#pragma once

#include <cstdint>
#include <span>
#include <string>
#include <vector>

namespace cpbitnode::messages {

inline constexpr std::uint64_t NODE_NETWORK = 1u << 0;
inline constexpr std::uint64_t NODE_WITNESS = 1u << 3;

struct NetworkAddress {
    std::uint64_t services = 0;
    std::string ip;
    std::uint16_t port = 0;

    std::vector<std::uint8_t> serialize(bool withTimestamp = true, std::int64_t timestamp = 0) const;
    static std::pair<NetworkAddress, std::size_t> deserialize(std::span<const std::uint8_t> data,
                                                              std::size_t offset = 0,
                                                              bool withTimestamp = true);
};

struct VersionMessage {
    static constexpr const char* kCommand = "version";

    std::int32_t version = 0;
    std::uint64_t services = 0;
    std::int64_t timestamp = 0;
    NetworkAddress addrRecv;
    NetworkAddress addrFrom;
    std::uint64_t nonce = 0;
    std::string userAgent;
    std::int32_t startHeight = 0;
    bool relay = true;

    std::vector<std::uint8_t> serialize() const;
    static VersionMessage deserialize(std::span<const std::uint8_t> payload);

    static VersionMessage build(std::int32_t protocolVersion, std::uint64_t services, const NetworkAddress& addrRecv,
                                const NetworkAddress& addrFrom, const std::string& userAgent,
                                std::int32_t startHeight = 0, bool relay = true);
};

struct VerAckMessage {
    static constexpr const char* kCommand = "verack";
    std::vector<std::uint8_t> serialize() const;
    static VerAckMessage deserialize(std::span<const std::uint8_t> payload);
};

struct SendHeadersMessage {
    static constexpr const char* kCommand = "sendheaders";
    std::vector<std::uint8_t> serialize() const;
    static SendHeadersMessage deserialize(std::span<const std::uint8_t> payload);
};

struct PingMessage {
    static constexpr const char* kCommand = "ping";
    std::uint64_t nonce = 0;

    std::vector<std::uint8_t> serialize() const;
    static PingMessage deserialize(std::span<const std::uint8_t> payload);
};

struct PongMessage {
    static constexpr const char* kCommand = "pong";
    std::uint64_t nonce = 0;

    std::vector<std::uint8_t> serialize() const;
    static PongMessage deserialize(std::span<const std::uint8_t> payload);
};

}  // namespace cpbitnode::messages
