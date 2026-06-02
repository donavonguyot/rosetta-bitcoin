#include "cpbitnode/consensus/sha1.hpp"

#include <array>
#include <cstring>
#include <vector>

namespace cpbitnode::consensus {
namespace {

std::uint32_t rol(std::uint32_t value, int bits) {
    return (value << bits) | (value >> (32 - bits));
}

void sha1Transform(std::array<std::uint32_t, 5>& state, const std::uint8_t* chunk) {
    std::uint32_t w[80];
    for (int i = 0; i < 16; ++i) {
        w[i] = (static_cast<std::uint32_t>(chunk[i * 4]) << 24) |
               (static_cast<std::uint32_t>(chunk[i * 4 + 1]) << 16) |
               (static_cast<std::uint32_t>(chunk[i * 4 + 2]) << 8) |
               static_cast<std::uint32_t>(chunk[i * 4 + 3]);
    }
    for (int i = 16; i < 80; ++i) {
        w[i] = rol(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
    }

    std::uint32_t a = state[0];
    std::uint32_t b = state[1];
    std::uint32_t c = state[2];
    std::uint32_t d = state[3];
    std::uint32_t e = state[4];

    for (int i = 0; i < 80; ++i) {
        std::uint32_t f = 0;
        std::uint32_t k = 0;
        if (i < 20) {
            f = (b & c) | ((~b) & d);
            k = 0x5A827999;
        } else if (i < 40) {
            f = b ^ c ^ d;
            k = 0x6ED9EBA1;
        } else if (i < 60) {
            f = (b & c) | (b & d) | (c & d);
            k = 0x8F1BBCDC;
        } else {
            f = b ^ c ^ d;
            k = 0xCA62C1D6;
        }
        const std::uint32_t temp = rol(a, 5) + f + e + k + w[i];
        e = d;
        d = c;
        c = rol(b, 30);
        b = a;
        a = temp;
    }

    state[0] += a;
    state[1] += b;
    state[2] += c;
    state[3] += d;
    state[4] += e;
}

}  // namespace

std::vector<std::uint8_t> sha1Digest(std::span<const std::uint8_t> data) {
    std::array<std::uint32_t, 5> state{0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0};
    std::uint64_t bitLen = static_cast<std::uint64_t>(data.size()) * 8;

    std::vector<std::uint8_t> buffer(data.begin(), data.end());
    buffer.push_back(0x80);
    while ((buffer.size() % 64) != 56) {
        buffer.push_back(0x00);
    }
    for (int i = 7; i >= 0; --i) {
        buffer.push_back(static_cast<std::uint8_t>((bitLen >> (8 * i)) & 0xff));
    }

    for (std::size_t offset = 0; offset < buffer.size(); offset += 64) {
        sha1Transform(state, buffer.data() + offset);
    }

    std::vector<std::uint8_t> out(20);
    for (int i = 0; i < 5; ++i) {
        out[static_cast<std::size_t>(i * 4)] = static_cast<std::uint8_t>((state[static_cast<std::size_t>(i)] >> 24) & 0xff);
        out[static_cast<std::size_t>(i * 4 + 1)] =
            static_cast<std::uint8_t>((state[static_cast<std::size_t>(i)] >> 16) & 0xff);
        out[static_cast<std::size_t>(i * 4 + 2)] =
            static_cast<std::uint8_t>((state[static_cast<std::size_t>(i)] >> 8) & 0xff);
        out[static_cast<std::size_t>(i * 4 + 3)] = static_cast<std::uint8_t>(state[static_cast<std::size_t>(i)] & 0xff);
    }
    return out;
}

}  // namespace cpbitnode::consensus
