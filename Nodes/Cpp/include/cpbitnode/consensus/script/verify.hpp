#pragma once

#include <cstdint>
#include <memory>
#include <optional>
#include <span>
#include <stdexcept>
#include <utility>
#include <vector>

#include "cpbitnode/consensus/script/sighash.hpp"
#include "cpbitnode/messages/transaction.hpp"

namespace cpbitnode::consensus::script {

class ScriptVerifyError : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

enum class ScriptTimingStage {
    legacySighash,
    bip143Sighash,
    taprootSighash,
    ecdsaVerify,
    schnorrVerify,
    interpreterEval,
    runnerWait,
};

struct ScriptTimingSnapshot {
    long long legacySighashUs = 0;
    long long bip143SighashUs = 0;
    long long taprootSighashUs = 0;
    long long ecdsaVerifyUs = 0;
    long long schnorrVerifyUs = 0;
    long long interpreterEvalUs = 0;
    long long runnerWaitUs = 0;
};

bool scriptTimingEnabled();
void resetScriptTiming();
void recordScriptTiming(ScriptTimingStage stage, long long elapsedUs);
ScriptTimingSnapshot scriptTimingSnapshot();

// Spend-path verifier for Shared-supported templates. Unsupported shapes must throw (validation blocker).
void verifyTransactionInput(
    const messages::Transaction& transaction, std::size_t inputIndex, std::span<const std::uint8_t> scriptPubkey,
    std::int64_t amount,
    const std::vector<std::pair<std::int64_t, std::vector<std::uint8_t>>>* spentPrevouts = nullptr,
    const SighashCache* sighashCache = nullptr);

struct VerifyInputJob {
    const messages::Transaction* transaction = nullptr;
    std::size_t txIndex = 0;
    std::size_t inputIndex = 0;
    std::vector<std::uint8_t> scriptPubkey;
    std::int64_t amount = 0;
    const std::vector<std::pair<std::int64_t, std::vector<std::uint8_t>>>* spentPrevouts = nullptr;
    const SighashCache* sighashCache = nullptr;
};

struct VerifyBatchResult {
    std::optional<std::string> error;
    std::size_t failedTxIndex = 0;
    std::size_t failedInputIndex = 0;
    long long workerCpuUs = 0;
};

class ScriptVerifyRunner {
public:
    explicit ScriptVerifyRunner(std::size_t threadCount = 0);
    ~ScriptVerifyRunner();

    ScriptVerifyRunner(const ScriptVerifyRunner&) = delete;
    ScriptVerifyRunner& operator=(const ScriptVerifyRunner&) = delete;
    ScriptVerifyRunner(ScriptVerifyRunner&&) noexcept;
    ScriptVerifyRunner& operator=(ScriptVerifyRunner&&) noexcept;

    VerifyBatchResult verify(const std::vector<VerifyInputJob>& jobs);
    std::size_t threadCount() const;
    bool parallel() const;

private:
    class Impl;
    std::unique_ptr<Impl> impl_;
};

bool scriptVerifyParallelEnabledFromEnv();
std::size_t scriptVerifyThreadCountFromEnv();
const char* scriptVerifyRunnerModeFromEnv();

}  // namespace cpbitnode::consensus::script
