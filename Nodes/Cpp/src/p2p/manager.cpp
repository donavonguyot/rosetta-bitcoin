#include "cpbitnode/p2p/manager.hpp"

#include "cpbitnode/consensus/witness.hpp"
#include "cpbitnode/metrics.hpp"
#include "cpbitnode/p2p/ban_policy.hpp"
#include "cpbitnode/p2p/discovery.hpp"
#include "cpbitnode/storage/blocks.hpp"
#include "cpbitnode/sync/blocks.hpp"
#include "cpbitnode/sync/headerRefresh.hpp"
#include "cpbitnode/sync/headers.hpp"
#include "cpbitnode/util/json.hpp"

#include <algorithm>
#include <stdexcept>

namespace cpbitnode::p2p {

PeerManager::PeerManager(const chain::ChainParams& chain, db::NodeStateStore& tracker, config::Settings settings)
    : chain_(chain), tracker_(tracker), settings_(std::move(settings)) {
    effectiveMaxOutbound_ = settings_.maxOutboundPeers;
    mempool::MempoolOptions opts;
    opts.tracker = &tracker_;
    opts.settings = &settings_;
    opts.mempoolMaxCount = settings_.mempoolMaxCount;
    opts.mempoolMaxAgeSeconds = settings_.mempoolMaxAgeSeconds;
    mempool_ = std::make_unique<mempool::Mempool>(opts);
}

void PeerManager::setPeerFactoryForTest(PeerFactory factory) { peerFactory_ = std::move(factory); }

std::unique_ptr<PeerConnection> PeerManager::makePeer(const std::string& host, int port, int startHeight) {
    if (peerFactory_) {
        return peerFactory_(host, port);
    }
    PeerConnection::Options options;
    options.host = host;
    options.port = port;
    options.chain = &chain_;
    options.tracker = &tracker_;
    options.settings = settings_;
    options.protocolVersion = settings_.protocolVersion;
    options.userAgent = settings_.userAgent;
    options.startHeight = startHeight;
    options.pingIntervalSeconds = settings_.pingIntervalSeconds;
    options.staleTimeoutSeconds = settings_.peerStaleSeconds;
    options.mempool = mempool_.get();
    options.relayTxAccepted = [this](const messages::Transaction& tx, PeerConnection& source) {
        relayAcceptedTransaction(tx, source);
    };
    return std::make_unique<PeerConnection>(std::move(options));
}

void PeerManager::connectPeers(const std::vector<std::pair<std::string, int>>& targets, int startHeight,
                               bool discoverPeerAddresses) {
    for (const auto& [host, port] : targets) {
        if (static_cast<int>(connections_.size()) >= effectiveMaxOutbound_) {
            break;
        }
        const bool alreadyConnected = std::any_of(connections_.begin(), connections_.end(),
                                                  [&](const auto& peer) {
                                                      return peer->host() == host && peer->port() == port;
                                                  });
        if (alreadyConnected) {
            continue;
        }
        auto peer = makePeer(host, port, startHeight);
        try {
            peer->connect();
        } catch (const std::exception&) {
            if (!host.empty() && host != "unknown" && port > 0) {
                tracker_.incrementPeerBanScore(host, port, kBanHandshakeFail);
            }
            continue;
        }
        if (discoverPeerAddresses) {
            try {
                peer->discoverPeers();
            } catch (const std::exception&) {
                // Retain peer for sync.
            }
        }
        connections_.push_back(std::move(peer));
        if (static_cast<int>(connections_.size()) >= effectiveMaxOutbound_) {
            break;
        }
    }
}

void PeerManager::bootstrap(const std::vector<std::pair<std::string, int>>& manualPeers, int startHeight) {
    manualSyncPeers_ = {manualPeers.begin(), manualPeers.end()};
    std::vector<std::pair<std::string, int>> targets;
    if (!manualPeers.empty()) {
        effectiveMaxOutbound_ = std::max(1, settings_.maxOutboundPeers);
        targets = manualPeers;
    } else {
        effectiveMaxOutbound_ = settings_.maxOutboundPeers;
        targets = bootstrapPeerTargets(tracker_, chain_, settings_, manualPeers);
    }
    const bool discover = !settings_.skipGetaddr;
    connectPeers(targets, startHeight, discover);
    if (connections_.empty()) {
        throw std::runtime_error("Could not connect to any peers");
    }
}

std::vector<PeerConnection*> PeerManager::orderedSyncPeers() const {
    std::vector<PeerConnection*> peers;
    peers.reserve(connections_.size());
    for (const auto& peer : connections_) {
        if (peer->isConnected()) {
            peers.push_back(peer.get());
        }
    }
    std::sort(peers.begin(), peers.end(), [&](PeerConnection* a, PeerConnection* b) {
        const int manualA = manualSyncPeers_.count({a->host(), a->port()}) > 0 ? 0 : 1;
        const int manualB = manualSyncPeers_.count({b->host(), b->port()}) > 0 ? 0 : 1;
        if (manualA != manualB) {
            return manualA < manualB;
        }
        const int heightA = a->remoteVersion() ? a->remoteVersion()->startHeight : 0;
        const int heightB = b->remoteVersion() ? b->remoteVersion()->startHeight : 0;
        return heightA > heightB;
    });
    return peers;
}

int PeerManager::syncHeaders(bool bestEffortIfHeadersCoverFollowupBlocks, std::optional<int> stopHeight) {
    const auto peers = orderedSyncPeers();
    if (peers.empty()) {
        throw std::runtime_error("No connected peers available for header sync");
    }
    std::exception_ptr lastError;
    for (auto* peer : peers) {
        try {
            return peer->syncHeaders(stopHeight);
        } catch (const std::exception& exc) {
            lastError = std::current_exception();
            tracker_.logEvent("sync", "Header sync failed via " + peer->host() + ":" + std::to_string(peer->port()),
                              "warning", "{\"error\":" + util::jsonString(exc.what()) + "}");
        }
    }
    if (bestEffortIfHeadersCoverFollowupBlocks &&
        sync::localHeadersCoverBlockFollowup(tracker_, chain_, settings_.blocksTargetHeight)) {
        tracker_.logEvent("sync", "header_sync_best_effort_continuing_block_download", "warning", "{}");
        sync::markHeadersCurrent(tracker_, chain_);
        return 0;
    }
    if (lastError) {
        std::rethrow_exception(lastError);
    }
    throw std::runtime_error("Header sync failed");
}

int PeerManager::syncBlocks(storage::BlockStore& blockStore) {
    return sync::syncBlocksToTip(orderedSyncPeers(), tracker_, chain_, blockStore, settings_);
}

int PeerManager::syncBlocks(storage::BlockStore& blockStore, db::ChainstateStore& chainstate) {
    return sync::syncBlocksToTip(orderedSyncPeers(), tracker_, chainstate, chain_, blockStore, settings_);
}

void PeerManager::completeDeferredHandshake() {
    for (auto& peer : connections_) {
        if (peer->isConnected()) {
            peer->completeDeferredHandshake();
        }
    }
}

void PeerManager::relayAcceptedTransaction(const messages::Transaction& tx, PeerConnection& source) {
    messages::InvMessage inv;
    inv.inventory.push_back(messages::InventoryVector{messages::MSG_WITNESS_TX, consensus::transactionWtxid(tx)});
    const auto payload = inv.serialize();
    bool relayedAny = false;
    for (auto& peer : connections_) {
        if (peer.get() == &source || !peer->isConnected()) {
            continue;
        }
        if (!mempool::transactionMeetsPeerFeefilter(tx, tracker_, peer->peerFeeFilterSatKvb())) {
            continue;
        }
        try {
            peer->send(messages::InvMessage::kCommand, payload);
            relayedAny = true;
        } catch (const std::exception&) {
            // Best-effort relay.
        }
    }
    if (relayedAny) {
        metrics::incrMetaCounter(tracker_, metrics::kMetaTxsRelayedTotal);
        tracker_.markWireCapability("tx.inv.send", true, "live", "witness-tx inv after mempool insert");
    }
}

void PeerManager::run() {
    if (connections_.empty()) {
        throw std::runtime_error("No connected peers for live message loop");
    }
    runThreads_.clear();
    runThreads_.reserve(connections_.size());
    for (auto& peer : connections_) {
        runThreads_.emplace_back([peerPtr = peer.get()]() {
            if (peerPtr->isConnected()) {
                peerPtr->run();
            }
        });
    }
    for (auto& thread : runThreads_) {
        if (thread.joinable()) {
            thread.join();
        }
    }
    runThreads_.clear();
}

void PeerManager::close() {
    for (auto& peer : connections_) {
        peer->close();
    }
    for (auto& thread : runThreads_) {
        if (thread.joinable()) {
            thread.join();
        }
    }
    runThreads_.clear();
    connections_.clear();
}

}  // namespace cpbitnode::p2p
