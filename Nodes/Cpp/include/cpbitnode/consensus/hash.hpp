#pragma once

#include <cstdint>
#include <span>
#include <vector>

namespace cpbitnode::consensus {

std::vector<std::uint8_t> sha256Digest(std::span<const std::uint8_t> data);
std::vector<std::uint8_t> hash160(std::span<const std::uint8_t> data);

}  // namespace cpbitnode::consensus
