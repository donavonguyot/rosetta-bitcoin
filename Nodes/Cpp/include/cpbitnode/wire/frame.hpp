#pragma once

#include <cstddef>
#include <cstdint>
#include <span>
#include <string>
#include <vector>

namespace cpbitnode::wire {

inline constexpr std::size_t kHeaderSize = 24;

struct MessageHeader {
    std::vector<std::uint8_t> magic;
    std::string command;
    std::uint32_t length = 0;
    std::vector<std::uint8_t> checksum;
};

std::vector<std::uint8_t> headerToBytes(const MessageHeader& header);
MessageHeader parseHeader(std::span<const std::uint8_t> data);
std::vector<std::uint8_t> buildMessage(std::span<const std::uint8_t> magic, const std::string& command,
                                       std::span<const std::uint8_t> payload);
bool verifyChecksum(std::span<const std::uint8_t> payload, std::span<const std::uint8_t> checksum);

}  // namespace cpbitnode::wire
