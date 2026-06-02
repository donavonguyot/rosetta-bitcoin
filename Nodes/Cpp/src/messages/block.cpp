#include "cpbitnode/messages/block.hpp"

namespace cpbitnode::messages {

BlockMessage deserializeBlockMessage(std::span<const std::uint8_t> payload) {
    return BlockMessage{std::vector<std::uint8_t>(payload.begin(), payload.end())};
}

std::vector<std::uint8_t> serializeBlockMessage(const BlockMessage& message) {
    return message.payload;
}

std::vector<std::uint8_t> blockHashFromPayload(std::span<const std::uint8_t> payload) {
    const auto [header, offset] = deserializeBlockHeader(payload, 0);
    (void)offset;
    return blockHash(header);
}

std::string blockHashHexFromPayload(std::span<const std::uint8_t> payload) {
    const auto [header, offset] = deserializeBlockHeader(payload, 0);
    (void)offset;
    return blockHashHex(header);
}

}  // namespace cpbitnode::messages
