#include "cpbitnode/sync/blocks.hpp"

#include "cpbitnode/consensus/connect.hpp"
#include "cpbitnode/messages/inventory.hpp"
#include "cpbitnode/util/json.hpp"

#include <algorithm>
#include <future>
#include <mutex>

namespace cpbitnode::sync {
namespace {

constexpr const char* kParallelCapId = "blocks.parallel";

std::vector<std::uint8_t> expectedPrevHash(const db::NodeStateStore& tracker, int height) {
    const auto prevHex = tracker.getHeaderHash(height - 1);
    if (!prevHex.has_value()) {
        return {};
    }
    std::vector<std::uint8_t> prev;
    prev.reserve(prevHex->size() / 2);
    for (std::size_t index = 0; index + 1 < prevHex->size(); index += 2) {
        prev.push_back(static_cast<std::uint8_t>(std::stoi(prevHex->substr(index, 2), nullptr, 16)));
    }
    std::reverse(prev.begin(), prev.end());
    return prev;
}

std::vector<std::uint8_t> hashHexToInternal(const std::string& hex) {
    std::vector<std::uint8_t> out;
    out.reserve(hex.size() / 2);
    for (std::size_t index = 0; index + 1 < hex.size(); index += 2) {
        out.push_back(static_cast<std::uint8_t>(std::stoi(hex.substr(index, 2), nullptr, 16)));
    }
    std::reverse(out.begin(), out.end());
    return out;
}

}  // namespace

std::pair<int, std::vector<std::vector<std::uint8_t>>> connectStoredBlocks(db::NodeStateStore& tracker,
                                                                           storage::BlockStore& blockStore,
                                                                           const chain::ChainParams& chain) {
    db::NodeStateChainstateStore chainstate(tracker);
    return connectStoredBlocks(tracker, chainstate, blockStore, chain);
}

std::pair<int, std::vector<std::vector<std::uint8_t>>> connectStoredBlocks(db::NodeStateStore& tracker,
                                                                           db::ChainstateStore& chainstate,
                                                                           storage::BlockStore& blockStore,
                                                                           const chain::ChainParams& chain) {
    int connected = 0;
    std::vector<std::vector<std::uint8_t>> hashes;
    while (true) {
        const int height = chainstate.readTip(chain.name).height + 1;
        const auto row = tracker.getBlock(height);
        if (!row.has_value()) {
            break;
        }
        const auto expectedPrev = expectedPrevHash(tracker, height);
        if (expectedPrev.size() != 32) {
            break;
        }
        const auto payload = blockStore.read(row->fileName, static_cast<std::size_t>(row->fileOffset),
                                             static_cast<std::size_t>(row->size));
        const auto blockHash = hashHexToInternal(row->blockHash);
        consensus::ConnectBlockOptions options;
        options.height = height;
        options.expectedPrev = expectedPrev;
        options.expectedHash = blockHash;
        options.hasExpectedHash = true;
        options.chainName = chain.name;
        try {
            consensus::connectBlock(tracker, chainstate, payload, options);
        } catch (const consensus::ConnectBlockError& exc) {
            tracker.logEvent("sync", "Rejected invalid block", "warning",
                             "{\"height\":" + std::to_string(height) + ",\"error\":" +
                                 cpbitnode::util::jsonString(exc.what()) + "}");
            break;
        }
        hashes.push_back(blockHash);
        connected += 1;
    }
    return {connected, hashes};
}

int rebuildValidatedChain(db::NodeStateStore& tracker, storage::BlockStore& blockStore,
                          const chain::ChainParams& chain) {
    db::NodeStateChainstateStore chainstate(tracker);
    return rebuildValidatedChain(tracker, chainstate, blockStore, chain);
}

int rebuildValidatedChain(db::NodeStateStore& tracker, db::ChainstateStore& chainstate,
                          storage::BlockStore& blockStore, const chain::ChainParams& chain) {
    chainstate.resetValidatedChain(chain.name, chain.genesisHash);
    int total = 0;
    while (true) {
        const auto [connected, hashes] = connectStoredBlocks(tracker, chainstate, blockStore, chain);
        (void)hashes;
        if (connected == 0) {
            break;
        }
        total += connected;
    }
    return total;
}

int repairValidatedIfAhead(db::NodeStateStore& tracker, storage::BlockStore& blockStore,
                           const chain::ChainParams& chain) {
    db::NodeStateChainstateStore chainstate(tracker);
    return repairValidatedIfAhead(tracker, chainstate, blockStore, chain);
}

int repairValidatedIfAhead(db::NodeStateStore& tracker, db::ChainstateStore& chainstate,
                           storage::BlockStore& blockStore, const chain::ChainParams& chain) {
    const int maxStored = tracker.maxStoredBlockHeight();
    const int validated = chainstate.readTip(chain.name).height;
    if (validated <= maxStored) {
        return 0;
    }
    return rebuildValidatedChain(tracker, chainstate, blockStore, chain);
}

void maybeMarkParallelSync(db::NodeStateStore& tracker, int parallelDownloads) {
    if (parallelDownloads <= 0) {
        return;
    }
    if (tracker.wireCapabilityMap().count(kParallelCapId) > 0 &&
        tracker.wireCapabilityMap().at(kParallelCapId) == 1) {
        return;
    }
    tracker.markWireCapability(kParallelCapId, true, "code", "prototype parallel height + peer races");
}

std::optional<std::pair<std::vector<std::uint8_t>, p2p::PeerConnection*>> requestBlockFromPeers(
    const std::vector<p2p::PeerConnection*>& peers, const std::vector<std::uint8_t>& blockHash) {
    for (auto* peer : peers) {
        if (peer == nullptr || !peer->isConnected()) {
            continue;
        }
        try {
            const auto payload = peer->requestBlock(blockHash);
            if (payload.has_value()) {
                return std::pair{*payload, peer};
            }
        } catch (const std::exception&) {
            continue;
        }
    }
    return std::nullopt;
}

std::optional<std::pair<std::vector<std::uint8_t>, p2p::PeerConnection*>> requestBlockFromPeersParallel(
    const std::vector<p2p::PeerConnection*>& peers, const std::vector<std::uint8_t>& blockHash) {
    std::vector<p2p::PeerConnection*> eligible;
    for (auto* peer : peers) {
        if (peer != nullptr && peer->isConnected()) {
            eligible.push_back(peer);
        }
    }
    if (eligible.empty()) {
        return std::nullopt;
    }

    std::mutex resultMutex;
    std::optional<std::pair<std::vector<std::uint8_t>, p2p::PeerConnection*>> winner;
    std::vector<std::future<void>> tasks;
    tasks.reserve(eligible.size());

    for (auto* peer : eligible) {
        tasks.push_back(std::async(std::launch::async, [peer, &blockHash, &resultMutex, &winner]() {
            if (winner.has_value()) {
                return;
            }
            try {
                const auto payload = peer->requestBlock(blockHash);
                if (!payload.has_value()) {
                    return;
                }
                std::lock_guard lock(resultMutex);
                if (!winner.has_value()) {
                    winner = std::pair{*payload, peer};
                }
            } catch (const std::exception&) {
            }
        }));
    }
    for (auto& task : tasks) {
        task.get();
    }
    return winner;
}

int syncBlocksBatch(const std::vector<p2p::PeerConnection*>& peers, db::NodeStateStore& tracker,
                    const chain::ChainParams& chain, storage::BlockStore& blockStore, int batchSize, int maxBlocks,
                    int parallelDownloads) {
    db::NodeStateChainstateStore chainstate(tracker);
    return syncBlocksBatch(peers, tracker, chainstate, chain, blockStore, batchSize, maxBlocks, parallelDownloads);
}

int syncBlocksBatch(const std::vector<p2p::PeerConnection*>& peers, db::NodeStateStore& tracker,
                    db::ChainstateStore& chainstate, const chain::ChainParams& chain, storage::BlockStore& blockStore,
                    int batchSize, int maxBlocks, int parallelDownloads) {
    if (peers.empty()) {
        return 0;
    }

    const int limit = maxBlocks == 0 ? batchSize : std::min(batchSize, maxBlocks);
    const auto missing = tracker.listMissingBlockHeights(limit);
    if (missing.empty()) {
        tracker.upsertSyncState(chain.name, std::nullopt, std::nullopt, std::nullopt, "blocks_current");
        return 0;
    }

    tracker.upsertSyncState(chain.name, std::nullopt, std::nullopt, std::nullopt, "blocks_syncing");
    int downloaded = 0;

    struct WorkItem {
        int height = 0;
        std::string blockHashHex;
        std::vector<std::uint8_t> blockHash;
        std::vector<std::uint8_t> expectedPrev;
    };

    auto connectDownloaded = [&](const WorkItem& item, const std::vector<std::uint8_t>& payload) -> bool {
        consensus::ConnectBlockOptions options;
        options.height = item.height;
        options.expectedPrev = item.expectedPrev;
        options.expectedHash = item.blockHash;
        options.hasExpectedHash = true;
        options.chainName = chain.name;
        try {
            consensus::connectBlock(tracker, chainstate, payload, options);
        } catch (const consensus::ConnectBlockError& exc) {
            tracker.logEvent("sync", "Rejected invalid block", "warning",
                             "{\"height\":" + std::to_string(item.height) + ",\"error\":" +
                                 util::jsonString(exc.what()) + "}");
            return false;
        }
        const auto written = blockStore.write(payload);
        tracker.recordBlock(item.height, item.blockHashHex, written.fileName, static_cast<int>(written.offset),
                            static_cast<int>(written.size));
        tracker.markWireCapability("blocks.block.store", true, "live",
                                   "stored block at height " + std::to_string(item.height));
        downloaded += 1;
        return true;
    };

    auto fetchOne = [&](const WorkItem& item) -> std::optional<std::vector<std::uint8_t>> {
        const auto outcome =
            parallelDownloads > 0 ? requestBlockFromPeersParallel(peers, item.blockHash)
                                  : requestBlockFromPeers(peers, item.blockHash);
        if (!outcome.has_value()) {
            tracker.logEvent("sync", "Block unavailable from peers", "warning",
                             "{\"height\":" + std::to_string(item.height) + ",\"block_hash\":" +
                                 util::jsonString(item.blockHashHex) + "}");
            return std::nullopt;
        }
        return outcome->first;
    };

    if (parallelDownloads > 0) {
        std::vector<WorkItem> work;
        for (const int height : missing) {
            if (maxBlocks > 0 && static_cast<int>(work.size()) >= maxBlocks) {
                break;
            }
            const auto blockHashHex = tracker.getHeaderHash(height);
            if (!blockHashHex.has_value()) {
                continue;
            }
            const auto expectedPrev = expectedPrevHash(tracker, height);
            if (expectedPrev.size() != 32) {
                continue;
            }
            work.push_back(
                WorkItem{height, *blockHashHex, hashHexToInternal(*blockHashHex), std::move(expectedPrev)});
        }
        if (!work.empty()) {
            maybeMarkParallelSync(tracker, parallelDownloads);
            for (std::size_t index = 0; index < work.size(); index += static_cast<std::size_t>(parallelDownloads)) {
                const std::size_t end =
                    std::min(work.size(), index + static_cast<std::size_t>(parallelDownloads));
                std::vector<std::future<std::optional<std::vector<std::uint8_t>>>> chunkTasks;
                for (std::size_t j = index; j < end; ++j) {
                    chunkTasks.push_back(std::async(std::launch::async, [&work, j, &fetchOne]() {
                        return fetchOne(work[j]);
                    }));
                }
                bool failed = false;
                for (std::size_t j = index; j < end; ++j) {
                    const auto payload = chunkTasks[j - index].get();
                    if (!payload.has_value() || !connectDownloaded(work[j], *payload)) {
                        failed = true;
                        break;
                    }
                }
                if (failed) {
                    break;
                }
            }
        }
    } else {
        for (const int height : missing) {
            if (maxBlocks > 0 && downloaded >= maxBlocks) {
                break;
            }
            const auto blockHashHex = tracker.getHeaderHash(height);
            if (!blockHashHex.has_value()) {
                continue;
            }
            const auto expectedPrev = expectedPrevHash(tracker, height);
            if (expectedPrev.size() != 32) {
                continue;
            }
            WorkItem item{height, *blockHashHex, hashHexToInternal(*blockHashHex), std::move(expectedPrev)};
            const auto payload = fetchOne(item);
            if (!payload.has_value() || !connectDownloaded(item, *payload)) {
                break;
            }
        }
    }

    if (downloaded > 0) {
        const int toHeight = missing[std::min(downloaded, static_cast<int>(missing.size())) - 1];
        tracker.logEvent("sync", "Downloaded " + std::to_string(downloaded) + " blocks", "info",
                         "{\"from_height\":" + std::to_string(missing.front()) + ",\"to_height\":" +
                             std::to_string(toHeight) + "}");
    }

    if (tracker.listMissingBlockHeights(1).empty()) {
        tracker.upsertSyncState(chain.name, std::nullopt, std::nullopt, std::nullopt, "blocks_current");
    }
    return downloaded;
}

int syncBlocksToTip(const std::vector<p2p::PeerConnection*>& peers, db::NodeStateStore& tracker,
                    const chain::ChainParams& chain, storage::BlockStore& blockStore,
                    const config::Settings& settings) {
    db::NodeStateChainstateStore chainstate(tracker);
    return syncBlocksToTip(peers, tracker, chainstate, chain, blockStore, settings);
}

int syncBlocksToTip(const std::vector<p2p::PeerConnection*>& peers, db::NodeStateStore& tracker,
                    db::ChainstateStore& chainstate, const chain::ChainParams& chain,
                    storage::BlockStore& blockStore, const config::Settings& settings) {
    int total = 0;
    while (true) {
        const int validated = chainstate.readTip(chain.name).height;
        if (settings.blocksTargetHeight > 0 && validated >= settings.blocksTargetHeight) {
            break;
        }
        const int remaining =
            settings.blocksMaxPerRun > 0 ? settings.blocksMaxPerRun - total : settings.blocksBatchSize;
        if (settings.blocksMaxPerRun > 0 && remaining <= 0) {
            break;
        }
        int batchLimit = settings.blocksMaxPerRun > 0 ? std::min(settings.blocksBatchSize, remaining)
                                                      : settings.blocksBatchSize;
        if (settings.blocksTargetHeight > 0) {
            const int heightsLeft = settings.blocksTargetHeight - validated;
            if (heightsLeft <= 0) {
                break;
            }
            batchLimit = std::min(batchLimit, heightsLeft);
        }
        const int downloaded = syncBlocksBatch(peers, tracker, chainstate, chain, blockStore, batchLimit,
                                               settings.blocksMaxPerRun > 0 ? batchLimit : 0,
                                               settings.parallelBlockDownloads);
        if (downloaded == 0) {
            break;
        }
        total += downloaded;
    }
    return total;
}

}  // namespace cpbitnode::sync
