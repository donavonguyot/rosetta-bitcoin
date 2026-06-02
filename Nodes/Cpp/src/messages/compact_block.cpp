#include "cpbitnode/messages/compact_block.hpp"

#include "cpbitnode/consensus/witness.hpp"
#include "cpbitnode/messages/bip152_short_txid.hpp"
#include "cpbitnode/wire/serialize.hpp"

#include <algorithm>
#include <sstream>
#include <stdexcept>

namespace cpbitnode::messages {
namespace {

std::vector<std::pair<std::uint64_t, std::vector<std::uint8_t>>> compactNonPrefilledShortidSlots(
    const CompactBlockMessage& compact) {
    const auto nShort = compact.shortids.size();
    const auto nPf = compact.prefilled.size();
    const auto total = nShort + nPf;

    std::map<std::uint64_t, Transaction> prefilledByIndex;
    for (const auto& pf : compact.prefilled) {
        prefilledByIndex.emplace(pf.index, pf.tx);
    }
    if (prefilledByIndex.size() != nPf) {
        throw std::runtime_error("duplicate prefilled transaction index in compact block");
    }
    for (const auto& [idx, _] : prefilledByIndex) {
        if (idx >= total) {
            throw std::runtime_error("prefilled index out of range for reconstructed block tx count");
        }
    }

    std::size_t slotsNeedingSid = 0;
    for (std::size_t pos = 0; pos < total; ++pos) {
        if (prefilledByIndex.find(pos) == prefilledByIndex.end()) {
            ++slotsNeedingSid;
        }
    }
    if (slotsNeedingSid != nShort) {
        throw std::runtime_error("prefilled gaps do not align with compact shortid vector length");
    }

    std::vector<std::pair<std::uint64_t, std::vector<std::uint8_t>>> gaps;
    gaps.reserve(nShort);
    std::size_t shortIndex = 0;
    for (std::size_t pos = 0; pos < total; ++pos) {
        if (prefilledByIndex.contains(pos)) {
            continue;
        }
        if (shortIndex >= nShort) {
            throw std::runtime_error("not enough shortids for non-prefilled block positions");
        }
        gaps.emplace_back(pos, compact.shortids[shortIndex]);
        ++shortIndex;
    }
    if (shortIndex != nShort) {
        throw std::runtime_error("too many shortids for reconstructed block transaction count");
    }
    return gaps;
}

bool wtxidEqual(const Transaction& left, const Transaction& right) {
    return consensus::transactionWtxid(left) == consensus::transactionWtxid(right);
}

}  // namespace

std::vector<std::uint8_t> bitcoinShortTransactionId(const BlockHeader& header,
                                                    std::uint64_t shortIdNonce,
                                                    const Transaction& tx) {
    const auto [k0, k1] = shortIdNonceKey(header, shortIdNonce);
    return presaltedShortIdFromUint256Digest(k0, k1, consensus::transactionWtxid(tx));
}

std::vector<Transaction> reconstructCompactTransactions(const CompactBlockMessage& compact,
                                                        const CompactShortIdMap& txsByShortid) {
    const auto total = compact.shortids.size() + compact.prefilled.size();
    std::map<std::uint64_t, Transaction> prefilledByIndex;
    for (const auto& pf : compact.prefilled) {
        prefilledByIndex.emplace(pf.index, pf.tx);
    }
    const auto gaps = compactNonPrefilledShortidSlots(compact);

    std::vector<Transaction> txsOut;
    txsOut.reserve(total);
    std::size_t gapIndex = 0;
    for (std::size_t pos = 0; pos < total; ++pos) {
        const auto prefilled = prefilledByIndex.find(pos);
        if (prefilled != prefilledByIndex.end()) {
            txsOut.push_back(prefilled->second);
            continue;
        }
        const auto& sid = gaps[gapIndex].second;
        ++gapIndex;
        const auto tx = txsByShortid.find(sid);
        if (tx == txsByShortid.end()) {
            std::ostringstream oss;
            oss << "missing compact short ID for block position " << pos;
            throw std::runtime_error(oss.str());
        }
        txsOut.push_back(tx->second);
    }
    return txsOut;
}

std::vector<std::uint8_t> serializeBlockWire(const BlockHeader& header,
                                              std::span<const Transaction> transactions) {
    std::vector<std::uint8_t> payload = header.serialize();
    const auto txCount = wire::writeVarint(transactions.size());
    payload.insert(payload.end(), txCount.begin(), txCount.end());
    const bool witnessBlock =
        std::any_of(transactions.begin(), transactions.end(),
                    [](const Transaction& tx) { return !tx.witness.empty(); });
    if (witnessBlock) {
        payload.push_back(kWitnessMarker0);
        payload.push_back(kWitnessMarker1);
    }
    for (const auto& tx : transactions) {
        const auto txBytes = tx.serialize(witnessBlock);
        payload.insert(payload.end(), txBytes.begin(), txBytes.end());
    }
    return payload;
}

std::vector<std::uint8_t> reconstructCompactBlockWire(const CompactBlockMessage& compact,
                                                      const CompactShortIdMap& txsByShortid) {
    return serializeBlockWire(compact.header, reconstructCompactTransactions(compact, txsByShortid));
}

std::optional<CompactShortIdMap> mempoolShortIdTransactionMap(const CompactBlockMessage& compact,
                                                              std::span<const Transaction> pooledTransactions) {
    CompactShortIdMap bySid;
    for (const auto& tx : pooledTransactions) {
        const auto sid = bitcoinShortTransactionId(compact.header, compact.shortIdNonce, tx);
        const auto existing = bySid.find(sid);
        if (existing == bySid.end()) {
            bySid.emplace(sid, tx);
        } else if (!wtxidEqual(existing->second, tx)) {
            return std::nullopt;
        }
    }
    return bySid;
}

std::optional<std::vector<std::uint64_t>> missingIndexesForGetblocktxn(const CompactBlockMessage& compact,
                                                                       const CompactShortIdMap& txsByShortid) {
    try {
        const auto gaps = compactNonPrefilledShortidSlots(compact);
        std::vector<std::uint64_t> missing;
        for (const auto& [pos, sid] : gaps) {
            if (txsByShortid.find(sid) == txsByShortid.end()) {
                missing.push_back(pos);
            }
        }
        std::sort(missing.begin(), missing.end());
        return missing;
    } catch (const std::runtime_error&) {
        return std::nullopt;
    }
}

std::optional<std::vector<Transaction>> tryReconstructCompactBlock(
    const CompactBlockMessage& compact,
    std::span<const Transaction> pooledTransactions) {
    const auto bySid = mempoolShortIdTransactionMap(compact, pooledTransactions);
    if (!bySid.has_value()) {
        return std::nullopt;
    }
    const auto missing = missingIndexesForGetblocktxn(compact, *bySid);
    if (!missing.has_value() || !missing->empty()) {
        return std::nullopt;
    }
    try {
        return reconstructCompactTransactions(compact, *bySid);
    } catch (const std::runtime_error&) {
        return std::nullopt;
    }
}

std::optional<std::vector<Transaction>> completeCompactWithBlockTransactions(
    const CompactBlockMessage& compact,
    const CompactShortIdMap& poolMap,
    std::span<const std::uint64_t> indexesRequestedSorted,
    std::span<const Transaction> replyTransactions) {
    try {
        const auto gaps = compactNonPrefilledShortidSlots(compact);
        std::map<std::uint64_t, std::vector<std::uint8_t>> idxToSid;
        for (const auto& [pos, sid] : gaps) {
            idxToSid.emplace(pos, sid);
        }

        std::vector<std::uint64_t> indexes(indexesRequestedSorted.begin(), indexesRequestedSorted.end());
        std::sort(indexes.begin(), indexes.end());
        if (indexes.size() != replyTransactions.size()) {
            return std::nullopt;
        }

        CompactShortIdMap merged = poolMap;
        for (std::size_t i = 0; i < indexes.size(); ++i) {
            const auto pos = indexes[i];
            const auto expectedSid = idxToSid.find(pos);
            if (expectedSid == idxToSid.end()) {
                return std::nullopt;
            }
            const auto computed = bitcoinShortTransactionId(compact.header, compact.shortIdNonce, replyTransactions[i]);
            if (computed != expectedSid->second) {
                return std::nullopt;
            }
            merged[expectedSid->second] = replyTransactions[i];
        }
        return reconstructCompactTransactions(compact, merged);
    } catch (const std::runtime_error&) {
        return std::nullopt;
    }
}

std::vector<std::uint8_t> CompactBlockMessage::serialize() const {
    std::vector<std::uint8_t> payload = header.serialize();
    const auto nonceBytes = wire::packUint64Le(shortIdNonce);
    payload.insert(payload.end(), nonceBytes.begin(), nonceBytes.end());
    const auto shortCount = wire::writeVarint(shortids.size());
    payload.insert(payload.end(), shortCount.begin(), shortCount.end());
    for (const auto& sid : shortids) {
        if (sid.size() != 6) {
            throw std::runtime_error("each shortid must be exactly 6 bytes");
        }
        payload.insert(payload.end(), sid.begin(), sid.end());
    }
    const auto prefilledCount = wire::writeVarint(prefilled.size());
    payload.insert(payload.end(), prefilledCount.begin(), prefilledCount.end());
    std::int64_t prevIndex = -1;
    for (std::size_t i = 0; i < prefilled.size(); ++i) {
        const auto diff = i == 0 ? static_cast<std::int64_t>(prefilled[i].index)
                                 : static_cast<std::int64_t>(prefilled[i].index) - prevIndex - 1;
        if (diff < 0) {
            throw std::runtime_error("prefilled transactions must be ordered by increasing index");
        }
        const auto diffBytes = wire::writeVarint(static_cast<std::uint64_t>(diff));
        payload.insert(payload.end(), diffBytes.begin(), diffBytes.end());
        const auto txBytes = prefilled[i].tx.serialize(true);
        payload.insert(payload.end(), txBytes.begin(), txBytes.end());
        prevIndex = static_cast<std::int64_t>(prefilled[i].index);
    }
    return payload;
}

CompactBlockMessage CompactBlockMessage::deserialize(std::span<const std::uint8_t> payload) {
    if (payload.size() < 88) {
        throw std::runtime_error("cmpctblock too short for header and short_id_nonce");
    }
    auto [header, offset] = deserializeBlockHeader(payload, 0);
    auto [shortIdNonce, afterNonce] = wire::unpackUint64Le(payload, offset);
    offset = afterNonce;
    auto [nShort, afterShortCount] = wire::readVarint(payload, offset);
    const auto needShort = nShort * 6;
    if (afterShortCount + needShort > payload.size()) {
        throw std::runtime_error("cmpctblock shortid bytes truncated");
    }
    std::vector<std::vector<std::uint8_t>> shortids;
    shortids.reserve(static_cast<std::size_t>(nShort));
    for (std::uint64_t i = 0; i < nShort; ++i) {
        const auto start = afterShortCount + i * 6;
        shortids.emplace_back(payload.begin() + static_cast<std::ptrdiff_t>(start),
                              payload.begin() + static_cast<std::ptrdiff_t>(start + 6));
    }
    offset = afterShortCount + needShort;
    auto [nPrefill, afterPrefillCount] = wire::readVarint(payload, offset);
    offset = afterPrefillCount;
    std::vector<PrefilledTransaction> prefilled;
    prefilled.reserve(static_cast<std::size_t>(nPrefill));
    std::int64_t prevAbs = -1;
    for (std::uint64_t i = 0; i < nPrefill; ++i) {
        auto [delta, afterDelta] = wire::readVarint(payload, offset);
        offset = afterDelta;
        const auto absIndex = prefilled.empty() ? delta : static_cast<std::uint64_t>(prevAbs + 1 + delta);
        if (static_cast<std::int64_t>(absIndex) <= prevAbs) {
            throw std::runtime_error("prefilled transaction indices must be strictly increasing");
        }
        auto [tx, afterTx] = deserializeTransaction(payload, offset);
        offset = afterTx;
        prefilled.push_back(PrefilledTransaction{absIndex, std::move(tx)});
        prevAbs = static_cast<std::int64_t>(absIndex);
    }
    if (offset != payload.size()) {
        throw std::runtime_error("trailing bytes after cmpctblock");
    }
    return CompactBlockMessage{std::move(header), shortIdNonce, std::move(shortids), std::move(prefilled)};
}

std::vector<std::uint8_t> GetBlockTxnMessage::serialize() const {
    if (blockHash.size() != 32) {
        throw std::runtime_error("block hash must be 32 bytes");
    }
    std::vector<std::uint8_t> payload = blockHash;
    const auto count = wire::writeVarint(txnIndexes.size());
    payload.insert(payload.end(), count.begin(), count.end());
    for (const auto index : txnIndexes) {
        const auto indexBytes = wire::writeVarint(index);
        payload.insert(payload.end(), indexBytes.begin(), indexBytes.end());
    }
    return payload;
}

GetBlockTxnMessage GetBlockTxnMessage::deserialize(std::span<const std::uint8_t> payload) {
    if (payload.size() < 32) {
        throw std::runtime_error("getblocktxn payload too short for block hash");
    }
    GetBlockTxnMessage message;
    message.blockHash.assign(payload.begin(), payload.begin() + 32);
    auto [count, offset] = wire::readVarint(payload, 32);
    message.txnIndexes.reserve(static_cast<std::size_t>(count));
    for (std::uint64_t i = 0; i < count; ++i) {
        auto [index, next] = wire::readVarint(payload, offset);
        offset = next;
        message.txnIndexes.push_back(index);
    }
    if (offset != payload.size()) {
        throw std::runtime_error("trailing bytes after getblocktxn indexes");
    }
    return message;
}

bool GetBlockTxnMessage::operator==(const GetBlockTxnMessage& other) const {
    return blockHash == other.blockHash && txnIndexes == other.txnIndexes;
}

std::vector<std::uint8_t> BlockTxnMessage::serialize() const {
    if (blockHash.size() != 32) {
        throw std::runtime_error("block hash must be 32 bytes");
    }
    const bool witnessMode =
        std::any_of(transactions.begin(), transactions.end(),
                    [](const Transaction& tx) { return !tx.witness.empty(); });
    std::vector<std::uint8_t> payload = blockHash;
    const auto count = wire::writeVarint(transactions.size());
    payload.insert(payload.end(), count.begin(), count.end());
    for (const auto& tx : transactions) {
        const auto txBytes = tx.serialize(witnessMode);
        payload.insert(payload.end(), txBytes.begin(), txBytes.end());
    }
    return payload;
}

BlockTxnMessage BlockTxnMessage::deserialize(std::span<const std::uint8_t> payload) {
    if (payload.size() < 32) {
        throw std::runtime_error("blocktxn payload too short for block hash");
    }
    BlockTxnMessage message;
    message.blockHash.assign(payload.begin(), payload.begin() + 32);
    auto [count, offset] = wire::readVarint(payload, 32);
    message.transactions.reserve(static_cast<std::size_t>(count));
    for (std::uint64_t i = 0; i < count; ++i) {
        auto [tx, next] = deserializeTransaction(payload, offset);
        offset = next;
        message.transactions.push_back(std::move(tx));
    }
    if (offset != payload.size()) {
        throw std::runtime_error("trailing bytes after blocktxn transactions");
    }
    return message;
}

}  // namespace cpbitnode::messages
