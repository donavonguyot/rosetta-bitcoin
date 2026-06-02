#include "cpbitnode/messages/fee_filter.hpp"

#include "cpbitnode/wire/serialize.hpp"

#include <stdexcept>

namespace cpbitnode::messages {

std::vector<std::uint8_t> FeeFilterMessage::serialize() const {
    const auto value = feerateSatKvb;
    return wire::packUint64Le(value);
}

FeeFilterMessage FeeFilterMessage::deserialize(std::span<const std::uint8_t> payload) {
    if (payload.size() != 8) {
        throw std::runtime_error("feefilter expects 8 bytes");
    }
    auto [value, offset] = wire::unpackUint64Le(payload, 0);
    if (offset != 8) {
        throw std::runtime_error("feefilter expects 8 bytes");
    }
    return FeeFilterMessage{value};
}

bool FeeFilterMessage::operator==(const FeeFilterMessage& other) const {
    return feerateSatKvb == other.feerateSatKvb;
}

}  // namespace cpbitnode::messages
