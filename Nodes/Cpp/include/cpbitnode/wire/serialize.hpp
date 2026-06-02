#pragma once

#include <cstdint>
#include <span>
#include <string>
#include <vector>

namespace cpbitnode::wire {

std::vector<std::uint8_t> messageChecksum(std::span<const std::uint8_t> payload);

std::vector<std::uint8_t> packInt32Le(std::int32_t value);
std::vector<std::uint8_t> packInt64Le(std::int64_t value);
std::vector<std::uint8_t> packUint32Le(std::uint32_t value);
std::vector<std::uint8_t> packUint64Le(std::uint64_t value);

std::pair<std::int32_t, std::size_t> unpackInt32Le(std::span<const std::uint8_t> data, std::size_t offset = 0);
std::pair<std::int64_t, std::size_t> unpackInt64Le(std::span<const std::uint8_t> data, std::size_t offset = 0);
std::pair<std::uint32_t, std::size_t> unpackUint32Le(std::span<const std::uint8_t> data, std::size_t offset = 0);
std::pair<std::uint64_t, std::size_t> unpackUint64Le(std::span<const std::uint8_t> data, std::size_t offset = 0);

std::pair<std::uint64_t, std::size_t> readVarint(std::span<const std::uint8_t> data, std::size_t offset = 0);
std::vector<std::uint8_t> writeVarint(std::uint64_t value);

}  // namespace cpbitnode::wire
