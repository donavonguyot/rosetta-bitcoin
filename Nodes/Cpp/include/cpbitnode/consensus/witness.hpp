#pragma once

#include <optional>
#include <span>
#include <vector>

#include "cpbitnode/messages/transaction.hpp"

namespace cpbitnode::consensus {

std::vector<std::uint8_t> transactionWtxid(const messages::Transaction& transaction);
std::vector<std::uint8_t> witnessMerkleRoot(std::span<const messages::Transaction> transactions);
std::optional<std::vector<std::uint8_t>> extractWitnessCommitment(std::span<const std::uint8_t> scriptPubKey);
void validateWitnessCommitment(const messages::Transaction& coinbase,
                               std::span<const messages::Transaction> transactions);

}  // namespace cpbitnode::consensus
