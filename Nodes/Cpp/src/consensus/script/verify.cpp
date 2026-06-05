#include "cpbitnode/consensus/script/verify.hpp"

#include "cpbitnode/consensus/script/interpreter.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <mutex>
#include <string>
#include <string_view>
#include <thread>
#include <utility>

namespace cpbitnode::consensus::script {
namespace {

using Clock = std::chrono::steady_clock;

std::atomic<long long> gLegacySighashUs{0};
std::atomic<long long> gBip143SighashUs{0};
std::atomic<long long> gTaprootSighashUs{0};
std::atomic<long long> gEcdsaVerifyUs{0};
std::atomic<long long> gSchnorrVerifyUs{0};
std::atomic<long long> gInterpreterEvalUs{0};
std::atomic<long long> gRunnerWaitUs{0};

long long elapsedUs(Clock::time_point start) {
    return std::chrono::duration_cast<std::chrono::microseconds>(Clock::now() - start).count();
}

bool envDisabled(const char* name) {
    const char* raw = std::getenv(name);
    return raw != nullptr && std::string_view(raw) == "0";
}

std::size_t boundedThreadCount(std::size_t requested) {
    if (requested > 0) {
        return std::max<std::size_t>(1, std::min<std::size_t>(requested, 16));
    }
    const auto hardware = std::thread::hardware_concurrency();
    const auto reserveOne = hardware > 1 ? hardware - 1 : 1;
    return std::max<std::size_t>(1, std::min<std::size_t>(reserveOne, 16));
}

}  // namespace

bool scriptTimingEnabled() {
    const char* raw = std::getenv("CPBITNODE_SYNC_TIMING");
    return raw != nullptr && std::string_view(raw) != "" && std::string_view(raw) != "0";
}

void resetScriptTiming() {
    gLegacySighashUs.store(0);
    gBip143SighashUs.store(0);
    gTaprootSighashUs.store(0);
    gEcdsaVerifyUs.store(0);
    gSchnorrVerifyUs.store(0);
    gInterpreterEvalUs.store(0);
    gRunnerWaitUs.store(0);
}

void recordScriptTiming(ScriptTimingStage stage, long long elapsed) {
    if (elapsed <= 0 || !scriptTimingEnabled()) {
        return;
    }
    switch (stage) {
        case ScriptTimingStage::legacySighash:
            gLegacySighashUs.fetch_add(elapsed);
            break;
        case ScriptTimingStage::bip143Sighash:
            gBip143SighashUs.fetch_add(elapsed);
            break;
        case ScriptTimingStage::taprootSighash:
            gTaprootSighashUs.fetch_add(elapsed);
            break;
        case ScriptTimingStage::ecdsaVerify:
            gEcdsaVerifyUs.fetch_add(elapsed);
            break;
        case ScriptTimingStage::schnorrVerify:
            gSchnorrVerifyUs.fetch_add(elapsed);
            break;
        case ScriptTimingStage::interpreterEval:
            gInterpreterEvalUs.fetch_add(elapsed);
            break;
        case ScriptTimingStage::runnerWait:
            gRunnerWaitUs.fetch_add(elapsed);
            break;
    }
}

ScriptTimingSnapshot scriptTimingSnapshot() {
    return ScriptTimingSnapshot{gLegacySighashUs.load(),   gBip143SighashUs.load(), gTaprootSighashUs.load(),
                                gEcdsaVerifyUs.load(),    gSchnorrVerifyUs.load(), gInterpreterEvalUs.load(),
                                gRunnerWaitUs.load()};
}

void verifyTransactionInput(
    const messages::Transaction& transaction, std::size_t inputIndex, std::span<const std::uint8_t> scriptPubkey,
    std::int64_t amount,
    const std::vector<std::pair<std::int64_t, std::vector<std::uint8_t>>>* spentPrevouts,
    const SighashCache* sighashCache) {
    if (inputIndex >= transaction.inputs.size()) {
        throw ScriptVerifyError("input index out of range");
    }

    const auto& txIn = transaction.inputs[inputIndex];
    std::vector<std::vector<std::uint8_t>> witness;
    if (!transaction.witness.empty() && inputIndex < transaction.witness.size()) {
        witness = transaction.witness[inputIndex];
    }

    const auto version = witnessProgramVersion(scriptPubkey);
    if (version && *version > 1) {
        throw ScriptVerifyError("unsupported witness program version " + std::to_string(*version));
    }

    const bool knownTemplate = isP2pk(scriptPubkey) || isP2pkh(scriptPubkey) || isP2wpkh(scriptPubkey) ||
                               isP2sh(scriptPubkey) || isP2wsh(scriptPubkey) || isP2tr(scriptPubkey) ||
                               isBareOpN(scriptPubkey) || isBareMultisig(scriptPubkey) ||
                               isBareLegacyScript(scriptPubkey);
    if (!knownTemplate) {
        throw ScriptVerifyError("unsupported scriptPubKey template");
    }

    try {
        if (!verifyScript(txIn.scriptSig, scriptPubkey, transaction, inputIndex, amount, witness, spentPrevouts,
                          sighashCache)) {
            throw ScriptVerifyError("script verification failed for input " + std::to_string(inputIndex));
        }
    } catch (const ScriptError& error) {
        throw ScriptVerifyError(std::string(error.what()) + " (input " + std::to_string(inputIndex) + ")");
    }
}

class ScriptVerifyRunner::Impl {
public:
    explicit Impl(std::size_t threadCount) : threadCount_(boundedThreadCount(threadCount)) {
        if (!scriptVerifyParallelEnabledFromEnv()) {
            threadCount_ = 1;
        }
        if (threadCount_ <= 1) {
            return;
        }
        workers_.reserve(threadCount_);
        for (std::size_t index = 0; index < threadCount_; ++index) {
            workers_.emplace_back([this]() { workerLoop(); });
        }
    }

    ~Impl() { stop(); }

    Impl(const Impl&) = delete;
    Impl& operator=(const Impl&) = delete;

    VerifyBatchResult verify(const std::vector<VerifyInputJob>& jobs) {
        VerifyBatchResult batch;
        if (jobs.empty()) {
            return batch;
        }
        if (!parallel() || jobs.size() == 1) {
            std::vector<JobResult> results(jobs.size());
            for (std::size_t index = 0; index < jobs.size(); ++index) {
                runJob(jobs[index], results[index]);
            }
            reduceResults(results, batch);
            return batch;
        }

        std::vector<JobResult> results(jobs.size());
        const auto waitStarted = Clock::now();
        startBatch(jobs, results);
        processJobs(jobs, results);
        waitForBatch();
        recordScriptTiming(ScriptTimingStage::runnerWait, elapsedUs(waitStarted));
        reduceResults(results, batch);
        return batch;
    }

    std::size_t threadCount() const { return threadCount_; }
    bool parallel() const { return threadCount_ > 1 && !workers_.empty(); }

private:
    struct JobResult {
        std::size_t txIndex = 0;
        std::size_t inputIndex = 0;
        long long workerCpuUs = 0;
        std::optional<std::string> error;
    };

    static bool isEarlierFailure(std::size_t txIndex, std::size_t inputIndex, const VerifyBatchResult& batch) {
        return !batch.error.has_value() ||
               std::pair(txIndex, inputIndex) < std::pair(batch.failedTxIndex, batch.failedInputIndex);
    }

    static void runJob(const VerifyInputJob& job, JobResult& result) {
        result.txIndex = job.txIndex;
        result.inputIndex = job.inputIndex;
        const auto started = Clock::now();
        try {
            if (job.transaction == nullptr) {
                throw ScriptVerifyError("missing transaction for script verify job");
            }
            verifyTransactionInput(*job.transaction, job.inputIndex, job.scriptPubkey, job.amount, job.spentPrevouts,
                                   job.sighashCache);
        } catch (const ScriptVerifyError& exc) {
            result.error = exc.what();
        }
        result.workerCpuUs = elapsedUs(started);
    }

    static void reduceResults(const std::vector<JobResult>& results, VerifyBatchResult& batch) {
        for (const auto& result : results) {
            batch.workerCpuUs += result.workerCpuUs;
            if (result.error.has_value() && isEarlierFailure(result.txIndex, result.inputIndex, batch)) {
                batch.error = result.error;
                batch.failedTxIndex = result.txIndex;
                batch.failedInputIndex = result.inputIndex;
            }
        }
    }

    void processJobs(const std::vector<VerifyInputJob>& jobs, std::vector<JobResult>& results) {
        while (true) {
            const auto index = nextJob_.fetch_add(1, std::memory_order_relaxed);
            if (index >= jobs.size()) {
                return;
            }
            runJob(jobs[index], results[index]);
        }
    }

    void startBatch(const std::vector<VerifyInputJob>& jobs, std::vector<JobResult>& results) {
        {
            std::lock_guard lock(mutex_);
            activeJobs_ = &jobs;
            activeResults_ = &results;
            nextJob_.store(0, std::memory_order_relaxed);
            activeWorkers_ = workers_.size();
            batchActive_ = true;
            ++generation_;
        }
        cv_.notify_all();
    }

    void waitForBatch() {
        std::unique_lock lock(mutex_);
        doneCv_.wait(lock, [this]() { return !batchActive_; });
    }

    void workerLoop() {
        std::size_t seenGeneration = 0;
        while (true) {
            const std::vector<VerifyInputJob>* jobs = nullptr;
            std::vector<JobResult>* results = nullptr;
            {
                std::unique_lock lock(mutex_);
                cv_.wait(lock, [this, &seenGeneration]() {
                    return stopped_ || (batchActive_ && generation_ != seenGeneration);
                });
                if (stopped_) {
                    return;
                }
                seenGeneration = generation_;
                jobs = activeJobs_;
                results = activeResults_;
            }
            if (jobs != nullptr && results != nullptr) {
                processJobs(*jobs, *results);
            }
            {
                std::lock_guard lock(mutex_);
                if (activeWorkers_ > 0) {
                    --activeWorkers_;
                }
                if (activeWorkers_ == 0 && batchActive_) {
                    batchActive_ = false;
                    activeJobs_ = nullptr;
                    activeResults_ = nullptr;
                    doneCv_.notify_one();
                }
            }
        }
    }

    void stop() {
        {
            std::lock_guard lock(mutex_);
            stopped_ = true;
        }
        cv_.notify_all();
        for (auto& worker : workers_) {
            if (worker.joinable()) {
                worker.join();
            }
        }
        workers_.clear();
    }

    std::size_t threadCount_ = 1;
    std::vector<std::thread> workers_;
    std::mutex mutex_;
    std::condition_variable cv_;
    std::condition_variable doneCv_;
    std::atomic<std::size_t> nextJob_{0};
    const std::vector<VerifyInputJob>* activeJobs_ = nullptr;
    std::vector<JobResult>* activeResults_ = nullptr;
    std::size_t activeWorkers_ = 0;
    std::size_t generation_ = 0;
    bool batchActive_ = false;
    bool stopped_ = false;
};

ScriptVerifyRunner::ScriptVerifyRunner(std::size_t threadCount) : impl_(std::make_unique<Impl>(threadCount)) {}
ScriptVerifyRunner::~ScriptVerifyRunner() = default;
ScriptVerifyRunner::ScriptVerifyRunner(ScriptVerifyRunner&&) noexcept = default;
ScriptVerifyRunner& ScriptVerifyRunner::operator=(ScriptVerifyRunner&&) noexcept = default;

VerifyBatchResult ScriptVerifyRunner::verify(const std::vector<VerifyInputJob>& jobs) { return impl_->verify(jobs); }
std::size_t ScriptVerifyRunner::threadCount() const { return impl_->threadCount(); }
bool ScriptVerifyRunner::parallel() const { return impl_->parallel(); }

bool scriptVerifyParallelEnabledFromEnv() { return !envDisabled("CPBITNODE_SCRIPT_VERIFY_PARALLEL"); }

std::size_t scriptVerifyThreadCountFromEnv() {
    const char* raw = std::getenv("CPBITNODE_SCRIPT_VERIFY_THREADS");
    if (raw == nullptr || std::string_view(raw) == "" || std::string_view(raw) == "0") {
        raw = std::getenv("CPBITNODE_SCRIPT_VERIFY_PARALLELISM");
    }
    if (raw != nullptr && std::string_view(raw) != "" && std::string_view(raw) != "0") {
        return boundedThreadCount(static_cast<std::size_t>(std::max(1, std::stoi(raw))));
    }
    return boundedThreadCount(0);
}

const char* scriptVerifyRunnerModeFromEnv() {
    return scriptVerifyParallelEnabledFromEnv() && scriptVerifyThreadCountFromEnv() > 1 ? "parallel" : "sequential";
}

}  // namespace cpbitnode::consensus::script
