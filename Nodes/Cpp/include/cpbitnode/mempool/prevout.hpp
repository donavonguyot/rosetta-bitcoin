#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <utility>
#include <vector>

#include "cpbitnode/messages/transaction.hpp"

namespace cpbitnode::mempool {

using PrevoutKey = std::pair<std::vector<std::uint8_t>, int>;

struct PrevoutKeyHash {
    std::size_t operator()(const PrevoutKey& key) const {
        std::size_t h = 0;
        for (const auto b : key.first) {
            h = h * 31 + b;
        }
        return h ^ static_cast<std::size_t>(key.second);
    }
};

PrevoutKey inputPrevoutKey(const messages::TxIn& input);

}  // namespace cpbitnode::mempool
