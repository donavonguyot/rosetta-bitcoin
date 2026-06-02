#pragma once

#include <cstdint>

#include "cpbitnode/consensus/connect.hpp"
#include "cpbitnode/db/node_state.hpp"
#include "cpbitnode/messages/transaction.hpp"

namespace cpbitnode::consensus::connect_test_access {

// Test-only hooks mirroring Python connect.py private helpers.
std::int64_t validateNonCoinbaseInputs(db::NodeStateStore& tracker, int height,
                                       const messages::Transaction& tx);
void validateCoinbaseAtHeight(const messages::Transaction& coinbase, int height, std::int64_t totalFees);

}  // namespace cpbitnode::consensus::connect_test_access
