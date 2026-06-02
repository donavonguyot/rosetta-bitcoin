#pragma once

#include "cpbitnode/messages/block_header.hpp"

#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace cpbitnode::messages {

struct BlockMessage {
    static constexpr std::string_view kCommand = "block";

    std::vector<std::uint8_t> payload;
};

BlockMessage deserializeBlockMessage(std::span<const std::uint8_t> payload);
std::vector<std::uint8_t> serializeBlockMessage(const BlockMessage& message);
std::vector<std::uint8_t> blockHashFromPayload(std::span<const std::uint8_t> payload);
std::string blockHashHexFromPayload(std::span<const std::uint8_t> payload);

}  // namespace cpbitnode::messages
