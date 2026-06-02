#pragma once

#include <cstdint>
#include <span>
#include <string>
#include <vector>

namespace cpbitnode::consensus {

std::vector<std::uint8_t> sha256(std::span<const std::uint8_t> data);
std::vector<std::uint8_t> doubleSha256(std::span<const std::uint8_t> data);
std::string sha256Hex(std::span<const std::uint8_t> data);

}  // namespace cpbitnode::consensus
