#pragma once

#include <cstdint>
#include <span>
#include <vector>

namespace cpbitnode::messages {

struct MempoolRequestMessage {
    static constexpr const char* kCommand = "mempool";

    std::vector<std::uint8_t> serialize() const;
    static MempoolRequestMessage deserialize(std::span<const std::uint8_t> payload);
};

}  // namespace cpbitnode::messages
