#pragma once

#include <cstdint>
#include <span>
#include <vector>

namespace cpbitnode::messages {

inline constexpr std::uint32_t MSG_TX = 1;
inline constexpr std::uint32_t MSG_BLOCK = 2;
inline constexpr std::uint32_t MSG_WITNESS_TX = MSG_TX | (1u << 30);
inline constexpr std::uint32_t MSG_WITNESS_BLOCK = MSG_BLOCK | (1u << 30);

struct InventoryVector {
    std::uint32_t type = 0;
    std::vector<std::uint8_t> hash;  // 32 bytes, internal byte order

    std::vector<std::uint8_t> serialize() const;
    static std::pair<InventoryVector, std::size_t> deserialize(std::span<const std::uint8_t> data,
                                                               std::size_t offset = 0);
};

struct InvMessage {
    static constexpr const char* kCommand = "inv";
    std::vector<InventoryVector> inventory;

    std::vector<std::uint8_t> serialize() const;
    static InvMessage deserialize(std::span<const std::uint8_t> payload);
};

struct GetDataMessage {
    static constexpr const char* kCommand = "getdata";
    std::vector<InventoryVector> inventory;

    std::vector<std::uint8_t> serialize() const;
    static GetDataMessage deserialize(std::span<const std::uint8_t> payload);
};

struct NotFoundMessage {
    static constexpr const char* kCommand = "notfound";
    std::vector<InventoryVector> inventory;

    std::vector<std::uint8_t> serialize() const;
    static NotFoundMessage deserialize(std::span<const std::uint8_t> payload);
};

struct GetHeadersMessage {
    static constexpr const char* kCommand = "getheaders";

    std::int32_t version = 0;
    std::vector<std::vector<std::uint8_t>> locatorHashes;
    std::vector<std::uint8_t> hashStop;

    std::vector<std::uint8_t> serialize() const;
    static GetHeadersMessage deserialize(std::span<const std::uint8_t> payload);
};

bool hasBlockInventory(const InvMessage& message);
bool hasTransactionInventory(const InvMessage& message);
std::vector<std::vector<std::uint8_t>> blockInventoryHashes(const InvMessage& message);

}  // namespace cpbitnode::messages
