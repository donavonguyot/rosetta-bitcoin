#include "cpbitnode/wire/serialize.hpp"

#include "cpbitnode/consensus/sha256.hpp"

#include <cstring>
#include <stdexcept>

namespace cpbitnode::wire {

std::vector<std::uint8_t> messageChecksum(std::span<const std::uint8_t> payload) {
    const auto hash = consensus::doubleSha256(payload);
    return std::vector<std::uint8_t>(hash.begin(), hash.begin() + 4);
}

std::vector<std::uint8_t> packInt32Le(std::int32_t value) {
    std::vector<std::uint8_t> out(4);
    std::memcpy(out.data(), &value, 4);
    return out;
}

std::vector<std::uint8_t> packInt64Le(std::int64_t value) {
    std::vector<std::uint8_t> out(8);
    std::memcpy(out.data(), &value, 8);
    return out;
}

std::vector<std::uint8_t> packUint32Le(std::uint32_t value) {
    std::vector<std::uint8_t> out(4);
    std::memcpy(out.data(), &value, 4);
    return out;
}

std::vector<std::uint8_t> packUint64Le(std::uint64_t value) {
    std::vector<std::uint8_t> out(8);
    std::memcpy(out.data(), &value, 8);
    return out;
}

std::pair<std::int32_t, std::size_t> unpackInt32Le(std::span<const std::uint8_t> data, std::size_t offset) {
    if (offset + 4 > data.size()) {
        throw std::runtime_error("int32 read past end");
    }
    std::int32_t value = 0;
    std::memcpy(&value, data.data() + offset, 4);
    return {value, offset + 4};
}

std::pair<std::int64_t, std::size_t> unpackInt64Le(std::span<const std::uint8_t> data, std::size_t offset) {
    if (offset + 8 > data.size()) {
        throw std::runtime_error("int64 read past end");
    }
    std::int64_t value = 0;
    std::memcpy(&value, data.data() + offset, 8);
    return {value, offset + 8};
}

std::pair<std::uint32_t, std::size_t> unpackUint32Le(std::span<const std::uint8_t> data, std::size_t offset) {
    if (offset + 4 > data.size()) {
        throw std::runtime_error("uint32 read past end");
    }
    std::uint32_t value = 0;
    std::memcpy(&value, data.data() + offset, 4);
    return {value, offset + 4};
}

std::pair<std::uint64_t, std::size_t> unpackUint64Le(std::span<const std::uint8_t> data, std::size_t offset) {
    if (offset + 8 > data.size()) {
        throw std::runtime_error("uint64 read past end");
    }
    std::uint64_t value = 0;
    std::memcpy(&value, data.data() + offset, 8);
    return {value, offset + 8};
}

std::pair<std::uint64_t, std::size_t> readVarint(std::span<const std::uint8_t> data, std::size_t offset) {
    if (offset >= data.size()) {
        throw std::runtime_error("varint read past end");
    }
    const auto prefix = data[offset++];
    if (prefix < 0xFD) {
        return {prefix, offset};
    }
    if (prefix == 0xFD) {
        if (offset + 2 > data.size()) {
            throw std::runtime_error("varint read past end");
        }
        std::uint16_t value = 0;
        std::memcpy(&value, data.data() + offset, 2);
        return {value, offset + 2};
    }
    if (prefix == 0xFE) {
        auto [value, next] = unpackUint32Le(data, offset);
        return {value, next};
    }
    return unpackUint64Le(data, offset);
}

std::vector<std::uint8_t> writeVarint(std::uint64_t value) {
    if (value < 0xFD) {
        return {static_cast<std::uint8_t>(value)};
    }
    if (value <= 0xFFFF) {
        const auto v = static_cast<std::uint16_t>(value);
        return {0xFD, static_cast<std::uint8_t>(v & 0xff), static_cast<std::uint8_t>((v >> 8) & 0xff)};
    }
    if (value <= 0xFFFFFFFF) {
        auto out = packUint32Le(static_cast<std::uint32_t>(value));
        out.insert(out.begin(), 0xFE);
        return out;
    }
    auto out = packUint64Le(value);
    out.insert(out.begin(), 0xFF);
    return out;
}

}  // namespace cpbitnode::wire
