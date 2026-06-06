#include "cpbitnode/messages/bip152_short_txid.hpp"

#include "cpbitnode/consensus/sha256.hpp"
#include "cpbitnode/wire/serialize.hpp"

#include <stdexcept>
#include <tuple>

namespace cpbitnode::messages {
namespace {

constexpr std::uint64_t kU64Mask = 0xFFFFFFFFFFFFFFFFull;
constexpr std::uint64_t kC0 = 0x736F6D6570736575ull;
constexpr std::uint64_t kC1 = 0x646F72616E646F6Dull;
constexpr std::uint64_t kC2 = 0x6C7967656E657261ull;
constexpr std::uint64_t kC3 = 0x7465646279746573ull;

std::uint64_t rotlU64(std::uint64_t value, int bits) {
    value &= kU64Mask;
    return ((value << bits) | (value >> (64 - bits))) & kU64Mask;
}

void sipRound(std::uint64_t& v0, std::uint64_t& v1, std::uint64_t& v2, std::uint64_t& v3) {
    v0 = (v0 + v1) & kU64Mask;
    v1 = rotlU64(v1 ^ v0, 13);
    v0 = rotlU64(v0, 32);
    v2 = (v2 + v3) & kU64Mask;
    v3 = rotlU64(v3 ^ v2, 16);
    v0 = (v0 + v3) & kU64Mask;
    v3 = rotlU64(v3 ^ v0, 21);
    v2 = (v2 + v1) & kU64Mask;
    v1 = rotlU64(v1 ^ v2, 17);
    v2 = rotlU64(v2, 32);
}

std::tuple<std::uint64_t, std::uint64_t, std::uint64_t, std::uint64_t> sipStateFromKeys(std::uint64_t k0,
                                                                                         std::uint64_t k1) {
    return {
        (kC0 ^ k0) & kU64Mask,
        (kC1 ^ k1) & kU64Mask,
        (kC2 ^ k0) & kU64Mask,
        (kC3 ^ k1) & kU64Mask,
    };
}

}  // namespace

std::pair<std::uint64_t, std::uint64_t> shortIdNonceKey(const BlockHeader& header, std::uint64_t shortIdNonce) {
    auto payload = header.serialize();
    const auto nonceBytes = wire::packUint64Le(shortIdNonce);
    payload.insert(payload.end(), nonceBytes.begin(), nonceBytes.end());
    const auto digest = consensus::sha256(payload);
    const auto [k0, afterK0] = wire::unpackUint64Le(digest, 0);
    const auto [k1, afterK1] = wire::unpackUint64Le(digest, afterK0);
    (void)afterK1;
    return {k0, k1};
}

std::vector<std::uint8_t> presaltedShortIdFromUint256Digest(std::uint64_t k0,
                                                            std::uint64_t k1,
                                                            std::span<const std::uint8_t> digest32) {
    if (digest32.size() != 32) {
        throw std::runtime_error("digest must be 32 bytes");
    }
    auto [v0, v1, v2, v3] = sipStateFromKeys(k0, k1);
    for (std::size_t chunk = 0; chunk < 32; chunk += 8) {
        auto [d, afterD] = wire::unpackUint64Le(digest32, chunk);
        if (afterD != chunk + 8) {
            throw std::runtime_error("digest chunk truncated");
        }
        v3 = (v3 ^ d) & kU64Mask;
        sipRound(v0, v1, v2, v3);
        sipRound(v0, v1, v2, v3);
        v0 = (v0 ^ d) & kU64Mask;
    }
    const std::uint64_t tail = (4ull << 59) & kU64Mask;
    v3 = (v3 ^ tail) & kU64Mask;
    sipRound(v0, v1, v2, v3);
    sipRound(v0, v1, v2, v3);
    v0 = (v0 ^ tail) & kU64Mask;
    v2 = (v2 ^ 0xFF) & kU64Mask;
    sipRound(v0, v1, v2, v3);
    sipRound(v0, v1, v2, v3);
    sipRound(v0, v1, v2, v3);
    sipRound(v0, v1, v2, v3);
    std::uint64_t out = (v0 ^ v1 ^ v2 ^ v3) & kU64Mask;
    out &= kU64Mask >> 16;
    std::vector<std::uint8_t> result(6);
    for (int i = 0; i < 6; ++i) {
        result[static_cast<std::size_t>(i)] = static_cast<std::uint8_t>((out >> (8 * i)) & 0xFF);
    }
    return result;
}

}  // namespace cpbitnode::messages
