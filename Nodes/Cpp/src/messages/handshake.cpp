#include "cpbitnode/messages/handshake.hpp"

#include "cpbitnode/wire/serialize.hpp"

#include <arpa/inet.h>

#include <array>
#include <chrono>
#include <cstring>
#include <random>
#include <stdexcept>
#include <tuple>

namespace cpbitnode::messages {
namespace {

std::vector<std::uint8_t> packUint16Be(std::uint16_t value) {
    return {static_cast<std::uint8_t>((value >> 8) & 0xff), static_cast<std::uint8_t>(value & 0xff)};
}

std::pair<std::uint16_t, std::size_t> unpackUint16Be(std::span<const std::uint8_t> data, std::size_t offset) {
    if (offset + 2 > data.size()) {
        throw std::runtime_error("uint16 read past end");
    }
    const auto value = static_cast<std::uint16_t>((static_cast<std::uint16_t>(data[offset]) << 8) | data[offset + 1]);
    return {value, offset + 2};
}

std::vector<std::uint8_t> ipToBytes(const std::string& ip) {
    std::array<std::uint8_t, 16> raw{};
    in_addr v4{};
    if (inet_pton(AF_INET, ip.c_str(), &v4) == 1) {
        constexpr std::uint8_t kMappedPrefix[] = {0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
                                                  0xff, 0xff, 0xff, 0xff};
        std::memcpy(raw.data(), kMappedPrefix, 12);
        std::memcpy(raw.data() + 12, &v4, 4);
        return std::vector<std::uint8_t>(raw.begin(), raw.end());
    }
    in6_addr v6{};
    if (inet_pton(AF_INET6, ip.c_str(), &v6) == 1) {
        std::memcpy(raw.data(), &v6, 16);
        return std::vector<std::uint8_t>(raw.begin(), raw.end());
    }
    throw std::runtime_error("invalid IP address");
}

std::string bytesToIp(std::span<const std::uint8_t> raw) {
    if (raw.size() != 16) {
        throw std::runtime_error("invalid network address bytes");
    }
    constexpr std::uint8_t kMappedPrefix[] = {0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
                                              0xff, 0xff, 0xff, 0xff};
    if (std::memcmp(raw.data(), kMappedPrefix, 12) == 0) {
        char buf[INET_ADDRSTRLEN] = {};
        in_addr v4{};
        std::memcpy(&v4, raw.data() + 12, 4);
        if (inet_ntop(AF_INET, &v4, buf, sizeof(buf)) == nullptr) {
            throw std::runtime_error("invalid IPv4 mapped address");
        }
        return buf;
    }
    char buf[INET6_ADDRSTRLEN] = {};
    in6_addr v6{};
    std::memcpy(&v6, raw.data(), 16);
    if (inet_ntop(AF_INET6, &v6, buf, sizeof(buf)) == nullptr) {
        throw std::runtime_error("invalid IPv6 address");
    }
    return buf;
}

std::uint64_t randomNonce() {
    std::random_device rd;
    std::mt19937_64 gen(rd());
    std::uniform_int_distribution<std::uint64_t> dist;
    return dist(gen);
}

}  // namespace

std::vector<std::uint8_t> NetworkAddress::serialize(bool withTimestamp, std::int64_t timestamp) const {
    std::vector<std::uint8_t> out;
    if (withTimestamp) {
        const auto ts = timestamp != 0 ? timestamp
                                       : std::chrono::duration_cast<std::chrono::seconds>(
                                             std::chrono::system_clock::now().time_since_epoch())
                                             .count();
        auto tsBytes = wire::packInt64Le(ts);
        out.insert(out.end(), tsBytes.begin(), tsBytes.end());
    }
    auto servicesBytes = wire::packUint64Le(services);
    out.insert(out.end(), servicesBytes.begin(), servicesBytes.end());
    const auto ipBytes = ipToBytes(ip);
    out.insert(out.end(), ipBytes.begin(), ipBytes.end());
    auto portBytes = packUint16Be(port);
    out.insert(out.end(), portBytes.begin(), portBytes.end());
    return out;
}

std::pair<NetworkAddress, std::size_t> NetworkAddress::deserialize(std::span<const std::uint8_t> data,
                                                                   std::size_t offset, bool withTimestamp) {
    const std::size_t required = (withTimestamp ? 8 : 0) + 8 + 16 + 2;
    if (offset + required > data.size()) {
        throw std::runtime_error("truncated network address");
    }
    if (withTimestamp) {
        std::tie(std::ignore, offset) = wire::unpackInt64Le(data, offset);
    }
    std::uint64_t services = 0;
    std::tie(services, offset) = wire::unpackUint64Le(data, offset);
    const auto ipBytes = data.subspan(offset, 16);
    offset += 16;
    std::uint16_t port = 0;
    std::tie(port, offset) = unpackUint16Be(data, offset);
    return {NetworkAddress{services, bytesToIp(ipBytes), port}, offset};
}

std::vector<std::uint8_t> VersionMessage::serialize() const {
    std::vector<std::uint8_t> payload;
    auto append = [&](const std::vector<std::uint8_t>& chunk) {
        payload.insert(payload.end(), chunk.begin(), chunk.end());
    };
    append(wire::packInt32Le(version));
    append(wire::packUint64Le(services));
    append(wire::packInt64Le(timestamp));
    append(addrRecv.serialize(false));
    append(addrFrom.serialize(false));
    append(wire::packUint64Le(nonce));
    if (userAgent.size() > 255) {
        throw std::runtime_error("user agent too long");
    }
    payload.push_back(static_cast<std::uint8_t>(userAgent.size()));
    payload.insert(payload.end(), userAgent.begin(), userAgent.end());
    append(wire::packInt32Le(startHeight));
    payload.push_back(relay ? 1 : 0);
    return payload;
}

VersionMessage VersionMessage::deserialize(std::span<const std::uint8_t> payload) {
    std::size_t offset = 0;
    VersionMessage msg;
    std::tie(msg.version, offset) = wire::unpackInt32Le(payload, offset);
    std::tie(msg.services, offset) = wire::unpackUint64Le(payload, offset);
    std::tie(msg.timestamp, offset) = wire::unpackInt64Le(payload, offset);
    std::tie(msg.addrRecv, offset) = NetworkAddress::deserialize(payload, offset, false);
    std::tie(msg.addrFrom, offset) = NetworkAddress::deserialize(payload, offset, false);
    std::tie(msg.nonce, offset) = wire::unpackUint64Le(payload, offset);
    if (offset >= payload.size()) {
        throw std::runtime_error("truncated version user agent length");
    }
    const auto uaLen = payload[offset++];
    if (offset + uaLen > payload.size()) {
        throw std::runtime_error("truncated version user agent");
    }
    msg.userAgent.assign(reinterpret_cast<const char*>(payload.data() + offset), uaLen);
    offset += uaLen;
    std::tie(msg.startHeight, offset) = wire::unpackInt32Le(payload, offset);
    msg.relay = offset < payload.size() ? payload[offset] != 0 : true;
    return msg;
}

VersionMessage VersionMessage::build(std::int32_t protocolVersion, std::uint64_t services,
                                     const NetworkAddress& recv, const NetworkAddress& from,
                                     const std::string& agent, std::int32_t height, bool relayFlag) {
    VersionMessage msg;
    msg.version = protocolVersion;
    msg.services = services;
    msg.timestamp = std::chrono::duration_cast<std::chrono::seconds>(
                        std::chrono::system_clock::now().time_since_epoch())
                        .count();
    msg.addrRecv = recv;
    msg.addrFrom = from;
    msg.nonce = randomNonce();
    msg.userAgent = agent;
    msg.startHeight = height;
    msg.relay = relayFlag;
    return msg;
}

std::vector<std::uint8_t> VerAckMessage::serialize() const { return {}; }

VerAckMessage VerAckMessage::deserialize(std::span<const std::uint8_t> /*payload*/) { return {}; }

std::vector<std::uint8_t> SendHeadersMessage::serialize() const { return {}; }

SendHeadersMessage SendHeadersMessage::deserialize(std::span<const std::uint8_t> /*payload*/) { return {}; }

std::vector<std::uint8_t> PingMessage::serialize() const { return wire::packUint64Le(nonce); }

PingMessage PingMessage::deserialize(std::span<const std::uint8_t> payload) {
    auto [nonce, offset] = wire::unpackUint64Le(payload, 0);
    (void)offset;
    return PingMessage{nonce};
}

std::vector<std::uint8_t> PongMessage::serialize() const { return wire::packUint64Le(nonce); }

PongMessage PongMessage::deserialize(std::span<const std::uint8_t> payload) {
    auto [nonce, offset] = wire::unpackUint64Le(payload, 0);
    (void)offset;
    return PongMessage{nonce};
}

}  // namespace cpbitnode::messages
