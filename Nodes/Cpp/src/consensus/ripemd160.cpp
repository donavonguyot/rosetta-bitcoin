#include "cpbitnode/consensus/ripemd160.hpp"

#include <cstring>
#include <vector>

namespace cpbitnode::consensus {
namespace {

std::uint32_t readLE32(const std::uint8_t* ptr) {
    return static_cast<std::uint32_t>(ptr[0]) | (static_cast<std::uint32_t>(ptr[1]) << 8) |
           (static_cast<std::uint32_t>(ptr[2]) << 16) | (static_cast<std::uint32_t>(ptr[3]) << 24);
}

void writeLE32(std::uint8_t* ptr, std::uint32_t v) {
    ptr[0] = static_cast<std::uint8_t>(v);
    ptr[1] = static_cast<std::uint8_t>(v >> 8);
    ptr[2] = static_cast<std::uint8_t>(v >> 16);
    ptr[3] = static_cast<std::uint8_t>(v >> 24);
}

std::uint32_t rol(std::uint32_t x, int i) { return (x << i) | (x >> (32 - i)); }

std::uint32_t f1(std::uint32_t x, std::uint32_t y, std::uint32_t z) { return x ^ y ^ z; }
std::uint32_t f2(std::uint32_t x, std::uint32_t y, std::uint32_t z) { return (x & y) | (~x & z); }
std::uint32_t f3(std::uint32_t x, std::uint32_t y, std::uint32_t z) { return (x | ~y) ^ z; }
std::uint32_t f4(std::uint32_t x, std::uint32_t y, std::uint32_t z) { return (x & z) | (y & ~z); }
std::uint32_t f5(std::uint32_t x, std::uint32_t y, std::uint32_t z) { return x ^ (y | ~z); }

void round(std::uint32_t& a, std::uint32_t b, std::uint32_t& c, std::uint32_t d, std::uint32_t e,
           std::uint32_t (*f)(std::uint32_t, std::uint32_t, std::uint32_t), std::uint32_t x, std::uint32_t k, int r) {
    a = rol(a + f(b, c, d) + x + k, r) + e;
    c = rol(c, 10);
}

void transform(std::uint32_t* s, const std::uint8_t* chunk) {
    std::uint32_t a1 = s[0], b1 = s[1], c1 = s[2], d1 = s[3], e1 = s[4];
    std::uint32_t a2 = a1, b2 = b1, c2 = c1, d2 = d1, e2 = e1;
    const std::uint32_t w0 = readLE32(chunk + 0);
    const std::uint32_t w1 = readLE32(chunk + 4);
    const std::uint32_t w2 = readLE32(chunk + 8);
    const std::uint32_t w3 = readLE32(chunk + 12);
    const std::uint32_t w4 = readLE32(chunk + 16);
    const std::uint32_t w5 = readLE32(chunk + 20);
    const std::uint32_t w6 = readLE32(chunk + 24);
    const std::uint32_t w7 = readLE32(chunk + 28);
    const std::uint32_t w8 = readLE32(chunk + 32);
    const std::uint32_t w9 = readLE32(chunk + 36);
    const std::uint32_t w10 = readLE32(chunk + 40);
    const std::uint32_t w11 = readLE32(chunk + 44);
    const std::uint32_t w12 = readLE32(chunk + 48);
    const std::uint32_t w13 = readLE32(chunk + 52);
    const std::uint32_t w14 = readLE32(chunk + 56);
    const std::uint32_t w15 = readLE32(chunk + 60);

#define R11(a, b, c, d, e, x, r) round(a, b, c, d, e, f1, x, 0, r)
#define R21(a, b, c, d, e, x, r) round(a, b, c, d, e, f2, x, 0x5A827999u, r)
#define R31(a, b, c, d, e, x, r) round(a, b, c, d, e, f3, x, 0x6ED9EBA1u, r)
#define R41(a, b, c, d, e, x, r) round(a, b, c, d, e, f4, x, 0x8F1BBCDCu, r)
#define R51(a, b, c, d, e, x, r) round(a, b, c, d, e, f5, x, 0xA953FD4Eu, r)
#define R12(a, b, c, d, e, x, r) round(a, b, c, d, e, f5, x, 0x50A28BE6u, r)
#define R22(a, b, c, d, e, x, r) round(a, b, c, d, e, f4, x, 0x5C4DD124u, r)
#define R32(a, b, c, d, e, x, r) round(a, b, c, d, e, f3, x, 0x6D703EF3u, r)
#define R42(a, b, c, d, e, x, r) round(a, b, c, d, e, f2, x, 0x7A6D76E9u, r)
#define R52(a, b, c, d, e, x, r) round(a, b, c, d, e, f1, x, 0, r)

    R11(a1, b1, c1, d1, e1, w0, 11);
    R12(a2, b2, c2, d2, e2, w5, 8);
    R11(e1, a1, b1, c1, d1, w1, 14);
    R12(e2, a2, b2, c2, d2, w14, 9);
    R11(d1, e1, a1, b1, c1, w2, 15);
    R12(d2, e2, a2, b2, c2, w7, 9);
    R11(c1, d1, e1, a1, b1, w3, 12);
    R12(c2, d2, e2, a2, b2, w0, 11);
    R11(b1, c1, d1, e1, a1, w4, 5);
    R12(b2, c2, d2, e2, a2, w9, 13);
    R11(a1, b1, c1, d1, e1, w5, 8);
    R12(a2, b2, c2, d2, e2, w2, 15);
    R11(e1, a1, b1, c1, d1, w6, 7);
    R12(e2, a2, b2, c2, d2, w11, 15);
    R11(d1, e1, a1, b1, c1, w7, 9);
    R12(d2, e2, a2, b2, c2, w4, 5);
    R11(c1, d1, e1, a1, b1, w8, 11);
    R12(c2, d2, e2, a2, b2, w13, 7);
    R11(b1, c1, d1, e1, a1, w9, 13);
    R12(b2, c2, d2, e2, a2, w6, 7);
    R11(a1, b1, c1, d1, e1, w10, 14);
    R12(a2, b2, c2, d2, e2, w15, 8);
    R11(e1, a1, b1, c1, d1, w11, 15);
    R12(e2, a2, b2, c2, d2, w8, 11);
    R11(d1, e1, a1, b1, c1, w12, 6);
    R12(d2, e2, a2, b2, c2, w1, 14);
    R11(c1, d1, e1, a1, b1, w13, 7);
    R12(c2, d2, e2, a2, b2, w10, 14);
    R11(b1, c1, d1, e1, a1, w14, 9);
    R12(b2, c2, d2, e2, a2, w3, 12);
    R11(a1, b1, c1, d1, e1, w15, 8);
    R12(a2, b2, c2, d2, e2, w12, 6);

    R21(e1, a1, b1, c1, d1, w7, 7);
    R22(e2, a2, b2, c2, d2, w6, 9);
    R21(d1, e1, a1, b1, c1, w4, 6);
    R22(d2, e2, a2, b2, c2, w11, 13);
    R21(c1, d1, e1, a1, b1, w13, 8);
    R22(c2, d2, e2, a2, b2, w3, 15);
    R21(b1, c1, d1, e1, a1, w1, 13);
    R22(b2, c2, d2, e2, a2, w7, 7);
    R21(a1, b1, c1, d1, e1, w10, 11);
    R22(a2, b2, c2, d2, e2, w0, 12);
    R21(e1, a1, b1, c1, d1, w6, 9);
    R22(e2, a2, b2, c2, d2, w13, 8);
    R21(d1, e1, a1, b1, c1, w15, 7);
    R22(d2, e2, a2, b2, c2, w5, 9);
    R21(c1, d1, e1, a1, b1, w3, 15);
    R22(c2, d2, e2, a2, b2, w10, 11);
    R21(b1, c1, d1, e1, a1, w12, 7);
    R22(b2, c2, d2, e2, a2, w14, 7);
    R21(a1, b1, c1, d1, e1, w0, 12);
    R22(a2, b2, c2, d2, e2, w15, 7);
    R21(e1, a1, b1, c1, d1, w9, 15);
    R22(e2, a2, b2, c2, d2, w8, 12);
    R21(d1, e1, a1, b1, c1, w5, 9);
    R22(d2, e2, a2, b2, c2, w12, 7);
    R21(c1, d1, e1, a1, b1, w2, 11);
    R22(c2, d2, e2, a2, b2, w4, 6);
    R21(b1, c1, d1, e1, a1, w14, 7);
    R22(b2, c2, d2, e2, a2, w9, 15);
    R21(a1, b1, c1, d1, e1, w11, 13);
    R22(a2, b2, c2, d2, e2, w1, 13);
    R21(e1, a1, b1, c1, d1, w8, 12);
    R22(e2, a2, b2, c2, d2, w2, 11);

    R31(d1, e1, a1, b1, c1, w3, 11);
    R32(d2, e2, a2, b2, c2, w15, 9);
    R31(c1, d1, e1, a1, b1, w10, 13);
    R32(c2, d2, e2, a2, b2, w5, 7);
    R31(b1, c1, d1, e1, a1, w14, 6);
    R32(b2, c2, d2, e2, a2, w1, 15);
    R31(a1, b1, c1, d1, e1, w4, 7);
    R32(a2, b2, c2, d2, e2, w3, 11);
    R31(e1, a1, b1, c1, d1, w9, 14);
    R32(e2, a2, b2, c2, d2, w7, 8);
    R31(d1, e1, a1, b1, c1, w15, 9);
    R32(d2, e2, a2, b2, c2, w14, 6);
    R31(c1, d1, e1, a1, b1, w8, 13);
    R32(c2, d2, e2, a2, b2, w6, 6);
    R31(b1, c1, d1, e1, a1, w1, 15);
    R32(b2, c2, d2, e2, a2, w9, 14);
    R31(a1, b1, c1, d1, e1, w2, 14);
    R32(a2, b2, c2, d2, e2, w11, 12);
    R31(e1, a1, b1, c1, d1, w7, 8);
    R32(e2, a2, b2, c2, d2, w8, 13);
    R31(d1, e1, a1, b1, c1, w0, 13);
    R32(d2, e2, a2, b2, c2, w12, 5);
    R31(c1, d1, e1, a1, b1, w6, 6);
    R32(c2, d2, e2, a2, b2, w2, 14);
    R31(b1, c1, d1, e1, a1, w13, 5);
    R32(b2, c2, d2, e2, a2, w10, 13);
    R31(a1, b1, c1, d1, e1, w11, 12);
    R32(a2, b2, c2, d2, e2, w0, 13);
    R31(e1, a1, b1, c1, d1, w5, 7);
    R32(e2, a2, b2, c2, d2, w4, 7);
    R31(d1, e1, a1, b1, c1, w12, 5);
    R32(d2, e2, a2, b2, c2, w13, 5);

    R41(c1, d1, e1, a1, b1, w1, 11);
    R42(c2, d2, e2, a2, b2, w8, 15);
    R41(b1, c1, d1, e1, a1, w9, 12);
    R42(b2, c2, d2, e2, a2, w6, 5);
    R41(a1, b1, c1, d1, e1, w11, 14);
    R42(a2, b2, c2, d2, e2, w4, 8);
    R41(e1, a1, b1, c1, d1, w10, 15);
    R42(e2, a2, b2, c2, d2, w1, 11);
    R41(d1, e1, a1, b1, c1, w0, 14);
    R42(d2, e2, a2, b2, c2, w3, 14);
    R41(c1, d1, e1, a1, b1, w8, 15);
    R42(c2, d2, e2, a2, b2, w11, 14);
    R41(b1, c1, d1, e1, a1, w12, 9);
    R42(b2, c2, d2, e2, a2, w15, 6);
    R41(a1, b1, c1, d1, e1, w4, 8);
    R42(a2, b2, c2, d2, e2, w0, 14);
    R41(e1, a1, b1, c1, d1, w13, 9);
    R42(e2, a2, b2, c2, d2, w5, 6);
    R41(d1, e1, a1, b1, c1, w3, 14);
    R42(d2, e2, a2, b2, c2, w12, 9);
    R41(c1, d1, e1, a1, b1, w7, 5);
    R42(c2, d2, e2, a2, b2, w2, 12);
    R41(b1, c1, d1, e1, a1, w15, 6);
    R42(b2, c2, d2, e2, a2, w13, 9);
    R41(a1, b1, c1, d1, e1, w14, 8);
    R42(a2, b2, c2, d2, e2, w9, 12);
    R41(e1, a1, b1, c1, d1, w5, 6);
    R42(e2, a2, b2, c2, d2, w7, 5);
    R41(d1, e1, a1, b1, c1, w6, 5);
    R42(d2, e2, a2, b2, c2, w10, 15);
    R41(c1, d1, e1, a1, b1, w2, 12);
    R42(c2, d2, e2, a2, b2, w14, 8);

    R51(b1, c1, d1, e1, a1, w4, 9);
    R52(b2, c2, d2, e2, a2, w12, 8);
    R51(a1, b1, c1, d1, e1, w0, 15);
    R52(a2, b2, c2, d2, e2, w15, 5);
    R51(e1, a1, b1, c1, d1, w5, 5);
    R52(e2, a2, b2, c2, d2, w10, 12);
    R51(d1, e1, a1, b1, c1, w9, 11);
    R52(d2, e2, a2, b2, c2, w4, 9);
    R51(c1, d1, e1, a1, b1, w7, 6);
    R52(c2, d2, e2, a2, b2, w1, 12);
    R51(b1, c1, d1, e1, a1, w12, 8);
    R52(b2, c2, d2, e2, a2, w5, 5);
    R51(a1, b1, c1, d1, e1, w2, 13);
    R52(a2, b2, c2, d2, e2, w8, 14);
    R51(e1, a1, b1, c1, d1, w10, 12);
    R52(e2, a2, b2, c2, d2, w7, 6);
    R51(d1, e1, a1, b1, c1, w14, 5);
    R52(d2, e2, a2, b2, c2, w6, 8);
    R51(c1, d1, e1, a1, b1, w1, 12);
    R52(c2, d2, e2, a2, b2, w2, 13);
    R51(b1, c1, d1, e1, a1, w3, 13);
    R52(b2, c2, d2, e2, a2, w13, 6);
    R51(a1, b1, c1, d1, e1, w8, 14);
    R52(a2, b2, c2, d2, e2, w14, 5);
    R51(e1, a1, b1, c1, d1, w11, 11);
    R52(e2, a2, b2, c2, d2, w0, 15);
    R51(d1, e1, a1, b1, c1, w6, 8);
    R52(d2, e2, a2, b2, c2, w3, 13);
    R51(c1, d1, e1, a1, b1, w15, 5);
    R52(c2, d2, e2, a2, b2, w9, 11);
    R51(b1, c1, d1, e1, a1, w13, 6);
    R52(b2, c2, d2, e2, a2, w11, 11);

#undef R11
#undef R21
#undef R31
#undef R41
#undef R51
#undef R12
#undef R22
#undef R32
#undef R42
#undef R52

    const std::uint32_t t = s[0];
    s[0] = s[1] + c1 + d2;
    s[1] = s[2] + d1 + e2;
    s[2] = s[3] + e1 + a2;
    s[3] = s[4] + a1 + b2;
    s[4] = t + b1 + c2;
}

}  // namespace

std::vector<std::uint8_t> ripemd160Digest(std::span<const std::uint8_t> data) {
    std::uint32_t state[5] = {0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0};
    std::uint64_t bytes = 0;
    std::vector<std::uint8_t> buffer;

    auto consume = [&](const std::uint8_t* chunkData) {
        transform(state, chunkData);
        bytes += 64;
    };

    std::size_t offset = 0;
    while (offset + 64 <= data.size()) {
        consume(data.data() + offset);
        offset += 64;
    }
    buffer.assign(data.begin() + static_cast<std::ptrdiff_t>(offset), data.end());
    bytes += buffer.size();

    buffer.push_back(0x80);
    while ((buffer.size() % 64) != 56) {
        buffer.push_back(0x00);
    }
    const std::uint64_t bitLen = bytes * 8;
    for (int i = 0; i < 8; ++i) {
        buffer.push_back(static_cast<std::uint8_t>((bitLen >> (8 * i)) & 0xff));
    }

    for (std::size_t pos = 0; pos < buffer.size(); pos += 64) {
        consume(buffer.data() + pos);
    }

    std::vector<std::uint8_t> out(20);
    writeLE32(out.data(), state[0]);
    writeLE32(out.data() + 4, state[1]);
    writeLE32(out.data() + 8, state[2]);
    writeLE32(out.data() + 12, state[3]);
    writeLE32(out.data() + 16, state[4]);
    return out;
}

}  // namespace cpbitnode::consensus
