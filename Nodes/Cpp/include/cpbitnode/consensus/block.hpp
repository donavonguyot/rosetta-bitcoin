#pragma once

#include <span>
#include <vector>

#include "cpbitnode/messages/block_header.hpp"
#include "cpbitnode/messages/transaction.hpp"

namespace cpbitnode::consensus {

struct Block {
    messages::BlockHeader header;
    std::vector<messages::Transaction> transactions;

    static Block deserialize(std::span<const std::uint8_t> payload);
};

}  // namespace cpbitnode::consensus
