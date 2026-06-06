#include "cpbitnode/messages/inventory.hpp"

#include "cpbitnode/wire/serialize.hpp"

#include <stdexcept>
#include <tuple>

namespace cpbitnode::messages {
namespace {

bool isBlockType(std::uint32_t type) { return type == MSG_BLOCK || type == MSG_WITNESS_BLOCK; }

bool isTxType(std::uint32_t type) { return type == MSG_TX || type == MSG_WITNESS_TX; }

std::vector<InventoryVector> deserializeInventoryList(std::span<const std::uint8_t> payload) {
    auto [count, offset] = wire::readVarint(payload, 0);
    std::vector<InventoryVector> items;
    items.reserve(static_cast<std::size_t>(count));
    for (std::uint64_t i = 0; i < count; ++i) {
        InventoryVector item;
        std::tie(item, offset) = InventoryVector::deserialize(payload, offset);
        items.push_back(std::move(item));
    }
    return items;
}

std::vector<std::uint8_t> serializeInventoryList(const std::vector<InventoryVector>& inventory) {
    auto payload = wire::writeVarint(inventory.size());
    for (const auto& item : inventory) {
        const auto encoded = item.serialize();
        payload.insert(payload.end(), encoded.begin(), encoded.end());
    }
    return payload;
}

}  // namespace

std::vector<std::uint8_t> InventoryVector::serialize() const {
    if (hash.size() != 32) {
        throw std::runtime_error("inventory hash must be 32 bytes");
    }
    auto out = wire::packUint32Le(type);
    out.insert(out.end(), hash.begin(), hash.end());
    return out;
}

std::pair<InventoryVector, std::size_t> InventoryVector::deserialize(std::span<const std::uint8_t> data,
                                                                     std::size_t offset) {
    std::uint32_t invType = 0;
    std::tie(invType, offset) = wire::unpackUint32Le(data, offset);
    if (offset + 32 > data.size()) {
        throw std::runtime_error("truncated inventory vector");
    }
    InventoryVector item;
    item.type = invType;
    item.hash.assign(data.begin() + static_cast<std::ptrdiff_t>(offset),
                     data.begin() + static_cast<std::ptrdiff_t>(offset + 32));
    offset += 32;
    return {item, offset};
}

std::vector<std::uint8_t> InvMessage::serialize() const { return serializeInventoryList(inventory); }

InvMessage InvMessage::deserialize(std::span<const std::uint8_t> payload) {
    return InvMessage{deserializeInventoryList(payload)};
}

std::vector<std::uint8_t> GetDataMessage::serialize() const { return serializeInventoryList(inventory); }

GetDataMessage GetDataMessage::deserialize(std::span<const std::uint8_t> payload) {
    return GetDataMessage{deserializeInventoryList(payload)};
}

std::vector<std::uint8_t> NotFoundMessage::serialize() const { return serializeInventoryList(inventory); }

NotFoundMessage NotFoundMessage::deserialize(std::span<const std::uint8_t> payload) {
    return NotFoundMessage{deserializeInventoryList(payload)};
}

std::vector<std::uint8_t> GetHeadersMessage::serialize() const {
    if (hashStop.size() != 32) {
        throw std::runtime_error("getheaders hash_stop must be 32 bytes");
    }
    std::vector<std::uint8_t> payload = wire::packInt32Le(version);
    const auto countBytes = wire::writeVarint(locatorHashes.size());
    payload.insert(payload.end(), countBytes.begin(), countBytes.end());
    for (const auto& hash : locatorHashes) {
        if (hash.size() != 32) {
            throw std::runtime_error("locator hash must be 32 bytes");
        }
        payload.insert(payload.end(), hash.begin(), hash.end());
    }
    payload.insert(payload.end(), hashStop.begin(), hashStop.end());
    return payload;
}

GetHeadersMessage GetHeadersMessage::deserialize(std::span<const std::uint8_t> payload) {
    if (payload.size() < 4 + 32) {
        throw std::runtime_error("invalid getheaders payload length");
    }
    std::int32_t version = 0;
    std::size_t offset = 0;
    std::tie(version, offset) = wire::unpackInt32Le(payload, offset);
    std::uint64_t count = 0;
    std::tie(count, offset) = wire::readVarint(payload, offset);
    GetHeadersMessage message;
    message.version = version;
    message.locatorHashes.reserve(static_cast<std::size_t>(count));
    for (std::uint64_t i = 0; i < count; ++i) {
        if (offset + 32 > payload.size()) {
            throw std::runtime_error("invalid getheaders payload length");
        }
        message.locatorHashes.emplace_back(payload.begin() + static_cast<std::ptrdiff_t>(offset),
                                           payload.begin() + static_cast<std::ptrdiff_t>(offset + 32));
        offset += 32;
    }
    if (offset + 32 != payload.size()) {
        throw std::runtime_error("invalid getheaders payload length");
    }
    message.hashStop.assign(payload.begin() + static_cast<std::ptrdiff_t>(offset),
                            payload.begin() + static_cast<std::ptrdiff_t>(offset + 32));
    return message;
}

bool hasBlockInventory(const InvMessage& message) {
    for (const auto& item : message.inventory) {
        if (isBlockType(item.type)) {
            return true;
        }
    }
    return false;
}

bool hasTransactionInventory(const InvMessage& message) {
    for (const auto& item : message.inventory) {
        if (isTxType(item.type)) {
            return true;
        }
    }
    return false;
}

std::vector<std::vector<std::uint8_t>> blockInventoryHashes(const InvMessage& message) {
    std::vector<std::vector<std::uint8_t>> hashes;
    for (const auto& item : message.inventory) {
        if (isBlockType(item.type)) {
            hashes.push_back(item.hash);
        }
    }
    return hashes;
}

}  // namespace cpbitnode::messages
