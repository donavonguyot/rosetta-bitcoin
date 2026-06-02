#pragma once

#include <array>
#include <cstdint>

namespace cpbitnode::consensus {

inline constexpr std::int64_t kCoin = 100'000'000;
inline constexpr std::int32_t kSubsidyHalvingInterval = 210'000;
inline constexpr std::int64_t kMaxBlockSubsidy = 50 * kCoin;
inline constexpr std::int32_t kCoinbaseMaturity = 100;

inline constexpr std::array<std::uint8_t, 4> kWitnessCommitmentHeader = {0xaa, 0x21, 0xa9, 0xed};
inline constexpr std::size_t kWitnessReservedValueSize = 32;

}  // namespace cpbitnode::consensus
