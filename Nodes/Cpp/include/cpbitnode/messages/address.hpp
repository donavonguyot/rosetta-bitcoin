#pragma once

#include "cpbitnode/messages/handshake.hpp"

#include <cstdint>
#include <span>
#include <vector>

namespace cpbitnode::messages {

struct GetAddrMessage {
    static constexpr const char* kCommand = "getaddr";
    std::vector<std::uint8_t> serialize() const;
    static GetAddrMessage deserialize(std::span<const std::uint8_t> payload);
};

struct AddrMessage {
    static constexpr const char* kCommand = "addr";
    std::vector<NetworkAddress> addresses;

    std::vector<std::uint8_t> serialize() const;
    static AddrMessage deserialize(std::span<const std::uint8_t> payload);
};

}  // namespace cpbitnode::messages
