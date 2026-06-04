#include "cpbitnode/chain/params.hpp"
#include "cpbitnode/config/settings.hpp"
#include "cpbitnode/consensus/connect.hpp"
#include "cpbitnode/db/chainstate.hpp"
#include "cpbitnode/db/node_state.hpp"
#include "cpbitnode/endpoint_parse.hpp"
#include "cpbitnode/p2p/manager.hpp"
#include "cpbitnode/storage/blocks.hpp"
#include "cpbitnode/sync/blocks.hpp"
#include "cpbitnode/sync/headerRefresh.hpp"
#include "cpbitnode/sync/headers.hpp"
#include "cpbitnode/sync/syncDatadirLock.hpp"

#include <algorithm>
#include <filesystem>
#include <iostream>
#include <memory>
#include <optional>

namespace {

using cpbitnode::chain::getChain;
using cpbitnode::config::Settings;
using cpbitnode::consensus::ConnectBlockError;
using cpbitnode::db::NodeStateStore;
using cpbitnode::p2p::PeerManager;
using cpbitnode::storage::BlockStore;
using cpbitnode::sync::connectStoredBlocks;
using cpbitnode::sync::decideHeaderRefreshAction;
using cpbitnode::sync::ensureGenesis;
using cpbitnode::sync::headerRefreshLogMessage;
using cpbitnode::sync::HeaderRefreshAction;
using cpbitnode::sync::localHeadersCoverBlockFollowup;
using cpbitnode::sync::markHeadersCurrent;
using cpbitnode::sync::rebuildValidatedChain;
using cpbitnode::sync::repairSyncState;
using cpbitnode::sync::repairValidatedIfAhead;
using cpbitnode::sync::resolveBootstrapStartHeight;

std::unique_ptr<NodeStateStore> openNodeState(const Settings& settings) {
    if (settings.chainstateBackend != "rocksdb") {
        throw std::runtime_error("Cpp Core-native mode only supports --chainstate-backend rocksdb");
    }
    return cpbitnode::db::openRocksDbNodeStateStore(settings.dataDir);
}

void updatePhase3(NodeStateStore& tracker, const std::string& chainName) {
    tracker.updatePhase("phase3", "in_progress",
                        "Validated through height " + std::to_string(tracker.getValidatedHeight(chainName)) + " (" +
                            std::to_string(tracker.utxoCount()) + " UTXOs)");
}

int connectStored(const Settings& settings, bool rebuild) {
    const auto chain = getChain(settings.chain);
    auto state = openNodeState(settings);
    auto chainstate = cpbitnode::db::openChainstateStore(settings.chainstateBackend, settings.dataDir, *state);
    ensureGenesis(*state, chain);
    if (chainstate->readTip(chain.name).height < 0) {
        chainstate->resetValidatedChain(chain.name, chain.genesisHash);
    }
    repairSyncState(*state, chain);
    BlockStore blockStore(settings.blocksDir(), chain.magic);
    try {
        repairValidatedIfAhead(*state, *chainstate, blockStore, chain);
        int connected = 0;
        if (rebuild) {
            connected = rebuildValidatedChain(*state, *chainstate, blockStore, chain);
            std::cerr << "Rebuilt validated chain from stored blocks (height="
                      << chainstate->readTip(chain.name).height << ", utxos=" << chainstate->utxoCount() << ")\n";
        } else {
            connected = connectStoredBlocks(*state, *chainstate, blockStore, chain).first;
        }
        if (connected > 0) {
            updatePhase3(*state, chain.name);
            std::cerr << "Connected " << connected << " stored blocks (validated height="
                      << chainstate->readTip(chain.name).height << ", utxos=" << chainstate->utxoCount() << ")\n";
        }
        return 0;
    } catch (const ConnectBlockError& exc) {
        state->logEvent("sync", std::string("Block connect failed: ") + exc.what(), "error");
        throw;
    }
}

int syncBlocksRun(const Settings& settings) {
    const auto chain = getChain(settings.chain);
    auto state = openNodeState(settings);
    auto chainstate = cpbitnode::db::openChainstateStore(settings.chainstateBackend, settings.dataDir, *state);
    ensureGenesis(*state, chain);
    if (chainstate->readTip(chain.name).height < 0) {
        chainstate->resetValidatedChain(chain.name, chain.genesisHash);
    }
    repairSyncState(*state, chain);
    BlockStore blockStore(settings.blocksDir(), chain.magic);
    const int port = settings.p2pPort > 0 ? settings.p2pPort : chain.defaultPort;
    const auto manualPeers = cpbitnode::splitManualPeerList(settings.peers, port);
    PeerManager manager(chain, *state, settings);

    try {
        repairValidatedIfAhead(*state, *chainstate, blockStore, chain);
        if (settings.rebuildValidatedChain) {
            const int connected = rebuildValidatedChain(*state, *chainstate, blockStore, chain);
            std::cerr << "Rebuilt validated chain before download (height=" << chainstate->readTip(chain.name).height
                      << ", utxos=" << chainstate->utxoCount() << ")\n";
            if (connected > 0) {
                updatePhase3(*state, chain.name);
            }
        } else {
            const int connected = connectStoredBlocks(*state, *chainstate, blockStore, chain).first;
            if (connected > 0) {
                updatePhase3(*state, chain.name);
                std::cerr << "Connected " << connected << " stored blocks before download\n";
            }
        }

        const auto syncState = state->getSyncState(chain.name);
        const int syncBest = syncState.has_value() ? std::stoi((*syncState).at("best_height")) : 0;
        const int handshakeHeight = std::max(resolveBootstrapStartHeight(*state, chain, settings),
                                             chainstate->readTip(chain.name).height);
        manager.bootstrap(manualPeers, handshakeHeight);

        const auto& ordered = manager.connections();
        int advertised = -1;
        for (const auto& peer : ordered) {
            if (peer->isConnected() && peer->remoteVersion() != nullptr) {
                advertised = peer->remoteVersion()->startHeight;
                break;
            }
        }

        const auto refreshAction =
            decideHeaderRefreshAction(settings, *state, chain, syncBest, advertised);
        const bool localsCoverFollowup =
            localHeadersCoverBlockFollowup(*state, chain, settings.blocksTargetHeight);

        if (refreshAction != HeaderRefreshAction::NetworkSync) {
            markHeadersCurrent(*state, chain);
            std::cerr << headerRefreshLogMessage(refreshAction) << '\n';
        } else {
            const std::optional<int> headerStop =
                settings.blocksTargetHeight > 0 ? std::optional<int>(settings.blocksTargetHeight) : std::nullopt;
            manager.syncHeaders(localsCoverFollowup, headerStop);
        }

        const int downloaded = manager.syncBlocks(blockStore, *chainstate);
        const int validated = chainstate->readTip(chain.name).height;
        if (downloaded > 0 || validated > 0) {
            state->updatePhase("phase2", "in_progress",
                                std::to_string(state->blockCount()) + " blocks stored, validated through height " +
                                    std::to_string(validated));
            updatePhase3(*state, chain.name);
            std::cerr << "Block sync complete: downloaded=" << downloaded << " stored=" << state->blockCount()
                      << " validated=" << validated << " utxos=" << chainstate->utxoCount() << '\n';
        }
        manager.close();
        return 0;
    } catch (const ConnectBlockError& exc) {
        manager.close();
        state->logEvent("sync", std::string("Block connect failed: ") + exc.what(), "error");
        throw;
    } catch (...) {
        manager.close();
        throw;
    }
}

}  // namespace

int main(int argc, char** argv) {
    try {
        const auto settings = Settings::fromSyncArgs(argc, argv);
        std::filesystem::create_directories(settings.dataDir);
        cpbitnode::sync::ExclusiveDataDirSyncLock lock(settings.dataDir);
        if (settings.setConnectOnly) {
            return connectStored(settings, settings.rebuildValidatedChain);
        }
        return syncBlocksRun(settings);
    } catch (const ConnectBlockError& exc) {
        std::cerr << exc.what() << '\n';
        return 1;
    } catch (const std::runtime_error& exc) {
        const std::string msg = exc.what();
        if (msg.find("Another cpbitnode-sync holds this datadir") != std::string::npos) {
            std::cerr << msg << '\n';
            return 2;
        }
        std::cerr << msg << '\n';
        return 1;
    } catch (const std::exception& exc) {
        std::cerr << exc.what() << '\n';
        return 1;
    }
}
