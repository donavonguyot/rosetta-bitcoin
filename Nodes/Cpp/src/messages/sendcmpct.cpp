#include "cpbitnode/messages/sendcmpct.hpp"

#include "cpbitnode/wire/serialize.hpp"

#include <stdexcept>

namespace cpbitnode::messages {

std::vector<std::uint8_t> SendCmpctMessage::serialize() const {
    std::vector<std::uint8_t> payload;
    payload.push_back(announce ? 1 : 0);
    const auto versionBytes = wire::packUint64Le(version);
    payload.insert(payload.end(), versionBytes.begin(), versionBytes.end());
    return payload;
}

SendCmpctMessage SendCmpctMessage::deserialize(std::span<const std::uint8_t> payload) {
    if (payload.size() < 9) {
        throw std::runtime_error("sendcmpct payload too short");
    }
    const bool announce = payload[0] != 0;
    auto [version, offset] = wire::unpackUint64Le(payload, 1);
    if (offset != payload.size()) {
        throw std::runtime_error("trailing bytes after sendcmpct");
    }
    return SendCmpctMessage{announce, version};
}

bool SendCmpctMessage::operator==(const SendCmpctMessage& other) const {
    return announce == other.announce && version == other.version;
}

}  // namespace cpbitnode::messages
