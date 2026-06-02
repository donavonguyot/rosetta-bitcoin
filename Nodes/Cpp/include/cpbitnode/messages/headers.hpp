#pragma once

#include "cpbitnode/messages/block_header.hpp"

#include <span>
#include <string_view>
#include <vector>

namespace cpbitnode::messages {

struct HeadersMessage {
    static constexpr std::string_view kCommand = "headers";

    std::vector<BlockHeader> headers;
};

std::vector<std::uint8_t> serializeHeadersMessage(const HeadersMessage& message);
HeadersMessage deserializeHeadersMessage(std::span<const std::uint8_t> payload);

}  // namespace cpbitnode::messages
