#include "cpbitnode/node.hpp"

#include "cpbitnode/chain/params.hpp"
#include "cpbitnode/consensus/connect.hpp"
#include "cpbitnode/endpoint_parse.hpp"
#include "cpbitnode/metrics.hpp"
#include "cpbitnode/metrics_http.hpp"
#include "cpbitnode/p2p/manager.hpp"
#include "cpbitnode/p2p/peer.hpp"
#include "cpbitnode/p2p/server.hpp"
#include "cpbitnode/storage/blocks.hpp"
#include "cpbitnode/sync/blocks.hpp"
#include "cpbitnode/sync/headerRefresh.hpp"
#include "cpbitnode/sync/headers.hpp"
#include "cpbitnode/sync/syncDatadirLock.hpp"
#include "cpbitnode/util/json.hpp"

#include <atomic>
#include <chrono>
#include <csignal>
#include <filesystem>
#include <iostream>
#include <thread>

namespace cpbitnode {
namespace {

std::atomic<bool> g_shutdownRequested{false};

void onSignal(int) { g_shutdownRequested.store(true); }

void updatePhase3(db::ProjectTracker& tracker, const std::string& chainName) {
    tracker.updatePhase("phase3", "in_progress",
                        "Validated through height " + std::to_string(tracker.getValidatedHeight(chainName)) + " (" +
                            std::to_string(tracker.utxoCount()) + " UTXOs)");
}

}  // namespace

int runNode(
    const config::Settings& settings,
    std::function<std::unique_ptr<p2p::PeerConnection>(const std::string&, int, db::ProjectTracker&)>
        peerFactoryForTest) {
    const auto chain = chain::getChain(settings.chain);
    std::filesystem::create_directories(settings.dataDir);
    sync::ExclusiveDataDirSyncLock lock(settings.dataDir);

    db::ProjectTracker tracker(settings.resolvedDbPath());
    metrics_http::MetricsServerHandle metricsHandle = metrics_http::startMetricsServer(settings, tracker);
    tracker.setMeta("chain", chain.name);
    tracker.setMeta("data_dir", settings.dataDir);
    tracker.upsertSyncState(chain.name, std::nullopt, std::nullopt, std::nullopt, "starting");
    tracker.logEvent("node", "Starting cpbitnode", "info", "{\"chain\":" + util::jsonString(chain.name) + "}");

    sync::ensureGenesis(tracker, chain);
    sync::repairSyncState(tracker, chain);
    storage::BlockStore blockStore(settings.blocksDir(), chain.magic);
    sync::repairValidatedIfAhead(tracker, blockStore, chain);

    const int port = settings.p2pPort > 0 ? settings.p2pPort : chain.defaultPort;
    const auto manualPeers = splitManualPeerList(settings.peers, port);
    const int handshakeHeight = sync::resolveBootstrapStartHeight(tracker, chain, settings);
    p2p::PeerManager manager(chain, tracker, settings);
    if (peerFactoryForTest) {
        manager.setPeerFactoryForTest([&tracker, factory = std::move(peerFactoryForTest)](const std::string& host,
                                                                                          int port) {
            return factory(host, port, tracker);
        });
    }
    p2p::InboundServerHandle inboundHandle;

    std::signal(SIGINT, onSignal);
    std::signal(SIGTERM, onSignal);

    try {
        manager.bootstrap(manualPeers, handshakeHeight);
        metrics::clearLastError(tracker);
        tracker.upsertSyncState(chain.name, std::nullopt, std::nullopt, std::nullopt, "connected");
        tracker.updatePhase("phase0", "completed", "Wire protocol and handshake verified");

        const bool skipHeaderNetwork = settings.noHeaderRefresh || settings.syncSkipHeaders;
        int stored = 0;
        if (skipHeaderNetwork) {
            sync::markHeadersCurrent(tracker, chain);
        } else {
            const auto& ordered = manager.connections();
            int advertised = -1;
            for (const auto& peer : ordered) {
                if (peer->isConnected() && peer->remoteVersion() != nullptr) {
                    advertised = peer->remoteVersion()->startHeight;
                    break;
                }
            }
            const auto state = tracker.getSyncState(chain.name);
            const int syncBest = state.has_value() ? std::stoi((*state).at("best_height")) : 0;
            const auto refreshAction =
                sync::decideHeaderRefreshAction(settings, tracker, chain, syncBest, advertised);
            const bool localsCoverFollowup =
                sync::localHeadersCoverBlockFollowup(tracker, chain, settings.blocksTargetHeight);
            if (refreshAction != sync::HeaderRefreshAction::NetworkSync) {
                sync::markHeadersCurrent(tracker, chain);
                tracker.logEvent("sync", sync::headerRefreshLogMessage(refreshAction), "info");
            } else {
                stored = manager.syncHeaders(localsCoverFollowup);
            }
        }

        const auto refreshed = tracker.getSyncState(chain.name);
        if (refreshed.has_value() && refreshed->at("sync_status") == "headers_current") {
            tracker.updatePhase("phase1", "completed",
                                "Header chain synced to height " + refreshed->at("best_height"));
        } else if (stored > 0) {
            tracker.updatePhase("phase1", "in_progress", "Header chain sync in progress");
        }

        tracker.logEvent("node",
                         "Header sync stored " + std::to_string(stored) + " headers (status=" +
                             (refreshed.has_value() ? refreshed->at("sync_status") : std::string("unknown")) +
                             ", peers=" + std::to_string(manager.connections().size()) + ")",
                         "info");

        try {
            sync::repairValidatedIfAhead(tracker, blockStore, chain);
            if (settings.rebuildValidatedChain) {
                const int rebuilt = sync::rebuildValidatedChain(tracker, blockStore, chain);
                if (rebuilt > 0) {
                    updatePhase3(tracker, chain.name);
                }
            } else {
                const auto [connected, newHashes] = sync::connectStoredBlocks(tracker, blockStore, chain);
                std::vector<p2p::PeerConnection*> peerPtrs;
                peerPtrs.reserve(manager.connections().size());
                for (const auto& peer : manager.connections()) {
                    peerPtrs.push_back(peer.get());
                }
                for (const auto& hash : newHashes) {
                    p2p::broadcastWitnessBlockInv(peerPtrs, hash, tracker);
                }
                if (connected > 0) {
                    updatePhase3(tracker, chain.name);
                }
            }
        } catch (const consensus::ConnectBlockError& exc) {
            tracker.logEvent("sync", std::string("Block connect failed: ") + exc.what(), "error");
            throw;
        }

        const int blocksDownloaded = manager.syncBlocks(blockStore);
        const int validated = tracker.getValidatedHeight(chain.name);
        if (blocksDownloaded > 0 || validated > 0 || tracker.blockCount() > 0) {
            tracker.updatePhase("phase2", "in_progress",
                                std::to_string(tracker.blockCount()) + " blocks stored, validated through height " +
                                    std::to_string(validated));
            if (validated > 0) {
                updatePhase3(tracker, chain.name);
            }
            tracker.logEvent("node",
                             "Block sync downloaded=" + std::to_string(blocksDownloaded) + " stored=" +
                                 std::to_string(tracker.blockCount()) + " validated=" + std::to_string(validated) +
                                 " utxos=" + std::to_string(tracker.utxoCount()),
                             "info");
        }

        if (settings.syncOnly) {
            tracker.upsertSyncState(chain.name, std::nullopt, std::nullopt, std::nullopt, "running");
            tracker.logEvent("node", "Sync-only mode complete", "info");
            manager.close();
            p2p::stopInboundServer(inboundHandle);
            metrics_http::stopMetricsServer(metricsHandle);
            return 0;
        }

        tracker.upsertSyncState(chain.name, std::nullopt, std::nullopt, std::nullopt, "running");
        tracker.logEvent("node",
                         "Entering live message loop with " + std::to_string(manager.connections().size()) + " peer(s)",
                         "info");

        if (settings.listen) {
            manager.completeDeferredHandshake();
            inboundHandle = p2p::startInboundServer(
                chain, tracker, settings, blockStore, &manager.mempool(),
                [&manager](const messages::Transaction& tx, p2p::PeerConnection& source) {
                    manager.relayAcceptedTransaction(tx, source);
                });
        }

        std::thread managerThread([&manager]() { manager.run(); });
        while (!g_shutdownRequested.load()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(250));
        }

        tracker.logEvent("node", "Shutdown requested", "info");
        manager.close();
        if (managerThread.joinable()) {
            managerThread.join();
        }
        p2p::stopInboundServer(inboundHandle);
        metrics_http::stopMetricsServer(metricsHandle);
        return 0;
    } catch (const std::exception& exc) {
        manager.close();
        p2p::stopInboundServer(inboundHandle);
        metrics_http::stopMetricsServer(metricsHandle);
        tracker.logEvent("node", std::string("Node error: ") + exc.what(), "error");
        metrics::recordLastError(tracker, exc.what());
        tracker.upsertSyncState(chain.name, std::nullopt, std::nullopt, std::nullopt, "error");
        throw;
    }
}

}  // namespace cpbitnode
