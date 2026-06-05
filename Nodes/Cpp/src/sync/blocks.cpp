#include "cpbitnode/sync/blocks.hpp"

#include "cpbitnode/consensus/connect.hpp"
#include "cpbitnode/consensus/script/verify.hpp"
#include "cpbitnode/messages/inventory.hpp"
#include "cpbitnode/sync/validate.hpp"
#include "cpbitnode/util/json.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <future>
#include <map>
#include <iostream>
#include <mutex>
#include <queue>
#include <string_view>
#include <thread>

namespace cpbitnode::sync {
namespace {

constexpr const char* kParallelCapId = "blocks.parallel";
using Clock = std::chrono::steady_clock;

struct WorkItem {
    int height = 0;
    std::string blockHashHex;
    std::vector<std::uint8_t> blockHash;
    std::vector<std::uint8_t> expectedPrev;
};

struct PipelineTiming {
    long long totalWall = 0;
    long long blockFetchWait = 0;
    long long blockParseValidate = 0;
    long long blockStore = 0;
    long long metadataStore = 0;
    long long connectTotal = 0;
    long long statusWrites = 0;
    long long idleWait = 0;
    int blocksFetched = 0;
    int blocksConnected = 0;
    int prefetchDepth = 1;
    std::size_t scriptThreads = 1;
    std::uint64_t p2pFramesRead = 0;
    std::uint64_t p2pBytesRead = 0;
    std::uint64_t p2pHeaderReadUs = 0;
    std::uint64_t p2pPayloadReadUs = 0;
    long long scriptLegacySighash = 0;
    long long scriptBip143Sighash = 0;
    long long scriptTaprootSighash = 0;
    long long scriptEcdsaVerify = 0;
    long long scriptSchnorrVerify = 0;
    long long scriptInterpreterEval = 0;
    long long scriptRunnerWait = 0;
    long long utxoDeletePrepare = 0;
    long long utxoPutPrepare = 0;
    long long undoPutPrepare = 0;
    long long metadataPutPrepare = 0;
    long long rocksdbWrite = 0;
};

long long elapsedUs(Clock::time_point start) {
    return std::chrono::duration_cast<std::chrono::microseconds>(Clock::now() - start).count();
}

bool syncTimingEnabled() {
    const char* raw = std::getenv("CPBITNODE_SYNC_TIMING");
    return raw != nullptr && std::string_view(raw) != "" && std::string_view(raw) != "0";
}

int prefetchDepthFromEnv(int parallelDownloads) {
    int depth = parallelDownloads > 0 ? parallelDownloads : 4;
    const char* raw = std::getenv("CPBITNODE_BLOCK_PREFETCH_DEPTH");
    if (raw != nullptr && std::string_view(raw) != "" && std::string_view(raw) != "0") {
        depth = std::stoi(raw);
    }
    return std::max(1, std::min(16, depth));
}

void emitPipelineTiming(const PipelineTiming& timing) {
    if (!syncTimingEnabled()) {
        return;
    }
    std::cerr << "cpbitnode_pipeline_timing"
              << " unit=us"
              << " total_wall=" << timing.totalWall
              << " block_fetch_wait=" << timing.blockFetchWait
              << " block_parse_validate=" << timing.blockParseValidate
              << " block_store=" << timing.blockStore
              << " metadata_store=" << timing.metadataStore
              << " connect_total=" << timing.connectTotal
              << " utxo_load=0"
              << " prevout_batch_load=0"
              << " script_verify=0"
              << " script_verify_worker_cpu=0"
              << " utxo_apply=0"
              << " commit=0"
              << " status_writes=" << timing.statusWrites
              << " idle_wait=" << timing.idleWait
              << " blocks_fetched=" << timing.blocksFetched
              << " blocks_connected=" << timing.blocksConnected
              << " prefetch_depth=" << timing.prefetchDepth
              << " script_threads=" << timing.scriptThreads
              << " p2p_frames_read=" << timing.p2pFramesRead
              << " p2p_bytes_read=" << timing.p2pBytesRead
              << " p2p_header_read_us=" << timing.p2pHeaderReadUs
              << " p2p_payload_read_us=" << timing.p2pPayloadReadUs
              << " script_legacy_sighash=" << timing.scriptLegacySighash
              << " script_bip143_sighash=" << timing.scriptBip143Sighash
              << " script_taproot_sighash=" << timing.scriptTaprootSighash
              << " script_ecdsa_verify=" << timing.scriptEcdsaVerify
              << " script_schnorr_verify=" << timing.scriptSchnorrVerify
              << " script_interpreter_eval=" << timing.scriptInterpreterEval
              << " script_runner_wait=" << timing.scriptRunnerWait
              << " utxo_delete_prepare=" << timing.utxoDeletePrepare
              << " utxo_put_prepare=" << timing.utxoPutPrepare
              << " undo_put_prepare=" << timing.undoPutPrepare
              << " metadata_put_prepare=" << timing.metadataPutPrepare
              << " rocksdb_write=" << timing.rocksdbWrite
              << "\n";
}

void applyP2PReadTelemetryDelta(PipelineTiming& timing, const p2p::P2PReadTelemetry& started) {
    const auto ended = p2p::p2pReadTelemetrySnapshot();
    timing.p2pFramesRead = ended.framesRead - started.framesRead;
    timing.p2pBytesRead = ended.bytesRead - started.bytesRead;
    timing.p2pHeaderReadUs = ended.headerReadUs - started.headerReadUs;
    timing.p2pPayloadReadUs = ended.payloadReadUs - started.payloadReadUs;
}

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

std::vector<WorkItem> buildOrderedBlockWork(const db::NodeStateStore& tracker,
                                            const db::ChainstateStore& chainstate,
                                            const chain::ChainParams& chain,
                                            int limit,
                                            int blocksTargetHeight) {
    std::vector<WorkItem> work;
    if (limit <= 0) {
        return work;
    }
    const int validated = chainstate.readTip(chain.name).height;
    const int headerTip = tracker.maxHeaderHeight();
    int endHeight = headerTip;
    if (blocksTargetHeight > 0) {
        endHeight = std::min(endHeight, blocksTargetHeight);
    }
    endHeight = std::min(endHeight, validated + limit);
    for (int height = validated + 1; height <= endHeight; ++height) {
        const auto blockHashHex = tracker.getHeaderHash(height);
        if (!blockHashHex.has_value()) {
            break;
        }
        const auto expectedPrev = expectedPrevHash(tracker, height);
        if (expectedPrev.size() != 32) {
            break;
        }
        work.push_back(WorkItem{height, *blockHashHex, hashHexToInternal(*blockHashHex), std::move(expectedPrev)});
    }
    return work;
}

struct PrefetchedBlock {
    WorkItem item;
    std::vector<std::uint8_t> payload;
    consensus::Block decoded;
    long long fetchWaitUs = 0;
    long long parseValidateUs = 0;
    std::string error;
};

class BlockPrefetcher {
public:
    BlockPrefetcher(const std::vector<p2p::PeerConnection*>& peers, std::vector<WorkItem> work, int depth)
        : peers_(peers), work_(std::move(work)), depth_(std::max(1, std::min(16, depth))) {}

    ~BlockPrefetcher() { join(); }

    void start() {
        worker_ = std::thread([this]() {
            try {
                run();
            } catch (const std::exception& exc) {
                PrefetchedBlock failed;
                failed.error = exc.what();
                push(std::move(failed));
            }
            {
                std::lock_guard lock(mutex_);
                done_ = true;
            }
            cv_.notify_all();
        });
    }

    std::optional<PrefetchedBlock> pop(long long* idleWaitUs) {
        const auto started = Clock::now();
        std::unique_lock lock(mutex_);
        cv_.wait(lock, [this]() { return !queue_.empty() || done_; });
        if (idleWaitUs != nullptr) {
            *idleWaitUs += elapsedUs(started);
        }
        if (queue_.empty()) {
            return std::nullopt;
        }
        auto item = std::move(queue_.front());
        queue_.pop();
        cv_.notify_all();
        return item;
    }

    void cancel() {
        {
            std::lock_guard lock(mutex_);
            cancelled_ = true;
        }
        cv_.notify_all();
    }

    void join() {
        cancel();
        if (worker_.joinable()) {
            worker_.join();
        }
    }

    const p2p::BlockRequestStats& stats() const { return stats_; }

private:
    bool push(PrefetchedBlock block) {
        std::unique_lock lock(mutex_);
        cv_.wait(lock, [this]() { return cancelled_ || queue_.size() < static_cast<std::size_t>(depth_); });
        if (cancelled_) {
            return false;
        }
        queue_.push(std::move(block));
        cv_.notify_all();
        return true;
    }

    void run() {
        if (work_.empty()) {
            return;
        }
        if (peers_.empty() || peers_.front() == nullptr || !peers_.front()->isConnected()) {
            PrefetchedBlock failed;
            failed.item = work_.front();
            failed.error = "block unavailable from peers";
            (void)push(std::move(failed));
            return;
        }

        std::vector<std::vector<std::uint8_t>> hashes;
        hashes.reserve(work_.size());
        for (const auto& item : work_) {
            hashes.push_back(item.blockHash);
        }

        std::map<std::size_t, PrefetchedBlock> ready;
        std::size_t nextToPush = 0;
        bool stoppedByCallback = false;

        auto flushContiguous = [&]() -> bool {
            while (true) {
                auto it = ready.find(nextToPush);
                if (it == ready.end()) {
                    return true;
                }
                const bool hasError = !it->second.error.empty();
                PrefetchedBlock block = std::move(it->second);
                ready.erase(it);
                nextToPush += 1;
                if (!push(std::move(block))) {
                    return false;
                }
                if (hasError) {
                    return false;
                }
            }
        };

        const auto callback = [&](std::size_t index, std::vector<std::uint8_t> payload,
                                  long long fetchWaitUs) -> bool {
            if (cancelled_.load() || index >= work_.size()) {
                return false;
            }
            PrefetchedBlock out;
            out.item = work_[index];
            out.fetchWaitUs = fetchWaitUs;
            out.payload = std::move(payload);
            const auto parseStarted = Clock::now();
            try {
                out.decoded = validateBlock(out.payload, out.item.expectedPrev, &out.item.blockHash);
            } catch (const BlockValidationError& exc) {
                out.parseValidateUs = elapsedUs(parseStarted);
                out.error = exc.what();
                stoppedByCallback = true;
            }
            if (out.parseValidateUs == 0) {
                out.parseValidateUs = elapsedUs(parseStarted);
            }
            ready[index] = std::move(out);
            if (!flushContiguous()) {
                stoppedByCallback = true;
                return false;
            }
            return !stoppedByCallback && !cancelled_.load();
        };

        const bool completed = peers_.front()->requestBlocksStreaming(
            hashes, static_cast<std::size_t>(depth_), callback, 120.0, p2p::BlockRequestOptions{false}, &stats_);
        if (!completed && !cancelled_.load()) {
            (void)flushContiguous();
            if (nextToPush < work_.size()) {
                PrefetchedBlock failed;
                failed.item = work_[nextToPush];
                failed.error = stoppedByCallback ? "block validation failed during streaming fetch"
                                                 : "block unavailable from peers";
                (void)push(std::move(failed));
            }
        }
    }

    const std::vector<p2p::PeerConnection*>& peers_;
    std::vector<WorkItem> work_;
    int depth_;
    std::thread worker_;
    std::mutex mutex_;
    std::condition_variable cv_;
    std::queue<PrefetchedBlock> queue_;
    p2p::BlockRequestStats stats_;
    bool done_ = false;
    std::atomic<bool> cancelled_ = false;
};

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
    tracker.markWireCapability(kParallelCapId, true, "code", "batched P2P block prefetch window");
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
                    int parallelDownloads, int blocksTargetHeight) {
    db::NodeStateChainstateStore chainstate(tracker);
    return syncBlocksBatch(peers, tracker, chainstate, chain, blockStore, batchSize, maxBlocks, parallelDownloads,
                           blocksTargetHeight);
}

int syncBlocksBatch(const std::vector<p2p::PeerConnection*>& peers, db::NodeStateStore& tracker,
                    db::ChainstateStore& chainstate, const chain::ChainParams& chain, storage::BlockStore& blockStore,
                    int batchSize, int maxBlocks, int parallelDownloads, int blocksTargetHeight) {
    return syncBlocksBatch(peers, tracker, chainstate, chain, blockStore, batchSize, maxBlocks, parallelDownloads,
                           blocksTargetHeight, nullptr);
}

int syncBlocksBatch(const std::vector<p2p::PeerConnection*>& peers, db::NodeStateStore& tracker,
                    db::ChainstateStore& chainstate, const chain::ChainParams& chain, storage::BlockStore& blockStore,
                    int batchSize, int maxBlocks, int parallelDownloads, int blocksTargetHeight,
                    consensus::script::ScriptVerifyRunner* scriptRunner) {
    if (peers.empty()) {
        return 0;
    }

    const auto batchStarted = Clock::now();
    PipelineTiming pipeline;
    pipeline.prefetchDepth = prefetchDepthFromEnv(parallelDownloads);
    pipeline.scriptThreads = scriptRunner != nullptr ? scriptRunner->threadCount() : 1;
    consensus::script::resetScriptTiming();
    db::resetStorageTiming();
    const auto p2pReadStarted = p2p::p2pReadTelemetrySnapshot();

    const int limit = maxBlocks == 0 ? batchSize : std::min(batchSize, maxBlocks);
    const auto work = buildOrderedBlockWork(tracker, chainstate, chain, limit, blocksTargetHeight);
    if (work.empty()) {
        const bool unbounded = blocksTargetHeight <= 0;
        const int validated = chainstate.readTip(chain.name).height;
        const int headerTip = tracker.maxHeaderHeight();
        if (unbounded && validated >= headerTip) {
            tracker.upsertSyncState(chain.name, std::nullopt, std::nullopt, std::nullopt, "blocks_current");
        }
        return 0;
    }
    const int validated = chainstate.readTip(chain.name).height;
    const bool unbounded = blocksTargetHeight <= 0;
    if (unbounded && validated >= tracker.maxHeaderHeight()) {
        const auto statusStarted = Clock::now();
        tracker.upsertSyncState(chain.name, std::nullopt, std::nullopt, std::nullopt, "blocks_current");
        pipeline.statusWrites += elapsedUs(statusStarted);
        pipeline.totalWall = elapsedUs(batchStarted);
        applyP2PReadTelemetryDelta(pipeline, p2pReadStarted);
        emitPipelineTiming(pipeline);
        return 0;
    }

    auto statusStarted = Clock::now();
    tracker.upsertSyncState(chain.name, std::nullopt, std::nullopt, std::nullopt, "blocks_syncing");
    pipeline.statusWrites += elapsedUs(statusStarted);
    int downloaded = 0;

    auto connectDownloaded = [&](const PrefetchedBlock& prefetched) -> bool {
        const auto storeStarted = Clock::now();
        const auto written = blockStore.write(prefetched.payload);
        pipeline.blockStore += elapsedUs(storeStarted);
        consensus::ConnectBlockOptions options;
        options.height = prefetched.item.height;
        options.expectedPrev = prefetched.item.expectedPrev;
        options.expectedHash = prefetched.item.blockHash;
        options.hasExpectedHash = true;
        options.chainName = chain.name;
        options.scriptRunner = scriptRunner;
        options.blockIndex =
            db::StoredBlockRow{prefetched.item.height, prefetched.item.blockHashHex, written.fileName,
                               static_cast<int>(written.offset), static_cast<int>(written.size)};
        try {
            const auto connectStarted = Clock::now();
            consensus::connectDecodedBlock(tracker, chainstate, prefetched.decoded, options);
            pipeline.connectTotal += elapsedUs(connectStarted);
        } catch (const consensus::ConnectBlockError& exc) {
            tracker.logEvent("sync", "Rejected invalid block", "warning",
                             "{\"height\":" + std::to_string(prefetched.item.height) + ",\"error\":" +
                                 util::jsonString(exc.what()) + "}");
            return false;
        }
        downloaded += 1;
        return true;
    };

    maybeMarkParallelSync(tracker, pipeline.prefetchDepth);
    BlockPrefetcher prefetcher(peers, work, pipeline.prefetchDepth);
    prefetcher.start();
    while (maxBlocks <= 0 || downloaded < maxBlocks) {
        auto prefetched = prefetcher.pop(&pipeline.idleWait);
        if (!prefetched.has_value()) {
            break;
        }
        pipeline.blockFetchWait += prefetched->fetchWaitUs;
        pipeline.blockParseValidate += prefetched->parseValidateUs;
        if (!prefetched->error.empty()) {
            tracker.logEvent("sync", "Block unavailable from peers", "warning",
                             "{\"height\":" + std::to_string(prefetched->item.height) + ",\"block_hash\":" +
                                 util::jsonString(prefetched->item.blockHashHex) + ",\"error\":" +
                                 util::jsonString(prefetched->error) + "}");
            break;
        }
        pipeline.blocksFetched += 1;
        if (!connectDownloaded(*prefetched)) {
            break;
        }
        pipeline.blocksConnected += 1;
    }
    prefetcher.join();
    const auto fetchStats = prefetcher.stats();

    if (fetchStats.sentGetData || fetchStats.receivedBlock || fetchStats.receivedNotFound || downloaded > 0) {
        const auto metaStarted = Clock::now();
        if (fetchStats.sentGetData) {
            tracker.markWireCapability("blocks.getdata.send", true, "live",
                                       "sent streaming getdata during block sync batch");
        }
        if (fetchStats.receivedBlock) {
            tracker.markWireCapability("blocks.block.recv", true, "live",
                                       "received streaming blocks during block sync batch");
        }
        if (fetchStats.receivedNotFound) {
            tracker.markWireCapability("blocks.notfound", true, "live",
                                       "peer returned notfound during block sync batch");
        }
        pipeline.metadataStore += elapsedUs(metaStarted);
    }

    if (downloaded > 0) {
        const int toHeight = work[std::min(downloaded, static_cast<int>(work.size())) - 1].height;
        tracker.logEvent("sync", "Downloaded " + std::to_string(downloaded) + " blocks", "info",
                             "{\"from_height\":" + std::to_string(work.front().height) + ",\"to_height\":" +
                                 std::to_string(toHeight) + "}");
        const auto metaStarted = Clock::now();
        tracker.markWireCapability("blocks.block.store", true, "live",
                                   "stored blocks through height " + std::to_string(toHeight));
        pipeline.metadataStore += elapsedUs(metaStarted);
    }

    if ((blocksTargetHeight <= 0 && chainstate.readTip(chain.name).height >= tracker.maxHeaderHeight()) ||
        (blocksTargetHeight > 0 && chainstate.readTip(chain.name).height >= blocksTargetHeight)) {
        const auto finalStatusStarted = Clock::now();
        tracker.upsertSyncState(chain.name, std::nullopt, std::nullopt, std::nullopt, "blocks_current");
        pipeline.statusWrites += elapsedUs(finalStatusStarted);
    }
    pipeline.totalWall = elapsedUs(batchStarted);
    applyP2PReadTelemetryDelta(pipeline, p2pReadStarted);
    const auto scriptTiming = consensus::script::scriptTimingSnapshot();
    pipeline.scriptLegacySighash = scriptTiming.legacySighashUs;
    pipeline.scriptBip143Sighash = scriptTiming.bip143SighashUs;
    pipeline.scriptTaprootSighash = scriptTiming.taprootSighashUs;
    pipeline.scriptEcdsaVerify = scriptTiming.ecdsaVerifyUs;
    pipeline.scriptSchnorrVerify = scriptTiming.schnorrVerifyUs;
    pipeline.scriptInterpreterEval = scriptTiming.interpreterEvalUs;
    pipeline.scriptRunnerWait = scriptTiming.runnerWaitUs;
    const auto storageTiming = db::storageTimingSnapshot();
    pipeline.utxoDeletePrepare = storageTiming.utxoDeletePrepareUs;
    pipeline.utxoPutPrepare = storageTiming.utxoPutPrepareUs;
    pipeline.undoPutPrepare = storageTiming.undoPutPrepareUs;
    pipeline.metadataPutPrepare = storageTiming.metadataPutPrepareUs;
    pipeline.rocksdbWrite = storageTiming.rocksdbWriteUs;
    emitPipelineTiming(pipeline);
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
    consensus::script::ScriptVerifyRunner scriptRunner(consensus::script::scriptVerifyThreadCountFromEnv());
    while (true) {
        const int validated = chainstate.readTip(chain.name).height;
        if (settings.blocksTargetHeight > 0 && validated >= settings.blocksTargetHeight) {
            tracker.upsertSyncState(chain.name, std::nullopt, std::nullopt, std::nullopt, "blocks_current");
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
                                               settings.parallelBlockDownloads, settings.blocksTargetHeight,
                                               &scriptRunner);
        if (downloaded == 0) {
            break;
        }
        total += downloaded;
    }
    return total;
}

}  // namespace cpbitnode::sync
