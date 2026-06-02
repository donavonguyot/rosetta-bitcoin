#pragma once

#include <cstdint>
#include <span>
#include <utility>
#include <vector>

#include "cpbitnode/messages/block_header.hpp"

namespace cpbitnode::messages {

std::pair<std::uint64_t, std::uint64_t> shortIdNonceKey(const BlockHeader& header, std::uint64_t shortIdNonce);

/** Lower 48 bits of Bitcoin Core's PresaltedSipHasher as 6-byte LE. */
std::vector<std::uint8_t> presaltedShortIdFromUint256Digest(std::uint64_t k0,
                                                            std::uint64_t k1,
                                                            std::span<const std::uint8_t> digest32);

}  // namespace cpbitnode::messages
