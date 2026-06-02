#pragma once

#include <cstdint>
#include <span>
#include <string>
#include <vector>

namespace cpbitnode::messages {

inline constexpr std::size_t kHeaderSize = 80;

struct BlockHeader {
    std::int32_t version = 1;
    std::vector<std::uint8_t> prevBlock;
    std::vector<std::uint8_t> merkleRoot;
    std::uint32_t timestamp = 0;
    std::uint32_t bits = 0;
    std::uint32_t nonce = 0;

    std::vector<std::uint8_t> serialize() const;
    std::vector<std::uint8_t> blockHash() const;
    std::string blockHashHex() const;
};

std::vector<std::uint8_t> serializeBlockHeader(const BlockHeader& header);
std::pair<BlockHeader, std::size_t> deserializeBlockHeader(std::span<const std::uint8_t> data,
                                                           std::size_t offset = 0);
std::vector<std::uint8_t> blockHash(const BlockHeader& header);
std::string blockHashHex(const BlockHeader& header);

}  // namespace cpbitnode::messages
