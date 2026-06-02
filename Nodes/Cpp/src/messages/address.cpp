#include "cpbitnode/messages/address.hpp"

#include "cpbitnode/wire/serialize.hpp"

namespace cpbitnode::messages {

std::vector<std::uint8_t> GetAddrMessage::serialize() const { return {}; }

GetAddrMessage GetAddrMessage::deserialize(std::span<const std::uint8_t> /*payload*/) { return {}; }

std::vector<std::uint8_t> AddrMessage::serialize() const {
    auto payload = wire::writeVarint(addresses.size());
    for (const auto& address : addresses) {
        const auto encoded = address.serialize(true);
        payload.insert(payload.end(), encoded.begin(), encoded.end());
    }
    return payload;
}

AddrMessage AddrMessage::deserialize(std::span<const std::uint8_t> payload) {
    AddrMessage message;
    auto [count, offset] = wire::readVarint(payload, 0);
    for (std::uint64_t i = 0; i < count; ++i) {
        try {
            NetworkAddress address;
            std::tie(address, offset) = NetworkAddress::deserialize(payload, offset, true);
            message.addresses.push_back(std::move(address));
        } catch (...) {
            break;
        }
    }
    return message;
}

}  // namespace cpbitnode::messages
