#pragma once

#include <cstdint>
#include <span>
#include <vector>

namespace cpbitnode::messages {

/** BIP152 compact block relay version (Bitcoin Core uses 2). */
inline constexpr std::uint64_t kSendCmpctVersion = 2;

struct SendCmpctMessage {
    static constexpr const char* kCommand = "sendcmpct";

    bool announce = false;
    std::uint64_t version = kSendCmpctVersion;

    std::vector<std::uint8_t> serialize() const;
    static SendCmpctMessage deserialize(std::span<const std::uint8_t> payload);

    bool operator==(const SendCmpctMessage& other) const;
};

}  // namespace cpbitnode::messages
