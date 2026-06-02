#pragma once

#include <cstdint>
#include <span>
#include <vector>

namespace cpbitnode::consensus {

std::vector<std::uint8_t> sha1Digest(std::span<const std::uint8_t> data);

}  // namespace cpbitnode::consensus
