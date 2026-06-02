#include "cpbitnode/consensus/sha256.hpp"

#include <array>
#include <cstring>
#include <iomanip>
#include <sstream>

namespace cpbitnode::consensus {
namespace {

constexpr std::array<std::uint32_t, 64> kRoundConstants = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

inline std::uint32_t rotr(std::uint32_t x, int n) { return (x >> n) | (x << (32 - n)); }

inline std::uint32_t ch(std::uint32_t x, std::uint32_t y, std::uint32_t z) { return (x & y) ^ (~x & z); }
inline std::uint32_t maj(std::uint32_t x, std::uint32_t y, std::uint32_t z) { return (x & y) ^ (x & z) ^ (y & z); }
inline std::uint32_t sig0(std::uint32_t x) { return rotr(x, 2) ^ rotr(x, 13) ^ rotr(x, 22); }
inline std::uint32_t sig1(std::uint32_t x) { return rotr(x, 6) ^ rotr(x, 11) ^ rotr(x, 25); }
inline std::uint32_t gam0(std::uint32_t x) { return rotr(x, 7) ^ rotr(x, 18) ^ (x >> 3); }
inline std::uint32_t gam1(std::uint32_t x) { return rotr(x, 17) ^ rotr(x, 19) ^ (x >> 10); }

void sha256Block(const std::uint8_t block[64], std::uint32_t state[8]) {
    std::uint32_t w[64];
    for (int i = 0; i < 16; ++i) {
        w[i] = (static_cast<std::uint32_t>(block[i * 4]) << 24) |
               (static_cast<std::uint32_t>(block[i * 4 + 1]) << 16) |
               (static_cast<std::uint32_t>(block[i * 4 + 2]) << 8) |
               static_cast<std::uint32_t>(block[i * 4 + 3]);
    }
    for (int i = 16; i < 64; ++i) {
        w[i] = gam1(w[i - 2]) + w[i - 7] + gam0(w[i - 15]) + w[i - 16];
    }

    std::uint32_t a = state[0];
    std::uint32_t b = state[1];
    std::uint32_t c = state[2];
    std::uint32_t d = state[3];
    std::uint32_t e = state[4];
    std::uint32_t f = state[5];
    std::uint32_t g = state[6];
    std::uint32_t h = state[7];

    for (int i = 0; i < 64; ++i) {
        const std::uint32_t t1 = h + sig1(e) + ch(e, f, g) + kRoundConstants[i] + w[i];
        const std::uint32_t t2 = sig0(a) + maj(a, b, c);
        h = g;
        g = f;
        f = e;
        e = d + t1;
        d = c;
        c = b;
        b = a;
        a = t1 + t2;
    }

    state[0] += a;
    state[1] += b;
    state[2] += c;
    state[3] += d;
    state[4] += e;
    state[5] += f;
    state[6] += g;
    state[7] += h;
}

}  // namespace

std::vector<std::uint8_t> sha256(std::span<const std::uint8_t> data) {
    std::uint32_t state[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                              0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};

    std::uint64_t bitLen = static_cast<std::uint64_t>(data.size()) * 8;
    std::vector<std::uint8_t> buf(data.begin(), data.end());
    buf.push_back(0x80);
    while ((buf.size() % 64) != 56) {
        buf.push_back(0x00);
    }
    for (int i = 7; i >= 0; --i) {
        buf.push_back(static_cast<std::uint8_t>((bitLen >> (i * 8)) & 0xff));
    }

    for (std::size_t offset = 0; offset < buf.size(); offset += 64) {
        sha256Block(buf.data() + offset, state);
    }

    std::vector<std::uint8_t> out(32);
    for (int i = 0; i < 8; ++i) {
        out[i * 4] = static_cast<std::uint8_t>((state[i] >> 24) & 0xff);
        out[i * 4 + 1] = static_cast<std::uint8_t>((state[i] >> 16) & 0xff);
        out[i * 4 + 2] = static_cast<std::uint8_t>((state[i] >> 8) & 0xff);
        out[i * 4 + 3] = static_cast<std::uint8_t>(state[i] & 0xff);
    }
    return out;
}

std::vector<std::uint8_t> doubleSha256(std::span<const std::uint8_t> data) {
    const auto first = sha256(data);
    return sha256(first);
}

std::string sha256Hex(std::span<const std::uint8_t> data) {
    const auto digest = sha256(data);
    std::ostringstream oss;
    for (const auto b : digest) {
        oss << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(b);
    }
    return oss.str();
}

}  // namespace cpbitnode::consensus
