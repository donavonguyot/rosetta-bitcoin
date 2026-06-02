#pragma once

#include <cstdint>
#include <span>
#include <stdexcept>
#include <vector>

#include "cpbitnode/consensus/block.hpp"
#include "cpbitnode/messages/block_header.hpp"

namespace cpbitnode::sync {

class HeaderValidationError : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

class BlockValidationError : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

inline constexpr std::size_t kMaxBlockPayloadBytes = 4'000'000;
inline constexpr std::size_t kMinBlockPayloadBytes = 80;

std::array<std::uint8_t, 32> compactToTargetLE(std::uint32_t bits);
bool headerMeetsTarget(const messages::BlockHeader& header);
void validateHeader(const messages::BlockHeader& header, std::span<const std::uint8_t> expectedPrev);

consensus::Block validateBlock(std::span<const std::uint8_t> payload, std::span<const std::uint8_t> expectedPrev,
                               const std::vector<std::uint8_t>* expectedHash = nullptr);

}  // namespace cpbitnode::sync
