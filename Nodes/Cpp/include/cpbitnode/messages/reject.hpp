#pragma once

#include <cstdint>
#include <span>
#include <string>
#include <vector>

namespace cpbitnode::messages {

inline constexpr std::uint8_t REJECT_MALFORMED = 0x01;
inline constexpr std::uint8_t REJECT_INVALID = 0x10;
inline constexpr std::uint8_t REJECT_OBSOLETE = 0x11;
inline constexpr std::uint8_t REJECT_DUPLICATE = 0x12;
inline constexpr std::uint8_t REJECT_NONSTANDARD = 0x40;
inline constexpr std::uint8_t REJECT_DUST = 0x41;
inline constexpr std::uint8_t REJECT_INSUFFICIENTFEE = 0x42;

struct RejectMessage {
    static constexpr const char* kCommand = "reject";

    std::string message;
    std::uint8_t ccode = 0;
    std::string reason;
    std::vector<std::uint8_t> data;

    std::vector<std::uint8_t> serialize() const;
    static RejectMessage deserialize(std::span<const std::uint8_t> payload);

    bool operator==(const RejectMessage& other) const;
};

}  // namespace cpbitnode::messages
