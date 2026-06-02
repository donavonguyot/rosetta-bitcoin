#pragma once

#include <cstdint>
#include <optional>
#include <span>
#include <stdexcept>
#include <vector>

#include "cpbitnode/messages/transaction.hpp"

namespace cpbitnode::consensus {

class CoinbaseError : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

std::optional<std::int64_t> decodeBip34Height(std::span<const std::uint8_t> scriptSig);
void validateBip34Height(const messages::Transaction& coinbase, std::int32_t height);
bool isOpReturn(std::span<const std::uint8_t> scriptPubKey);
bool isSpendableOutput(std::span<const std::uint8_t> scriptPubKey);

}  // namespace cpbitnode::consensus
