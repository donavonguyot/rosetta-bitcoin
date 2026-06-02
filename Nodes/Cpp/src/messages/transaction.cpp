#include "cpbitnode/messages/transaction.hpp"

#include "cpbitnode/wire/serialize.hpp"

#include <algorithm>
#include <stdexcept>

namespace cpbitnode::messages {
namespace {

constexpr std::uint32_t kCoinbaseIndex = 0xFFFFFFFFu;

bool isWitnessMarker(std::span<const std::uint8_t> data, std::size_t offset) {
    return offset + 1 < data.size() && data[offset] == kWitnessMarker0 && data[offset + 1] == kWitnessMarker1;
}

}  // namespace

bool transactionIsCoinbase(const Transaction& transaction) {
    return transaction.isCoinbase();
}

std::vector<std::uint8_t> OutPoint::serialize() const {
    return serializeOutPoint(*this);
}

std::vector<std::uint8_t> TxIn::serialize() const {
    return serializeTxIn(*this);
}

std::vector<std::uint8_t> TxOut::serialize() const {
    return serializeTxOut(*this);
}

bool Transaction::isCoinbase() const {
    return inputs.size() == 1 &&
           inputs[0].previousOutput.hash == std::vector<std::uint8_t>(32, 0) &&
           inputs[0].previousOutput.index == kCoinbaseIndex;
}

std::vector<std::uint8_t> Transaction::serialize(bool includeWitness) const {
    return serializeTransaction(*this, includeWitness);
}

std::vector<std::uint8_t> serializeOutPoint(const OutPoint& outpoint) {
    if (outpoint.hash.size() != 32) {
        throw std::runtime_error("outpoint hash must be 32 bytes");
    }
    auto payload = outpoint.hash;
    const auto indexBytes = wire::packUint32Le(outpoint.index);
    payload.insert(payload.end(), indexBytes.begin(), indexBytes.end());
    return payload;
}

std::vector<std::uint8_t> serializeTxIn(const TxIn& input) {
    auto payload = serializeOutPoint(input.previousOutput);
    const auto scriptPrefix = wire::writeVarint(input.scriptSig.size());
    payload.insert(payload.end(), scriptPrefix.begin(), scriptPrefix.end());
    payload.insert(payload.end(), input.scriptSig.begin(), input.scriptSig.end());
    const auto sequenceBytes = wire::packUint32Le(input.sequence);
    payload.insert(payload.end(), sequenceBytes.begin(), sequenceBytes.end());
    return payload;
}

std::vector<std::uint8_t> serializeTxOut(const TxOut& output) {
    auto payload = wire::packInt64Le(output.value);
    const auto scriptPrefix = wire::writeVarint(output.scriptPubkey.size());
    payload.insert(payload.end(), scriptPrefix.begin(), scriptPrefix.end());
    payload.insert(payload.end(), output.scriptPubkey.begin(), output.scriptPubkey.end());
    return payload;
}

std::vector<std::uint8_t> serializeTransaction(const Transaction& transaction, bool includeWitness) {
    auto payload = wire::packInt32Le(transaction.version);
    const bool useWitness = includeWitness && !transaction.witness.empty();
    if (useWitness) {
        payload.push_back(kWitnessMarker0);
        payload.push_back(kWitnessMarker1);
    }
    const auto inputCount = wire::writeVarint(transaction.inputs.size());
    payload.insert(payload.end(), inputCount.begin(), inputCount.end());
    for (const auto& input : transaction.inputs) {
        const auto serialized = serializeTxIn(input);
        payload.insert(payload.end(), serialized.begin(), serialized.end());
    }
    const auto outputCount = wire::writeVarint(transaction.outputs.size());
    payload.insert(payload.end(), outputCount.begin(), outputCount.end());
    for (const auto& output : transaction.outputs) {
        const auto serialized = serializeTxOut(output);
        payload.insert(payload.end(), serialized.begin(), serialized.end());
    }
    if (useWitness) {
        for (const auto& stack : transaction.witness) {
            const auto stackCount = wire::writeVarint(stack.size());
            payload.insert(payload.end(), stackCount.begin(), stackCount.end());
            for (const auto& item : stack) {
                const auto itemPrefix = wire::writeVarint(item.size());
                payload.insert(payload.end(), itemPrefix.begin(), itemPrefix.end());
                payload.insert(payload.end(), item.begin(), item.end());
            }
        }
    }
    const auto lockTimeBytes = wire::packUint32Le(transaction.lockTime);
    payload.insert(payload.end(), lockTimeBytes.begin(), lockTimeBytes.end());
    return payload;
}

std::pair<Transaction, std::size_t> deserializeTransaction(std::span<const std::uint8_t> data,
                                                             std::size_t offset) {
    const auto start = offset;
    Transaction transaction;
    std::tie(transaction.version, offset) = wire::unpackInt32Le(data, offset);
    bool witness = false;
    if (isWitnessMarker(data, offset)) {
        witness = true;
        offset += 2;
    }
    std::uint64_t inputCount = 0;
    std::tie(inputCount, offset) = wire::readVarint(data, offset);
    transaction.inputs.reserve(static_cast<std::size_t>(inputCount));
    for (std::uint64_t index = 0; index < inputCount; ++index) {
        TxIn input;
        input.previousOutput.hash.assign(data.begin() + static_cast<std::ptrdiff_t>(offset),
                                         data.begin() + static_cast<std::ptrdiff_t>(offset + 32));
        offset += 32;
        std::tie(input.previousOutput.index, offset) = wire::unpackUint32Le(data, offset);
        std::uint64_t scriptLen = 0;
        std::tie(scriptLen, offset) = wire::readVarint(data, offset);
        input.scriptSig.assign(data.begin() + static_cast<std::ptrdiff_t>(offset),
                               data.begin() + static_cast<std::ptrdiff_t>(offset + scriptLen));
        offset += static_cast<std::size_t>(scriptLen);
        std::tie(input.sequence, offset) = wire::unpackUint32Le(data, offset);
        transaction.inputs.push_back(std::move(input));
    }
    std::uint64_t outputCount = 0;
    std::tie(outputCount, offset) = wire::readVarint(data, offset);
    transaction.outputs.reserve(static_cast<std::size_t>(outputCount));
    for (std::uint64_t index = 0; index < outputCount; ++index) {
        TxOut output;
        std::tie(output.value, offset) = wire::unpackInt64Le(data, offset);
        std::uint64_t scriptLen = 0;
        std::tie(scriptLen, offset) = wire::readVarint(data, offset);
        output.scriptPubkey.assign(data.begin() + static_cast<std::ptrdiff_t>(offset),
                                   data.begin() + static_cast<std::ptrdiff_t>(offset + scriptLen));
        offset += static_cast<std::size_t>(scriptLen);
        transaction.outputs.push_back(std::move(output));
    }
    if (witness) {
        transaction.witness.reserve(static_cast<std::size_t>(inputCount));
        for (std::uint64_t index = 0; index < inputCount; ++index) {
            std::uint64_t stackCount = 0;
            std::tie(stackCount, offset) = wire::readVarint(data, offset);
            std::vector<std::vector<std::uint8_t>> stack;
            stack.reserve(static_cast<std::size_t>(stackCount));
            for (std::uint64_t stackIndex = 0; stackIndex < stackCount; ++stackIndex) {
                std::uint64_t itemLen = 0;
                std::tie(itemLen, offset) = wire::readVarint(data, offset);
                stack.emplace_back(data.begin() + static_cast<std::ptrdiff_t>(offset),
                                   data.begin() + static_cast<std::ptrdiff_t>(offset + itemLen));
                offset += static_cast<std::size_t>(itemLen);
            }
            transaction.witness.push_back(std::move(stack));
        }
    }
    std::tie(transaction.lockTime, offset) = wire::unpackUint32Le(data, offset);
    if (offset < start) {
        throw std::runtime_error("transaction deserialization underflow");
    }
    return {std::move(transaction), offset};
}

}  // namespace cpbitnode::messages
