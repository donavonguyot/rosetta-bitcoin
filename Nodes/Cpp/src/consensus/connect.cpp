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
#include <set>
#include <sstream>
#include <unordered_map>
#include <utility>

namespace cpbitnode::consensus {
namespace detail {

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
    std::vector<std::uint8_t> txid;
    std::uint32_t vout = 0;

    bool operator==(const OutpointKey& other) const { return vout == other.vout && txid == other.txid; }
    bool operator<(const OutpointKey& other) const {
        if (txid != other.txid) {
            return txid < other.txid;
        }
        return vout < other.vout;
    }
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
    return {outpoint.hash, outpoint.index};
}

class BlockUtxoView {
public:
    BlockUtxoView(db::ChainstateStore& chainstate, int height) : chainstate_(chainstate), height_(height) {}

    std::optional<db::StoredUtxo> get(const messages::OutPoint& outpoint) const {
        const auto key = outpointKey(outpoint);
        if (spent_.contains(key)) {
            return std::nullopt;
        }
        const auto created = created_.find(key);
        if (created != created_.end()) {
            return created->second;
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
        return *utxo;
    }

    void create(const std::vector<std::uint8_t>& txid, int vout, std::int64_t value,
                const std::vector<std::uint8_t>& scriptPubkey, bool coinbase) {
        const OutpointKey key{txid, static_cast<std::uint32_t>(vout)};
        if (created_.contains(key) || chainstate_.getUtxo(txid, vout).has_value()) {
            throw ConnectBlockError("duplicate UTXO " + displayHex(txid) + ":" + std::to_string(vout));
        }
        db::StoredUtxo utxo;
        utxo.txid = displayHex(txid);
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
            chainstate_.spendUtxo(key.txid, static_cast<int>(key.vout));
        }
        for (const auto& [key, utxo] : created_) {
            if (spent_.contains(key)) {
                continue;
            }
            std::vector<std::uint8_t> txid;
            txid.reserve(32);
            for (std::size_t index = 0; index + 1 < utxo.txid.size(); index += 2) {
                txid.push_back(static_cast<std::uint8_t>(std::stoi(utxo.txid.substr(index, 2), nullptr, 16)));
            }
            std::reverse(txid.begin(), txid.end());
            chainstate_.addUtxo(txid, utxo.vout, utxo.height, utxo.value, utxo.scriptPubkey, utxo.coinbase);
        }
    }

    const std::set<OutpointKey>& spent() const { return spent_; }
    const std::unordered_map<OutpointKey, db::StoredUtxo, OutpointKeyHash>& created() const { return created_; }
    int height() const { return height_; }

private:
    db::ChainstateStore& chainstate_;
    int height_;
    std::unordered_map<OutpointKey, db::StoredUtxo, OutpointKeyHash> created_;
    std::set<OutpointKey> spent_;
};

std::vector<db::StoredUtxo> externalSpendUndoEntries(const BlockUtxoView& view, db::ChainstateStore& chainstate) {
    std::vector<db::StoredUtxo> entries;
    for (const auto& key : view.spent()) {
        if (view.created().contains(key)) {
            continue;
        }
        const auto utxo = chainstate.getUtxo(key.txid, static_cast<int>(key.vout));
        if (!utxo.has_value()) {
            throw ConnectBlockError("internal error: could not capture undo for " + displayHex(key.txid) + ":" +
                                    std::to_string(key.vout));
        }
        entries.push_back(*utxo);
    }
    return entries;
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

std::int64_t validateNonCoinbaseInputs(BlockUtxoView& view, const messages::Transaction& tx) {
    std::set<OutpointKey> seenPrevouts;
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

    std::int64_t inputTotal = 0;
    for (std::size_t inputIndex = 0; inputIndex < tx.inputs.size(); ++inputIndex) {
        const auto& utxo = utxoInfos[inputIndex];
        try {
            script::verifyTransactionInput(tx, inputIndex, utxo.scriptPubkey, utxo.value, &spentPrevouts);
        } catch (const script::ScriptVerifyError& exc) {
            throw ConnectBlockError(exc.what());
        }
        inputTotal += utxo.value;
    }

    for (const auto& txIn : tx.inputs) {
        view.spend(txIn.previousOutput);
    }

    return inputTotal;
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

    detail::BlockUtxoView view(chainstate, options.height);
    std::int64_t totalFees = 0;
    for (const auto& tx : block.transactions) {
        if (messages::transactionIsCoinbase(tx)) {
            continue;
        }
        const auto inputTotal = detail::validateNonCoinbaseInputs(view, tx);
        std::int64_t outputTotal = 0;
        for (const auto& output : tx.outputs) {
            outputTotal += output.value;
        }
        if (inputTotal < outputTotal) {
            throw ConnectBlockError("transaction outputs exceed inputs");
        }
        totalFees += inputTotal - outputTotal;
        const auto txid = transactionTxid(tx);
        for (std::size_t index = 0; index < tx.outputs.size(); ++index) {
            if (!isSpendableOutput(tx.outputs[index].scriptPubkey)) {
                continue;
            }
            view.create(txid, static_cast<int>(index), tx.outputs[index].value, tx.outputs[index].scriptPubkey, false);
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
    for (std::size_t index = 0; index < coinbase.outputs.size(); ++index) {
        if (!isSpendableOutput(coinbase.outputs[index].scriptPubkey)) {
            continue;
        }
        view.create(coinbaseTxid, static_cast<int>(index), coinbase.outputs[index].value,
                    coinbase.outputs[index].scriptPubkey, true);
    }

    const auto undoEntries = detail::externalSpendUndoEntries(view, chainstate);
    chainstate.replaceUtxoUndo(options.chainName, options.height, undoEntries);
    view.apply();
    chainstate.setTip(options.chainName, options.height, block.header.blockHashHex());
    metrics::incrMetaCounter(tracker, metrics::kMetaBlocksValidatedTotal);
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
        std::vector<std::uint8_t> txid;
        txid.reserve(32);
        for (std::size_t index = 0; index + 1 < entry.txid.size(); index += 2) {
            txid.push_back(static_cast<std::uint8_t>(std::stoi(entry.txid.substr(index, 2), nullptr, 16)));
        }
        std::reverse(txid.begin(), txid.end());
        chainstate.addUtxo(txid, entry.vout, entry.height, entry.value, entry.scriptPubkey, entry.coinbase);
    }
    chainstate.setTip(chainName, height - 1, *prevHashHex);
}

namespace connect_test_access {

std::int64_t validateNonCoinbaseInputs(db::NodeStateStore& tracker, int height,
                                       const messages::Transaction& tx) {
    db::NodeStateChainstateStore chainstate(tracker);
    detail::BlockUtxoView view(chainstate, height);
    return detail::validateNonCoinbaseInputs(view, tx);
}

void validateCoinbaseAtHeight(const messages::Transaction& coinbase, int height, std::int64_t totalFees) {
    detail::validateCoinbase(coinbase, height, totalFees);
}

}  // namespace connect_test_access

}  // namespace cpbitnode::consensus
