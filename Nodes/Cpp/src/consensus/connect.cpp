#include "cpbitnode/consensus/connect.hpp"

#include "cpbitnode/consensus/coinbase.hpp"
#include "cpbitnode/consensus/constants.hpp"
#include "cpbitnode/consensus/merkle.hpp"
#include "cpbitnode/consensus/script/verify.hpp"
#include "cpbitnode/consensus/subsidy.hpp"
#include "cpbitnode/consensus/witness.hpp"
#include "cpbitnode/metrics.hpp"
#include "cpbitnode/sync/validate.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdlib>
#include <iostream>
#include <optional>
#include <sstream>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <utility>

namespace cpbitnode::consensus {
namespace detail {

using Clock = std::chrono::steady_clock;

struct ConnectTiming {
    long long utxoLoad = 0;
    long long scriptVerify = 0;
    long long scriptVerifyWorkerCpu = 0;
    long long utxoApply = 0;
    long long commit = 0;
    long long blockConnectStoreCommit = 0;
};

bool syncTimingEnabled() {
    const char* raw = std::getenv("CPBITNODE_SYNC_TIMING");
    return raw != nullptr && std::string_view(raw) != "" && std::string_view(raw) != "0";
}

long long elapsedUs(Clock::time_point start) {
    return std::chrono::duration_cast<std::chrono::microseconds>(Clock::now() - start).count();
}

std::string displayHex(std::span<const std::uint8_t> bytes) {
    static const char* kHex = "0123456789abcdef";
    std::string out;
    out.reserve(bytes.size() * 2);
    for (auto it = bytes.rbegin(); it != bytes.rend(); ++it) {
        out.push_back(kHex[(*it >> 4) & 0xf]);
        out.push_back(kHex[*it & 0xf]);
    }
    return out;
}

struct OutpointKey {
    std::array<std::uint8_t, 32> txid{};
    std::uint32_t vout = 0;

    bool operator==(const OutpointKey& other) const { return vout == other.vout && txid == other.txid; }
};

struct OutpointKeyHash {
    std::size_t operator()(const OutpointKey& key) const {
        std::size_t hash = key.vout;
        for (const auto byte : key.txid) {
            hash = hash * 131 + byte;
        }
        return hash;
    }
};

OutpointKey outpointKey(const messages::OutPoint& outpoint) {
    OutpointKey key;
    if (outpoint.hash.size() == key.txid.size()) {
        std::copy(outpoint.hash.begin(), outpoint.hash.end(), key.txid.begin());
    }
    key.vout = outpoint.index;
    return key;
}

OutpointKey outpointKey(std::span<const std::uint8_t> txid, int vout) {
    OutpointKey key;
    if (txid.size() == key.txid.size()) {
        std::copy(txid.begin(), txid.end(), key.txid.begin());
    }
    key.vout = static_cast<std::uint32_t>(vout);
    return key;
}

std::vector<std::uint8_t> keyTxidVector(const OutpointKey& key) {
    return std::vector<std::uint8_t>(key.txid.begin(), key.txid.end());
}

class BlockUtxoView {
public:
    BlockUtxoView(db::ChainstateStore& chainstate, int height) : chainstate_(chainstate), height_(height) {}

    void preloadExternal(std::span<const db::Outpoint> outpoints) {
        std::vector<db::Outpoint> external;
        external.reserve(outpoints.size());
        std::unordered_set<OutpointKey, OutpointKeyHash> seen;
        for (const auto& outpoint : outpoints) {
            const auto key = outpointKey(outpoint.txid, outpoint.vout);
            if (created_.contains(key)) {
                continue;
            }
            if (seen.insert(key).second) {
                external.push_back(outpoint);
            }
        }
        const auto loaded = chainstate_.getUtxos(external);
        for (std::size_t index = 0; index < external.size(); ++index) {
            if (loaded[index].has_value()) {
                loaded_.emplace(outpointKey(external[index].txid, external[index].vout), *loaded[index]);
            }
        }
    }

    std::optional<db::StoredUtxo> get(const messages::OutPoint& outpoint) const {
        const auto key = outpointKey(outpoint);
        if (spent_.contains(key)) {
            return std::nullopt;
        }
        const auto created = created_.find(key);
        if (created != created_.end()) {
            return created->second;
        }
        const auto loaded = loaded_.find(key);
        if (loaded != loaded_.end()) {
            return loaded->second;
        }
        return chainstate_.getUtxo(outpoint.hash, static_cast<int>(outpoint.index));
    }

    db::StoredUtxo spend(const messages::OutPoint& outpoint) {
        const auto key = outpointKey(outpoint);
        if (spent_.contains(key)) {
            throw ConnectBlockError("double spend of " + displayHex(outpoint.hash) + ":" +
                                    std::to_string(outpoint.index));
        }
        const auto utxo = get(outpoint);
        if (!utxo.has_value()) {
            throw ConnectBlockError("missing UTXO " + displayHex(outpoint.hash) + ":" +
                                    std::to_string(outpoint.index));
        }
        if (utxo->coinbase && height_ - utxo->height < kCoinbaseMaturity) {
            throw ConnectBlockError("coinbase output not mature at height " + std::to_string(height_) +
                                    " (created at " + std::to_string(utxo->height) + ")");
        }
        spent_.insert(key);
        if (!created_.contains(key)) {
            externalUndo_.push_back(*utxo);
        }
        return *utxo;
    }

    void create(const std::vector<std::uint8_t>& txid, int vout, std::int64_t value,
                const std::vector<std::uint8_t>& scriptPubkey, bool coinbase) {
        const auto key = outpointKey(txid, vout);
        if (created_.contains(key) || chainstate_.getUtxo(txid, vout).has_value()) {
            throw ConnectBlockError("duplicate UTXO " + displayHex(txid) + ":" + std::to_string(vout));
        }
        db::StoredUtxo utxo;
        utxo.txid = txid;
        utxo.vout = vout;
        utxo.height = height_;
        utxo.value = value;
        utxo.scriptPubkey = scriptPubkey;
        utxo.coinbase = coinbase;
        created_.emplace(key, std::move(utxo));
    }

    void apply() {
        for (const auto& key : spent_) {
            if (created_.contains(key)) {
                continue;
            }
            chainstate_.spendUtxo(keyTxidVector(key), static_cast<int>(key.vout));
        }
        for (const auto& [key, utxo] : created_) {
            if (spent_.contains(key)) {
                continue;
            }
            chainstate_.addUtxo(utxo.txid, utxo.vout, utxo.height, utxo.value, utxo.scriptPubkey, utxo.coinbase);
        }
    }

    const std::unordered_set<OutpointKey, OutpointKeyHash>& spent() const { return spent_; }
    const std::unordered_map<OutpointKey, db::StoredUtxo, OutpointKeyHash>& created() const { return created_; }
    const std::vector<db::StoredUtxo>& externalUndo() const { return externalUndo_; }
    int height() const { return height_; }

private:
    db::ChainstateStore& chainstate_;
    int height_;
    std::unordered_map<OutpointKey, db::StoredUtxo, OutpointKeyHash> created_;
    std::unordered_map<OutpointKey, db::StoredUtxo, OutpointKeyHash> loaded_;
    std::vector<db::StoredUtxo> externalUndo_;
    std::unordered_set<OutpointKey, OutpointKeyHash> spent_;
};

std::vector<db::StoredUtxo> externalSpendUndoEntries(const BlockUtxoView& view, db::ChainstateStore& chainstate) {
    (void)chainstate;
    return view.externalUndo();
}

void validateCoinbase(const messages::Transaction& coinbase, int height, std::int64_t totalFees) {
    try {
        validateBip34Height(coinbase, height);
    } catch (const CoinbaseError& exc) {
        throw ConnectBlockError(exc.what());
    }

    const auto subsidy = blockSubsidy(height);
    const auto allowed = subsidy + totalFees;
    std::int64_t outputTotal = 0;
    for (const auto& output : coinbase.outputs) {
        outputTotal += output.value;
    }
    if (outputTotal > allowed) {
        throw ConnectBlockError("coinbase value " + std::to_string(outputTotal) + " exceeds subsidy+fees " +
                                std::to_string(allowed) + " at height " + std::to_string(height));
    }
}

bool blockHasWitness(const Block& block) {
    for (const auto& tx : block.transactions) {
        if (!tx.witness.empty()) {
            return true;
        }
    }
    return false;
}

std::int64_t validateNonCoinbaseInputs(BlockUtxoView& view, const messages::Transaction& tx,
                                       script::ScriptVerifyRunner* runner, ConnectTiming* timing) {
    std::unordered_set<OutpointKey, OutpointKeyHash> seenPrevouts;
    std::vector<db::StoredUtxo> utxoInfos;
    utxoInfos.reserve(tx.inputs.size());

    for (const auto& txIn : tx.inputs) {
        const auto key = outpointKey(txIn.previousOutput);
        if (seenPrevouts.contains(key)) {
            throw ConnectBlockError("double spend of " + displayHex(txIn.previousOutput.hash) + ":" +
                                    std::to_string(txIn.previousOutput.index));
        }
        seenPrevouts.insert(key);

        const auto utxo = view.get(txIn.previousOutput);
        if (!utxo.has_value()) {
            throw ConnectBlockError("missing UTXO " + displayHex(txIn.previousOutput.hash) + ":" +
                                    std::to_string(txIn.previousOutput.index));
        }
        if (utxo->coinbase && view.height() - utxo->height < kCoinbaseMaturity) {
            throw ConnectBlockError("coinbase output not mature at height " + std::to_string(view.height()) +
                                    " (created at " + std::to_string(utxo->height) + ")");
        }
        utxoInfos.push_back(*utxo);
    }

    std::vector<std::pair<std::int64_t, std::vector<std::uint8_t>>> spentPrevouts;
    spentPrevouts.reserve(utxoInfos.size());
    for (const auto& utxo : utxoInfos) {
        spentPrevouts.emplace_back(utxo.value, utxo.scriptPubkey);
    }

    if (runner != nullptr && tx.inputs.size() > 1) {
        std::vector<script::VerifyInputJob> jobs;
        jobs.reserve(tx.inputs.size());
        for (std::size_t inputIndex = 0; inputIndex < tx.inputs.size(); ++inputIndex) {
            const auto& utxo = utxoInfos[inputIndex];
            jobs.push_back(script::VerifyInputJob{&tx, inputIndex, utxo.scriptPubkey, utxo.value, &spentPrevouts});
        }
        const auto result = runner->verify(jobs);
        if (timing != nullptr) {
            timing->scriptVerifyWorkerCpu += result.workerCpuUs;
        }
        if (result.error.has_value()) {
            throw ConnectBlockError(*result.error);
        }
    } else {
        for (std::size_t inputIndex = 0; inputIndex < tx.inputs.size(); ++inputIndex) {
            const auto& utxo = utxoInfos[inputIndex];
            try {
                script::verifyTransactionInput(tx, inputIndex, utxo.scriptPubkey, utxo.value, &spentPrevouts);
            } catch (const script::ScriptVerifyError& exc) {
                throw ConnectBlockError(exc.what());
            }
        }
    }

    std::int64_t inputTotal = 0;
    for (const auto& utxo : utxoInfos) {
        inputTotal += utxo.value;
    }

    for (const auto& txIn : tx.inputs) {
        view.spend(txIn.previousOutput);
    }

    return inputTotal;
}

void emitTiming(int height, const ConnectTiming& timing) {
    std::cerr << "cpbitnode_sync_timing"
              << " height=" << height
              << " unit=us"
              << " utxo_load=" << timing.utxoLoad
              << " script_verify=" << timing.scriptVerify
              << " script_verify_worker_cpu=" << timing.scriptVerifyWorkerCpu
              << " utxo_apply=" << timing.utxoApply
              << " commit=" << timing.commit
              << " block_connect_store_commit=" << timing.blockConnectStoreCommit
              << "\n";
}

}  // namespace detail

Block connectBlock(db::NodeStateStore& tracker, std::span<const std::uint8_t> payload,
                   const ConnectBlockOptions& options) {
    db::NodeStateChainstateStore chainstate(tracker);
    return connectBlock(tracker, chainstate, payload, options);
}

Block connectBlock(db::NodeStateStore& tracker, db::ChainstateStore& chainstate,
                   std::span<const std::uint8_t> payload, const ConnectBlockOptions& options) {
    const auto tip = chainstate.readTip(options.chainName);
    if (options.height != tip.height + 1) {
        throw ConnectBlockError("cannot connect height " + std::to_string(options.height) +
                                " on top of validated tip " + std::to_string(tip.height));
    }

    Block block;
    try {
        block = sync::validateBlock(payload, options.expectedPrev,
                                    options.hasExpectedHash ? &options.expectedHash : nullptr);
    } catch (const sync::BlockValidationError& exc) {
        throw ConnectBlockError(exc.what());
    }

    auto connected = connectDecodedBlock(tracker, chainstate, block, options);
    return connected;
}

Block connectDecodedBlock(db::NodeStateStore& tracker, db::ChainstateStore& chainstate, const Block& block,
                          const ConnectBlockOptions& options) {
    const auto fullStart = detail::Clock::now();
    const auto tip = chainstate.readTip(options.chainName);
    if (options.height != tip.height + 1) {
        throw ConnectBlockError("cannot connect height " + std::to_string(options.height) +
                                " on top of validated tip " + std::to_string(tip.height));
    }

    try {
        sync::validateDecodedBlock(block, options.expectedPrev, options.hasExpectedHash ? &options.expectedHash : nullptr);
    } catch (const sync::BlockValidationError& exc) {
        throw ConnectBlockError(exc.what());
    }

    detail::BlockUtxoView view(chainstate, options.height);
    detail::ConnectTiming timing;
    const bool timingEnabled = detail::syncTimingEnabled();
    std::vector<db::Outpoint> blockPrevouts;
    for (const auto& tx : block.transactions) {
        if (messages::transactionIsCoinbase(tx)) {
            continue;
        }
        for (const auto& txIn : tx.inputs) {
            blockPrevouts.push_back(db::Outpoint{txIn.previousOutput.hash, static_cast<int>(txIn.previousOutput.index)});
        }
    }
    auto timerStart = detail::Clock::now();
    view.preloadExternal(blockPrevouts);
    if (timingEnabled) {
        timing.utxoLoad += detail::elapsedUs(timerStart);
    }

    std::int64_t totalFees = 0;
    for (const auto& tx : block.transactions) {
        if (messages::transactionIsCoinbase(tx)) {
            continue;
        }
        timerStart = detail::Clock::now();
        const auto inputTotal = detail::validateNonCoinbaseInputs(view, tx, options.scriptRunner, &timing);
        if (timingEnabled) {
            timing.scriptVerify += detail::elapsedUs(timerStart);
        }
        std::int64_t outputTotal = 0;
        for (const auto& output : tx.outputs) {
            outputTotal += output.value;
        }
        if (inputTotal < outputTotal) {
            throw ConnectBlockError("transaction outputs exceed inputs");
        }
        totalFees += inputTotal - outputTotal;
        const auto txid = transactionTxid(tx);
        timerStart = detail::Clock::now();
        for (std::size_t index = 0; index < tx.outputs.size(); ++index) {
            if (!isSpendableOutput(tx.outputs[index].scriptPubkey)) {
                continue;
            }
            view.create(txid, static_cast<int>(index), tx.outputs[index].value, tx.outputs[index].scriptPubkey, false);
        }
        if (timingEnabled) {
            timing.utxoApply += detail::elapsedUs(timerStart);
        }
    }

    const auto& coinbase = block.transactions.front();
    detail::validateCoinbase(coinbase, options.height, totalFees);
    if (detail::blockHasWitness(block)) {
        try {
            validateWitnessCommitment(coinbase, block.transactions);
        } catch (const std::exception& exc) {
            throw ConnectBlockError(exc.what());
        }
    }

    const auto coinbaseTxid = transactionTxid(coinbase);
    timerStart = detail::Clock::now();
    for (std::size_t index = 0; index < coinbase.outputs.size(); ++index) {
        if (!isSpendableOutput(coinbase.outputs[index].scriptPubkey)) {
            continue;
        }
        view.create(coinbaseTxid, static_cast<int>(index), coinbase.outputs[index].value,
                    coinbase.outputs[index].scriptPubkey, true);
    }
    if (timingEnabled) {
        timing.utxoApply += detail::elapsedUs(timerStart);
    }

    timerStart = detail::Clock::now();
    db::BlockCommit commit;
    commit.chain = options.chainName;
    commit.height = options.height;
    commit.blockHash = block.header.blockHashHex();
    commit.blockIndex = options.blockIndex;
    commit.undo = detail::externalSpendUndoEntries(view, chainstate);
    for (const auto& key : view.spent()) {
        if (view.created().contains(key)) {
            continue;
        }
        commit.spends.push_back(db::Outpoint{detail::keyTxidVector(key), static_cast<int>(key.vout)});
    }
    for (const auto& [key, utxo] : view.created()) {
        if (view.spent().contains(key)) {
            continue;
        }
        commit.creates.push_back(
            db::UtxoCreate{utxo.txid, utxo.vout, utxo.height, utxo.value, utxo.scriptPubkey, utxo.coinbase});
    }
    if (timingEnabled) {
        timing.utxoApply += detail::elapsedUs(timerStart);
    }
    timerStart = detail::Clock::now();
    chainstate.commitBlock(commit);
    if (timingEnabled) {
        timing.commit += detail::elapsedUs(timerStart);
        timing.blockConnectStoreCommit = detail::elapsedUs(fullStart);
        detail::emitTiming(options.height, timing);
    }
    return block;
}

void disconnectBlock(db::NodeStateStore& tracker, int height, const chain::ChainParams& chain) {
    db::NodeStateChainstateStore chainstate(tracker);
    disconnectBlock(tracker, chainstate, height, chain);
}

void disconnectBlock(db::NodeStateStore& tracker, db::ChainstateStore& chainstate, int height,
                     const chain::ChainParams& chain) {
    const std::string chainName = chain.name;
    const int validated = chainstate.readTip(chainName).height;
    if (validated != height) {
        throw ConnectBlockError("cannot disconnect height " + std::to_string(height) + ": validated tip is " +
                                std::to_string(validated));
    }
    if (height < 1) {
        throw ConnectBlockError("cannot disconnect genesis (height < 1)");
    }
    const auto prevHashHex = tracker.getHeaderHash(height - 1);
    if (!prevHashHex.has_value()) {
        throw ConnectBlockError("missing header at height " + std::to_string(height - 1));
    }

    std::vector<db::StoredUtxo> undoEntries;
    try {
        undoEntries = chainstate.takeUtxoUndo(chainName, height);
    } catch (const std::runtime_error&) {
        throw ConnectBlockError("missing UTXO undo data for height " + std::to_string(height) +
                                "; reconnect this block or replay the chain (undo is recorded during connect)");
    }

    chainstate.deleteUtxosCreatedAtHeight(height);
    for (const auto& entry : undoEntries) {
        chainstate.addUtxo(entry.txid, entry.vout, entry.height, entry.value, entry.scriptPubkey, entry.coinbase);
    }
    chainstate.setTip(chainName, height - 1, *prevHashHex);
}

namespace connect_test_access {

std::int64_t validateNonCoinbaseInputs(db::NodeStateStore& tracker, int height,
                                       const messages::Transaction& tx) {
    db::NodeStateChainstateStore chainstate(tracker);
    detail::BlockUtxoView view(chainstate, height);
    return detail::validateNonCoinbaseInputs(view, tx, nullptr, nullptr);
}

void validateCoinbaseAtHeight(const messages::Transaction& coinbase, int height, std::int64_t totalFees) {
    detail::validateCoinbase(coinbase, height, totalFees);
}

}  // namespace connect_test_access

}  // namespace cpbitnode::consensus
