#include "cpbitnode/consensus/script/sighash.hpp"

#include "cpbitnode/consensus/hash.hpp"
#include "cpbitnode/consensus/sha256.hpp"
#include "cpbitnode/wire/serialize.hpp"

#include <algorithm>
#include <cstring>
#include <stdexcept>

namespace cpbitnode::consensus::script {
namespace {

bool taprootAllowedHashtypes(int hashType) {
    return hashType <= 0x03 || (0x81 <= hashType && hashType <= 0x83);
}

std::vector<std::uint8_t> sha256Concat(const std::vector<std::vector<std::uint8_t>>& parts) {
    std::vector<std::uint8_t> joined;
    for (const auto& p : parts) {
        joined.insert(joined.end(), p.begin(), p.end());
    }
    return sha256Digest(joined);
}

std::vector<std::uint8_t> taprootAnnexDigest(const std::vector<std::uint8_t>& annex) {
    auto blob = wire::writeVarint(annex.size());
    blob.insert(blob.end(), annex.begin(), annex.end());
    return sha256Digest(blob);
}

const std::vector<std::uint8_t>& zeroHash() {
    static const std::vector<std::uint8_t> kZero(32, 0x00);
    return kZero;
}

}  // namespace

SighashCache::SighashCache(
    const messages::Transaction& transaction,
    const std::vector<std::pair<std::int64_t, std::vector<std::uint8_t>>>* spentPrevouts)
    : bip143HashPrevouts_(zeroHash()),
      bip143HashSequence_(zeroHash()),
      bip143HashOutputs_(zeroHash()),
      taprootHashPrevouts_(zeroHash()),
      taprootHashAmounts_(zeroHash()),
      taprootHashScriptPubkeys_(zeroHash()),
      taprootHashSequences_(zeroHash()),
      taprootHashOutputs_(zeroHash()) {
    std::vector<std::uint8_t> prevouts;
    prevouts.reserve(transaction.inputs.size() * 36);
    std::vector<std::uint8_t> sequences;
    sequences.reserve(transaction.inputs.size() * 4);
    for (const auto& txIn : transaction.inputs) {
        const auto prevSer = txIn.previousOutput.serialize();
        prevouts.insert(prevouts.end(), prevSer.begin(), prevSer.end());
        const auto seq = wire::packUint32Le(txIn.sequence);
        sequences.insert(sequences.end(), seq.begin(), seq.end());
    }
    bip143HashPrevouts_ = doubleSha256(prevouts);
    bip143HashSequence_ = doubleSha256(sequences);

    std::vector<std::uint8_t> outputs;
    bip143HashSingle_.reserve(transaction.outputs.size());
    taprootHashSingle_.reserve(transaction.outputs.size());
    for (const auto& output : transaction.outputs) {
        const auto ser = output.serialize();
        outputs.insert(outputs.end(), ser.begin(), ser.end());
        bip143HashSingle_.push_back(doubleSha256(ser));
        taprootHashSingle_.push_back(sha256Digest(ser));
    }
    bip143HashOutputs_ = doubleSha256(outputs);
    taprootHashOutputs_ = sha256Digest(outputs);

    if (spentPrevouts == nullptr || spentPrevouts->size() != transaction.inputs.size()) {
        return;
    }

    taprootReady_ = true;
    std::vector<std::uint8_t> amounts;
    std::vector<std::uint8_t> scriptPubkeys;
    amounts.reserve(spentPrevouts->size() * 8);
    for (std::size_t index = 0; index < spentPrevouts->size(); ++index) {
        const auto amt = wire::packInt64Le((*spentPrevouts)[index].first);
        amounts.insert(amounts.end(), amt.begin(), amt.end());
        const auto& script = (*spentPrevouts)[index].second;
        auto scriptLen = wire::writeVarint(script.size());
        scriptPubkeys.insert(scriptPubkeys.end(), scriptLen.begin(), scriptLen.end());
        scriptPubkeys.insert(scriptPubkeys.end(), script.begin(), script.end());
    }
    taprootHashPrevouts_ = sha256Digest(prevouts);
    taprootHashAmounts_ = sha256Digest(amounts);
    taprootHashScriptPubkeys_ = sha256Digest(scriptPubkeys);
    taprootHashSequences_ = sha256Digest(sequences);
}

const std::vector<std::uint8_t>& SighashCache::bip143HashSingle(std::size_t outputIndex) const {
    if (outputIndex >= bip143HashSingle_.size()) {
        return zeroHash();
    }
    return bip143HashSingle_[outputIndex];
}

const std::vector<std::uint8_t>& SighashCache::taprootHashSingle(std::size_t outputIndex) const {
    if (outputIndex >= taprootHashSingle_.size()) {
        return zeroHash();
    }
    return taprootHashSingle_[outputIndex];
}

std::vector<std::uint8_t> bitcoinTaggedHash(const std::string& tag, std::span<const std::uint8_t> msg) {
    const auto tagDigest = sha256Digest(std::span<const std::uint8_t>(
        reinterpret_cast<const std::uint8_t*>(tag.data()), tag.size()));
    std::vector<std::uint8_t> payload;
    payload.insert(payload.end(), tagDigest.begin(), tagDigest.end());
    payload.insert(payload.end(), tagDigest.begin(), tagDigest.end());
    payload.insert(payload.end(), msg.begin(), msg.end());
    return sha256Digest(payload);
}

std::vector<std::uint8_t> tapleafHash(int leafVersion, std::span<const std::uint8_t> tapscriptBytes) {
    std::vector<std::uint8_t> msg = {static_cast<std::uint8_t>(leafVersion & 0xFF)};
    auto len = wire::writeVarint(tapscriptBytes.size());
    msg.insert(msg.end(), len.begin(), len.end());
    msg.insert(msg.end(), tapscriptBytes.begin(), tapscriptBytes.end());
    return bitcoinTaggedHash("TapLeaf", msg);
}

std::vector<std::uint8_t> tapbranchHash(std::span<const std::uint8_t, 32> left,
                                          std::span<const std::uint8_t, 32> right) {
    std::vector<std::uint8_t> pair;
    if (std::lexicographical_compare(left.begin(), left.end(), right.begin(), right.end())) {
        pair.insert(pair.end(), left.begin(), left.end());
        pair.insert(pair.end(), right.begin(), right.end());
    } else {
        pair.insert(pair.end(), right.begin(), right.end());
        pair.insert(pair.end(), left.begin(), left.end());
    }
    return bitcoinTaggedHash("TapBranch", pair);
}

std::vector<std::uint8_t> taprootTweakPubkeyHash(std::span<const std::uint8_t, 32> internalPubkeyXonly,
                                                 std::span<const std::uint8_t> merkleRoot) {
    std::vector<std::uint8_t> msg(internalPubkeyXonly.begin(), internalPubkeyXonly.end());
    msg.insert(msg.end(), merkleRoot.begin(), merkleRoot.end());
    return bitcoinTaggedHash("TapTweak", msg);
}

std::vector<std::uint8_t> taprootMerkleRootFromBranch(
    const std::vector<std::vector<std::uint8_t>>& branchNodes, std::span<const std::uint8_t, 32> leafHash) {
    std::array<std::uint8_t, 32> k{};
    std::memcpy(k.data(), leafHash.data(), 32);
    for (const auto& sibling : branchNodes) {
        if (sibling.size() != 32) {
            throw std::runtime_error("invalid merkle branch node");
        }
        const auto h = tapbranchHash(k, std::span<const std::uint8_t, 32>(sibling.data(), 32));
        std::memcpy(k.data(), h.data(), 32);
    }
    return std::vector<std::uint8_t>(k.begin(), k.end());
}

std::vector<std::uint8_t> serializedWitnessStackBytes(const std::vector<std::vector<std::uint8_t>>& stack) {
    auto blob = wire::writeVarint(stack.size());
    for (const auto& item : stack) {
        auto itemLen = wire::writeVarint(item.size());
        blob.insert(blob.end(), itemLen.begin(), itemLen.end());
        blob.insert(blob.end(), item.begin(), item.end());
    }
    return blob;
}

std::vector<std::uint8_t> taprootSignatureHash(
    const messages::Transaction& transaction, std::size_t inputIndex,
    const std::vector<std::pair<std::int64_t, std::vector<std::uint8_t>>>& spentPrevouts, int hashType,
    const std::vector<std::uint8_t>* annex, int extFlag, std::span<const std::uint8_t> tapleafHashBytes,
    std::uint32_t tapscriptCodeseparatorPos, const SighashCache* cache) {
    if (spentPrevouts.size() != transaction.inputs.size()) {
        throw std::runtime_error("spent_prevouts length mismatch");
    }
    if (!taprootAllowedHashtypes(hashType)) {
        throw std::runtime_error("unsupported taproot sighash type");
    }
    const bool annexPresent = annex != nullptr;
    if (extFlag != 0 && extFlag != 1) {
        throw std::runtime_error("invalid taproot ext_flag");
    }
    if (extFlag == 1 && tapleafHashBytes.size() != 32) {
        throw std::runtime_error("tapscript sighash requires 32-byte tapleaf_hash");
    }

    const std::array<std::uint8_t, 1> epoch = {0};
    const int outputMode =
        hashType == TAPROOT_SIGHASH_DEFAULT ? TAPROOT_SIGHASH_ALL : (hashType & 0x03);
    const bool anyoneCanPay = (hashType & 0x80) != 0;

    std::vector<std::uint8_t> body = {static_cast<std::uint8_t>(hashType)};
    auto version = wire::packInt32Le(transaction.version);
    body.insert(body.end(), version.begin(), version.end());
    auto lock = wire::packUint32Le(transaction.lockTime);
    body.insert(body.end(), lock.begin(), lock.end());

    if (!anyoneCanPay && cache != nullptr && cache->hasTaprootPrevouts()) {
        body.insert(body.end(), cache->taprootHashPrevouts().begin(), cache->taprootHashPrevouts().end());
        body.insert(body.end(), cache->taprootHashAmounts().begin(), cache->taprootHashAmounts().end());
        body.insert(body.end(), cache->taprootHashScriptPubkeys().begin(), cache->taprootHashScriptPubkeys().end());
        body.insert(body.end(), cache->taprootHashSequences().begin(), cache->taprootHashSequences().end());
    } else if (!anyoneCanPay) {
        std::vector<std::uint8_t> prevBlob;
        std::vector<std::uint8_t> amountsBlob;
        std::vector<std::uint8_t> scriptBlob;
        std::vector<std::uint8_t> sequencesBlob;
        for (std::size_t i = 0; i < transaction.inputs.size(); ++i) {
            const auto ser = transaction.inputs[i].previousOutput.serialize();
            prevBlob.insert(prevBlob.end(), ser.begin(), ser.end());
            const auto amt = wire::packInt64Le(spentPrevouts[i].first);
            amountsBlob.insert(amountsBlob.end(), amt.begin(), amt.end());
            const auto& pk = spentPrevouts[i].second;
            auto pkLen = wire::writeVarint(pk.size());
            scriptBlob.insert(scriptBlob.end(), pkLen.begin(), pkLen.end());
            scriptBlob.insert(scriptBlob.end(), pk.begin(), pk.end());
            const auto seq = wire::packUint32Le(transaction.inputs[i].sequence);
            sequencesBlob.insert(sequencesBlob.end(), seq.begin(), seq.end());
        }
        const auto h1 = sha256Concat({prevBlob});
        body.insert(body.end(), h1.begin(), h1.end());
        const auto h2 = sha256Concat({amountsBlob});
        body.insert(body.end(), h2.begin(), h2.end());
        const auto h3 = sha256Concat({scriptBlob});
        body.insert(body.end(), h3.begin(), h3.end());
        const auto h4 = sha256Concat({sequencesBlob});
        body.insert(body.end(), h4.begin(), h4.end());
    } else if (inputIndex >= transaction.inputs.size()) {
        throw std::runtime_error("input_index out of range");
    }

    if (outputMode == TAPROOT_SIGHASH_ALL && cache != nullptr) {
        body.insert(body.end(), cache->taprootHashOutputs().begin(), cache->taprootHashOutputs().end());
    } else if (outputMode == TAPROOT_SIGHASH_ALL) {
        std::vector<std::uint8_t> outsBlob;
        for (const auto& out : transaction.outputs) {
            const auto ser = out.serialize();
            outsBlob.insert(outsBlob.end(), ser.begin(), ser.end());
        }
        const auto h = sha256Concat({outsBlob});
        body.insert(body.end(), h.begin(), h.end());
    } else if (outputMode == TAPROOT_SIGHASH_SINGLE) {
        if (inputIndex >= transaction.outputs.size()) {
            throw std::runtime_error("SIGHASH_SINGLE without matching output");
        }
    }

    const int spendType = (extFlag << 1) + (annexPresent ? 1 : 0);
    body.push_back(static_cast<std::uint8_t>(spendType));

    if (anyoneCanPay) {
        const auto& tin = transaction.inputs[inputIndex];
        const auto amt = spentPrevouts[inputIndex].first;
        const auto& spk = spentPrevouts[inputIndex].second;
        messages::TxOut utxo{amt, spk};
        const auto utxoBlob = utxo.serialize();
        const auto prevSer = tin.previousOutput.serialize();
        body.insert(body.end(), prevSer.begin(), prevSer.end());
        body.insert(body.end(), utxoBlob.begin(), utxoBlob.end());
        const auto seq = wire::packUint32Le(tin.sequence);
        body.insert(body.end(), seq.begin(), seq.end());
    } else {
        const auto idx = wire::packUint32Le(static_cast<std::uint32_t>(inputIndex));
        body.insert(body.end(), idx.begin(), idx.end());
    }

    if (annexPresent) {
        const auto digest = taprootAnnexDigest(*annex);
        body.insert(body.end(), digest.begin(), digest.end());
    }

    if (outputMode == TAPROOT_SIGHASH_SINGLE) {
        const auto outSer = transaction.outputs[inputIndex].serialize();
        const auto h = cache != nullptr ? cache->taprootHashSingle(inputIndex) : sha256Digest(outSer);
        body.insert(body.end(), h.begin(), h.end());
    }

    if (extFlag == 1) {
        body.insert(body.end(), tapleafHashBytes.begin(), tapleafHashBytes.end());
        body.push_back(0);
        const auto csPos = wire::packUint32Le(tapscriptCodeseparatorPos);
        body.insert(body.end(), csPos.begin(), csPos.end());
    }

    std::vector<std::uint8_t> sigmsg(epoch.begin(), epoch.end());
    sigmsg.insert(sigmsg.end(), body.begin(), body.end());
    return bitcoinTaggedHash("TapSighash", sigmsg);
}

std::vector<std::uint8_t> legacySighash(const messages::Transaction& transaction, std::size_t inputIndex,
                                          std::span<const std::uint8_t> scriptCode, int sighashType) {
    if (inputIndex >= transaction.inputs.size()) {
        throw std::runtime_error("input_index out of range");
    }

    const int baseType = sighashType & 0x1F;
    const bool anyoneCanPay = (sighashType & 0x80) != 0;

    if (baseType == 3 && inputIndex >= transaction.outputs.size()) {
        std::vector<std::uint8_t> special(32, 0x00);
        special[0] = 0x01;
        return special;
    }

    std::vector<messages::TxIn> inputs;
    if (anyoneCanPay) {
        inputs.push_back(transaction.inputs[inputIndex]);
    } else {
        inputs = transaction.inputs;
    }

    std::vector<std::uint8_t> serialized = wire::packInt32Le(transaction.version);
    auto inCount = wire::writeVarint(inputs.size());
    serialized.insert(serialized.end(), inCount.begin(), inCount.end());

    for (std::size_t index = 0; index < inputs.size(); ++index) {
        const std::size_t sourceIndex = anyoneCanPay ? inputIndex : index;
        const auto prevSer = inputs[index].previousOutput.serialize();
        serialized.insert(serialized.end(), prevSer.begin(), prevSer.end());
        if (sourceIndex == inputIndex) {
            auto scriptLen = wire::writeVarint(scriptCode.size());
            serialized.insert(serialized.end(), scriptLen.begin(), scriptLen.end());
            serialized.insert(serialized.end(), scriptCode.begin(), scriptCode.end());
        } else {
            serialized.push_back(0x00);
        }
        if (anyoneCanPay || baseType == 1 || sourceIndex == inputIndex) {
            const auto seq = wire::packUint32Le(transaction.inputs[sourceIndex].sequence);
            serialized.insert(serialized.end(), seq.begin(), seq.end());
        } else {
            serialized.insert(serialized.end(), 4, 0x00);
        }
    }

    if (baseType == 2) {
        serialized.push_back(0x00);
    } else if (baseType == 3) {
        auto outCount = wire::writeVarint(inputIndex + 1);
        serialized.insert(serialized.end(), outCount.begin(), outCount.end());
        for (std::size_t i = 0; i < inputIndex; ++i) {
            messages::TxOut nullOut;
            nullOut.value = -1;
            const auto outSer = nullOut.serialize();
            serialized.insert(serialized.end(), outSer.begin(), outSer.end());
        }
        const auto outSer = transaction.outputs[inputIndex].serialize();
        serialized.insert(serialized.end(), outSer.begin(), outSer.end());
    } else {
        auto outCount = wire::writeVarint(transaction.outputs.size());
        serialized.insert(serialized.end(), outCount.begin(), outCount.end());
        for (const auto& output : transaction.outputs) {
            const auto outSer = output.serialize();
            serialized.insert(serialized.end(), outSer.begin(), outSer.end());
        }
    }

    const auto lock = wire::packUint32Le(transaction.lockTime);
    serialized.insert(serialized.end(), lock.begin(), lock.end());
    const auto type = wire::packUint32Le(static_cast<std::uint32_t>(sighashType));
    serialized.insert(serialized.end(), type.begin(), type.end());
    return doubleSha256(serialized);
}

std::vector<std::uint8_t> bip143Sighash(const messages::Transaction& transaction, std::size_t inputIndex,
                                          std::span<const std::uint8_t> scriptCode, std::int64_t amount,
                                          int sighashType, const SighashCache* cache) {
    if (inputIndex >= transaction.inputs.size()) {
        throw std::runtime_error("input_index out of range");
    }

    const bool anyoneCanPay = (sighashType & 0x80) != 0;
    const int baseType = sighashType & 0x1F;

    std::vector<std::uint8_t> hashPrevouts(32, 0x00);
    if (!anyoneCanPay) {
        if (cache != nullptr) {
            hashPrevouts = cache->bip143HashPrevouts();
        } else {
            std::vector<std::uint8_t> prevouts;
            for (const auto& txIn : transaction.inputs) {
                const auto ser = txIn.previousOutput.serialize();
                prevouts.insert(prevouts.end(), ser.begin(), ser.end());
            }
            hashPrevouts = doubleSha256(prevouts);
        }
    }

    std::vector<std::uint8_t> hashSequence(32, 0x00);
    if (!anyoneCanPay && baseType != 2 && baseType != 3) {
        if (cache != nullptr) {
            hashSequence = cache->bip143HashSequence();
        } else {
            std::vector<std::uint8_t> sequences;
            for (const auto& txIn : transaction.inputs) {
                const auto seq = wire::packUint32Le(txIn.sequence);
                sequences.insert(sequences.end(), seq.begin(), seq.end());
            }
            hashSequence = doubleSha256(sequences);
        }
    }

    std::vector<std::uint8_t> hashOutputs(32, 0x00);
    if (baseType == 3) {
        if (inputIndex < transaction.outputs.size()) {
            hashOutputs = cache != nullptr ? cache->bip143HashSingle(inputIndex)
                                           : doubleSha256(transaction.outputs[inputIndex].serialize());
        }
    } else if (baseType != 2) {
        if (cache != nullptr) {
            hashOutputs = cache->bip143HashOutputs();
        } else {
            std::vector<std::uint8_t> outputs;
            for (const auto& output : transaction.outputs) {
                const auto ser = output.serialize();
                outputs.insert(outputs.end(), ser.begin(), ser.end());
            }
            hashOutputs = doubleSha256(outputs);
        }
    }

    const auto& txIn = transaction.inputs[inputIndex];
    std::vector<std::uint8_t> payload = wire::packInt32Le(transaction.version);
    payload.insert(payload.end(), hashPrevouts.begin(), hashPrevouts.end());
    payload.insert(payload.end(), hashSequence.begin(), hashSequence.end());
    const auto prevSer = txIn.previousOutput.serialize();
    payload.insert(payload.end(), prevSer.begin(), prevSer.end());
    auto scriptLen = wire::writeVarint(scriptCode.size());
    payload.insert(payload.end(), scriptLen.begin(), scriptLen.end());
    payload.insert(payload.end(), scriptCode.begin(), scriptCode.end());
    const auto amt = wire::packInt64Le(amount);
    payload.insert(payload.end(), amt.begin(), amt.end());
    const auto seq = wire::packUint32Le(txIn.sequence);
    payload.insert(payload.end(), seq.begin(), seq.end());
    payload.insert(payload.end(), hashOutputs.begin(), hashOutputs.end());
    const auto lock = wire::packUint32Le(transaction.lockTime);
    payload.insert(payload.end(), lock.begin(), lock.end());
    const auto type = wire::packUint32Le(static_cast<std::uint32_t>(sighashType));
    payload.insert(payload.end(), type.begin(), type.end());
    return doubleSha256(payload);
}

}  // namespace cpbitnode::consensus::script
