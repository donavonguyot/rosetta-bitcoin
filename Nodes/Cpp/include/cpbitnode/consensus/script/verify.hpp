#pragma once

#include <cstdint>
#include <optional>
#include <stdexcept>
#include <utility>
#include <vector>

#include "cpbitnode/messages/transaction.hpp"

namespace cpbitnode::consensus::script {

class ScriptVerifyError : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

void verifyTransactionInput(
    const messages::Transaction& transaction, std::size_t inputIndex, std::span<const std::uint8_t> scriptPubkey,
    std::int64_t amount,
    const std::vector<std::pair<std::int64_t, std::vector<std::uint8_t>>>* spentPrevouts = nullptr);

}  // namespace cpbitnode::consensus::script
