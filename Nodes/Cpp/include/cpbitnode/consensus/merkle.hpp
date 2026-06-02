#pragma once

#include <span>
#include <vector>

#include "cpbitnode/messages/transaction.hpp"

namespace cpbitnode::consensus {

std::vector<std::uint8_t> merkleRoot(std::span<const std::vector<std::uint8_t>> hashes);
std::vector<std::uint8_t> transactionTxid(const messages::Transaction& transaction);
std::vector<std::uint8_t> blockMerkleRoot(std::span<const messages::Transaction> transactions);

}  // namespace cpbitnode::consensus
