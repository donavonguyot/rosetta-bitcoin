#pragma once

#include <cstdint>
#include <span>
#include <vector>

namespace cpbitnode::messages {

inline constexpr std::int32_t FEEFILTER_MIN_VERSION = 70013;

struct FeeFilterMessage {
    static constexpr const char* kCommand = "feefilter";

    std::uint64_t feerateSatKvb = 0;

    std::vector<std::uint8_t> serialize() const;
    static FeeFilterMessage deserialize(std::span<const std::uint8_t> payload);

    bool operator==(const FeeFilterMessage& other) const;
};

}  // namespace cpbitnode::messages
