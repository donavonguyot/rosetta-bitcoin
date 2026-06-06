#include "cpbitnode/messages/headers.hpp"

#include "cpbitnode/wire/serialize.hpp"

#include <tuple>

namespace cpbitnode::messages {

std::vector<std::uint8_t> serializeHeadersMessage(const HeadersMessage& message) {
    std::vector<std::uint8_t> payload = wire::writeVarint(message.headers.size());
    for (const auto& header : message.headers) {
        const auto serialized = serializeBlockHeader(header);
        payload.insert(payload.end(), serialized.begin(), serialized.end());
        payload.push_back(0x00);
    }
    return payload;
}

HeadersMessage deserializeHeadersMessage(std::span<const std::uint8_t> payload) {
    auto [count, offset] = wire::readVarint(payload, 0);
    HeadersMessage message;
    message.headers.reserve(static_cast<std::size_t>(count));
    for (std::uint64_t index = 0; index < count; ++index) {
        BlockHeader header;
        std::tie(header, offset) = deserializeBlockHeader(payload, offset);
        std::tie(std::ignore, offset) = wire::readVarint(payload, offset);
        message.headers.push_back(std::move(header));
    }
    return message;
}

}  // namespace cpbitnode::messages
