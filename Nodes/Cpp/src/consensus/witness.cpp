#include "cpbitnode/consensus/witness.hpp"

#include "cpbitnode/consensus/constants.hpp"
#include "cpbitnode/consensus/merkle.hpp"
#include "cpbitnode/consensus/sha256.hpp"
#include "cpbitnode/messages/transaction.hpp"

#include <stdexcept>

namespace cpbitnode::consensus {

std::vector<std::uint8_t> transactionWtxid(const messages::Transaction& transaction) {
    if (messages::transactionIsCoinbase(transaction)) {
        return std::vector<std::uint8_t>(32, 0);
    }
    return doubleSha256(messages::serializeTransaction(transaction, true));
}

std::vector<std::uint8_t> witnessMerkleRoot(std::span<const messages::Transaction> transactions) {
    std::vector<std::vector<std::uint8_t>> hashes;
    hashes.reserve(transactions.size());
    for (const auto& tx : transactions) {
        hashes.push_back(transactionWtxid(tx));
    }
    return merkleRoot(hashes);
}

std::optional<std::vector<std::uint8_t>> extractWitnessCommitment(std::span<const std::uint8_t> scriptPubkey) {
    if (scriptPubkey.size() < 38 || scriptPubkey[0] != 0x6A || scriptPubkey[1] != 0x24) {
        return std::nullopt;
    }
    if (!std::equal(kWitnessCommitmentHeader.begin(), kWitnessCommitmentHeader.end(), scriptPubkey.begin() + 2)) {
        return std::nullopt;
    }
    return std::vector<std::uint8_t>(scriptPubkey.begin() + 6, scriptPubkey.begin() + 38);
}

void validateWitnessCommitment(const messages::Transaction& coinbase,
                               std::span<const messages::Transaction> transactions) {
    if (coinbase.witness.empty() || coinbase.witness[0].empty()) {
        throw std::runtime_error("coinbase witness stack missing reserved value");
    }
    const auto& reserved = coinbase.witness[0][0];
    if (reserved.size() != kWitnessReservedValueSize) {
        throw std::runtime_error("coinbase witness reserved value must be 32 bytes");
    }

    std::optional<std::vector<std::uint8_t>> commitmentHash;
    for (const auto& output : coinbase.outputs) {
        commitmentHash = extractWitnessCommitment(output.scriptPubkey);
        if (commitmentHash.has_value()) {
            break;
        }
    }
    if (!commitmentHash.has_value()) {
        throw std::runtime_error("coinbase missing witness commitment output");
    }

    const auto root = witnessMerkleRoot(transactions);
    std::vector<std::uint8_t> combined;
    combined.reserve(64);
    combined.insert(combined.end(), root.begin(), root.end());
    combined.insert(combined.end(), reserved.begin(), reserved.end());
    const auto expected = doubleSha256(combined);
    if (*commitmentHash != expected) {
        throw std::runtime_error("witness commitment mismatch");
    }
}

}  // namespace cpbitnode::consensus
