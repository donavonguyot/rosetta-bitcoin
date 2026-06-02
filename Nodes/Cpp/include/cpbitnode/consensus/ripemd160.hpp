#pragma once

#include <cstdint>
#include <span>
#include <vector>

namespace cpbitnode::consensus {

std::vector<std::uint8_t> ripemd160Digest(std::span<const std::uint8_t> data);

}  // namespace cpbitnode::consensus
