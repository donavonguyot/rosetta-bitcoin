#include "cpbitnode/messages/block_header.hpp"

#include "cpbitnode/consensus/sha256.hpp"

#include <cstring>
#include <iomanip>
#include <sstream>
#include <stdexcept>

namespace cpbitnode::messages {

std::vector<std::uint8_t> serializeBlockHeader(const BlockHeader& header) {
    if (header.prevBlock.size() != 32 || header.merkleRoot.size() != 32) {
        throw std::runtime_error("header fields must be 32 bytes");
    }
    std::vector<std::uint8_t> out(kHeaderSize);
    std::memcpy(out.data(), &header.version, 4);
    std::memcpy(out.data() + 4, header.prevBlock.data(), 32);
    std::memcpy(out.data() + 36, header.merkleRoot.data(), 32);
    std::memcpy(out.data() + 68, &header.timestamp, 4);
    std::memcpy(out.data() + 72, &header.bits, 4);
    std::memcpy(out.data() + 76, &header.nonce, 4);
    return out;
}

std::pair<BlockHeader, std::size_t> deserializeBlockHeader(std::span<const std::uint8_t> data,
                                                           std::size_t offset) {
    if (offset + kHeaderSize > data.size()) {
        throw std::runtime_error("block header read past end");
    }
    BlockHeader header;
    std::memcpy(&header.version, data.data() + offset, 4);
    header.prevBlock.assign(data.begin() + static_cast<std::ptrdiff_t>(offset + 4),
                            data.begin() + static_cast<std::ptrdiff_t>(offset + 36));
    header.merkleRoot.assign(data.begin() + static_cast<std::ptrdiff_t>(offset + 36),
                             data.begin() + static_cast<std::ptrdiff_t>(offset + 68));
    std::memcpy(&header.timestamp, data.data() + offset + 68, 4);
    std::memcpy(&header.bits, data.data() + offset + 72, 4);
    std::memcpy(&header.nonce, data.data() + offset + 76, 4);
    return {header, offset + kHeaderSize};
}

std::vector<std::uint8_t> blockHash(const BlockHeader& header) {
    return consensus::doubleSha256(serializeBlockHeader(header));
}

std::string blockHashHex(const BlockHeader& header) {
    const auto hash = blockHash(header);
    std::ostringstream oss;
    for (auto it = hash.rbegin(); it != hash.rend(); ++it) {
        oss << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(*it);
    }
    return oss.str();
}

std::vector<std::uint8_t> BlockHeader::serialize() const {
    return serializeBlockHeader(*this);
}

std::vector<std::uint8_t> BlockHeader::blockHash() const {
    return messages::blockHash(*this);
}

std::string BlockHeader::blockHashHex() const {
    return messages::blockHashHex(*this);
}

}  // namespace cpbitnode::messages
