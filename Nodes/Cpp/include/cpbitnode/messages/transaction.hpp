#pragma once

#include <cstdint>
#include <span>
#include <string_view>
#include <vector>

namespace cpbitnode::messages {

inline constexpr std::uint8_t kWitnessMarker0 = 0x00;
inline constexpr std::uint8_t kWitnessMarker1 = 0x01;

struct OutPoint {
    std::vector<std::uint8_t> hash;
    std::uint32_t index = 0;

    std::vector<std::uint8_t> serialize() const;
};

struct TxIn {
    OutPoint previousOutput;
    std::vector<std::uint8_t> scriptSig;
    std::uint32_t sequence = 0;

    std::vector<std::uint8_t> serialize() const;
};

struct TxOut {
    std::int64_t value = 0;
    std::vector<std::uint8_t> scriptPubkey;

    std::vector<std::uint8_t> serialize() const;
};

struct Transaction {
    static constexpr std::string_view kCommand = "tx";

    std::int32_t version = 0;
    std::vector<TxIn> inputs;
    std::vector<TxOut> outputs;
    std::uint32_t lockTime = 0;
    std::vector<std::vector<std::vector<std::uint8_t>>> witness;

    bool isCoinbase() const;
    std::vector<std::uint8_t> serialize(bool includeWitness = false) const;
};

bool transactionIsCoinbase(const Transaction& transaction);

std::vector<std::uint8_t> serializeOutPoint(const OutPoint& outpoint);
std::vector<std::uint8_t> serializeTxIn(const TxIn& input);
std::vector<std::uint8_t> serializeTxOut(const TxOut& output);
std::vector<std::uint8_t> serializeTransaction(const Transaction& transaction, bool includeWitness = false);
std::pair<Transaction, std::size_t> deserializeTransaction(std::span<const std::uint8_t> data,
                                                             std::size_t offset = 0);

}  // namespace cpbitnode::messages
