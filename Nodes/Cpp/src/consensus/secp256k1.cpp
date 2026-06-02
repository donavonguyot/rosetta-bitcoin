#include "cpbitnode/consensus/secp256k1.hpp"

#include "cpbitnode/consensus/hash.hpp"
#include "cpbitnode/consensus/script/sighash.hpp"

#include <algorithm>
#include <cstring>

#ifdef CPBITNODE_USE_NATIVE_SECP256K1
#include <secp256k1.h>
#include <secp256k1_extrakeys.h>
#include <secp256k1_schnorrsig.h>
#endif

namespace cpbitnode::consensus {
namespace {

struct U256;

const U256& secp256k1P();
const U256& secp256k1N();

struct U256 {
    std::uint64_t d[4]{};

    static U256 zero() { return {}; }

    static U256 fromBE(std::span<const std::uint8_t> bytes) {
        U256 r;
        const auto n = std::min(bytes.size(), std::size_t{32});
        for (std::size_t i = 0; i < n; ++i) {
            const auto limb = (31 - i) / 8;
            const auto shift = ((31 - i) % 8) * 8;
            r.d[limb] |= static_cast<std::uint64_t>(bytes[i]) << shift;
        }
        return r;
    }

    static U256 fromU64(std::uint64_t v) {
        U256 r;
        r.d[0] = v;
        return r;
    }

    std::array<std::uint8_t, 32> toBE() const {
        std::array<std::uint8_t, 32> out{};
        for (int i = 0; i < 32; ++i) {
            const auto limb = (31 - i) / 8;
            const auto shift = ((31 - i) % 8) * 8;
            out[static_cast<std::size_t>(i)] = static_cast<std::uint8_t>((d[limb] >> shift) & 0xff);
        }
        return out;
    }

    bool isZero() const { return d[0] == 0 && d[1] == 0 && d[2] == 0 && d[3] == 0; }

    int cmp(const U256& o) const {
        for (int i = 3; i >= 0; --i) {
            if (d[i] > o.d[i]) return 1;
            if (d[i] < o.d[i]) return -1;
        }
        return 0;
    }

    bool operator==(const U256& o) const { return cmp(o) == 0; }
    bool operator!=(const U256& o) const { return cmp(o) != 0; }
    bool operator<(const U256& o) const { return cmp(o) < 0; }
    bool operator>=(const U256& o) const { return cmp(o) >= 0; }

    static U256 addRaw(const U256& a, const U256& b, bool* carryOut = nullptr) {
        U256 r;
        unsigned __int128 c = 0;
        for (int i = 0; i < 4; ++i) {
            c += static_cast<unsigned __int128>(a.d[i]) + b.d[i];
            r.d[i] = static_cast<std::uint64_t>(c);
            c >>= 64;
        }
        if (carryOut) *carryOut = c != 0;
        return r;
    }

    static U256 subRaw(const U256& a, const U256& b, bool* borrowOut = nullptr) {
        U256 r;
        unsigned __int128 borrow = 0;
        for (int i = 0; i < 4; ++i) {
            const unsigned __int128 ai = a.d[i];
            const unsigned __int128 bi = b.d[i] + borrow;
            if (ai >= bi) {
                r.d[i] = static_cast<std::uint64_t>(ai - bi);
                borrow = 0;
            } else {
                r.d[i] = static_cast<std::uint64_t>(ai + (static_cast<unsigned __int128>(1) << 64) - bi);
                borrow = 1;
            }
        }
        if (borrowOut) *borrowOut = borrow != 0;
        return r;
    }

    U256 shr1() const {
        U256 r;
        for (int i = 0; i < 3; ++i) {
            r.d[i] = (d[i] >> 1) | (d[i + 1] << 63);
        }
        r.d[3] = d[3] >> 1;
        return r;
    }

    U256 modN() const {
        U256 r = *this;
        const U256& n = secp256k1N();
        while (r >= n) {
            r = subRaw(r, n, nullptr);
        }
        return r;
    }

    U256 addMod(const U256& b, const U256& mod) const {
        bool carry = false;
        auto r = addRaw(*this, b, &carry);
        if (carry || r >= mod) {
            r = subRaw(r, mod, nullptr);
        }
        return r;
    }

    U256 subMod(const U256& b, const U256& mod) const {
        if (*this >= b) {
            return subRaw(*this, b, nullptr);
        }
        return subRaw(mod, subRaw(b, *this, nullptr), nullptr);
    }

    static U256 mul512(const U256& a, const U256& b, U256& hiOut) {
        unsigned __int128 product[8]{};
        for (int i = 0; i < 4; ++i) {
            unsigned __int128 carry = 0;
            for (int j = 0; j < 4; ++j) {
                const unsigned __int128 t =
                    static_cast<unsigned __int128>(a.d[i]) * b.d[j] + product[i + j] + carry;
                product[i + j] = static_cast<std::uint64_t>(t);
                carry = t >> 64;
            }
            product[i + 4] += carry;
        }
        for (int k = 4; k < 7; ++k) {
            const unsigned __int128 carry = product[k] >> 64;
            product[k] = static_cast<std::uint64_t>(product[k]);
            product[k + 1] += carry;
        }
        U256 lo;
        hiOut = U256{};
        for (int i = 0; i < 4; ++i) {
            lo.d[i] = static_cast<std::uint64_t>(product[i]);
            hiOut.d[i] = static_cast<std::uint64_t>(product[i + 4]);
        }
        return lo;
    }

    static U256 reduceSecp256k1(const U256& lo, const U256& hi) {
        U256 mult{};
        mult.d[0] = (1ULL << 32) + 977ULL;
        U256 hiAcc = hi;
        U256 r = lo;
        for (int round = 0; round < 5 && !hiAcc.isZero(); ++round) {
            U256 hiPart;
            const U256 term = mul512(hiAcc, mult, hiPart);
            bool carry = false;
            r = addRaw(r, term, &carry);
            if (carry) {
                hiPart = addRaw(hiPart, U256::fromU64(1), nullptr);
            }
            hiAcc = hiPart;
        }
        const U256& p = secp256k1P();
        while (r >= p) {
            r = subRaw(r, p, nullptr);
        }
        return r;
    }

    U256 fieldMul(const U256& b) const {
        U256 hi;
        const U256 lo = mul512(*this, b, hi);
        return reduceSecp256k1(lo, hi);
    }

    U256 fieldModExp(U256 exp) const {
        U256 result = U256::fromU64(1);
        U256 base = reduceSecp256k1(*this, U256{});
        while (!exp.isZero()) {
            if (exp.d[0] & 1) {
                result = result.fieldMul(base);
            }
            base = base.fieldMul(base);
            exp = exp.shr1();
        }
        return result;
    }

    U256 mulMod(const U256& b, const U256& mod) const {
        if (mod.cmp(secp256k1P()) == 0) {
            return fieldMul(b);
        }
        U256 multiplicand = *this;
        U256 multiplier = b;
        while (multiplicand >= mod) {
            multiplicand = subRaw(multiplicand, mod, nullptr);
        }
        while (multiplier >= mod) {
            multiplier = subRaw(multiplier, mod, nullptr);
        }
        U256 result{};
        while (!multiplier.isZero()) {
            if (multiplier.d[0] & 1) {
                result = result.addMod(multiplicand, mod);
            }
            multiplicand = multiplicand.addMod(multiplicand, mod);
            multiplier = multiplier.shr1();
        }
        return result;
    }

    U256 modInv(const U256& mod) const {
        U256 base = *this;
        while (base >= mod) {
            base = subRaw(base, mod, nullptr);
        }
        if (base.isZero()) {
            return {};
        }
        U256 exp = subRaw(mod, U256::fromU64(2), nullptr);
        if (mod.cmp(secp256k1P()) == 0) {
            return base.fieldModExp(exp);
        }
        return base.modExp(exp, mod);
    }

    U256 modExp(U256 exp, const U256& mod) const {
        U256 result = U256::fromU64(1);
        U256 base = mod == secp256k1P() ? reduceSecp256k1(*this, U256{}) : *this;
        while (!exp.isZero()) {
            if (exp.d[0] & 1) {
                result = result.mulMod(base, mod);
            }
            base = base.mulMod(base, mod);
            exp = exp.shr1();
        }
        return result;
    }
};

const U256 kP = U256::fromBE(std::array<std::uint8_t, 32>{
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE, 0xFF, 0xFF, 0xFC, 0x2F});

const U256 kN = U256::fromBE(std::array<std::uint8_t, 32>{
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE,
    0xBA, 0xAE, 0xDC, 0xE6, 0xAF, 0x48, 0xA0, 0x3B, 0xBF, 0xD2, 0x5E, 0x8C, 0xD0, 0x36, 0x41, 0x41});

const U256& secp256k1P() { return kP; }
const U256& secp256k1N() { return kN; }

const U256 kGx = U256::fromBE(std::array<std::uint8_t, 32>{
    0x79, 0xBE, 0x66, 0x7E, 0xF9, 0xDC, 0xBB, 0xAC, 0x55, 0xA0, 0x62, 0x95, 0xCE, 0x87, 0x0B, 0x07,
    0x02, 0x9B, 0xFC, 0xDB, 0x2D, 0xCE, 0x28, 0xD9, 0x59, 0xF2, 0x81, 0x5B, 0x16, 0xF8, 0x17, 0x98});

const U256 kGy = U256::fromBE(std::array<std::uint8_t, 32>{
    0x48, 0x3A, 0xDA, 0x77, 0x26, 0xA3, 0xC4, 0x65, 0x5D, 0xA4, 0xFB, 0xFC, 0x0E, 0x11, 0x08, 0xA8,
    0xFD, 0x17, 0xB4, 0x48, 0xA6, 0x85, 0x54, 0x19, 0x9C, 0x47, 0xD0, 0x8F, 0xFB, 0x10, 0xD4, 0xB8});

const U256 kB = U256::fromU64(7);

U256 secp256k1SqrtExponent() {
    const U256 pPlusOne = U256::addRaw(kP, U256::fromU64(1), nullptr);
    return pPlusOne.shr1().shr1();
}

struct Point {
    bool inf = true;
    U256 x;
    U256 y;
};

Point toInternal(const Secp256k1Point& p) {
    if (p.infinity) return {};
    return {false, U256::fromBE(p.x), U256::fromBE(p.y)};
}

Secp256k1Point toExternal(const Point& p) {
    if (p.inf) return {};
    Secp256k1Point out;
    out.infinity = false;
    out.x = p.x.toBE();
    out.y = p.y.toBE();
    return out;
}

Point decompressPubkey(std::span<const std::uint8_t> data) {
    if (data.size() == 33 && (data[0] == 2 || data[0] == 3)) {
        const auto x = U256::fromBE(data.subspan(1));
        const auto y2 = x.fieldMul(x).fieldMul(x).addMod(kB, kP);
        const auto exp = secp256k1SqrtExponent();
        auto y = y2.fieldModExp(exp);
        const bool yEven = (y.d[0] & 1) == 0;
        const bool wantEven = data[0] == 2;
        if (yEven != wantEven) {
            y = kP.subMod(y, kP);
        }
        return {false, x, y};
    }
    if (data.size() == 65 && data[0] == 4) {
        return {false, U256::fromBE(data.subspan(1, 32)), U256::fromBE(data.subspan(33, 32))};
    }
    throw Secp256k1Error("invalid public key encoding");
}

Point pointAddInternal(const Point& p1, const Point& p2) {
    if (p1.inf) return p2;
    if (p2.inf) return p1;
    if (p1.x == p2.x) {
        if (p1.y.addMod(p2.y, kP).isZero()) {
            return {};
        }
        const auto x2 = p1.x.fieldMul(p1.x);
        const auto num = U256::fromU64(3).fieldMul(x2);
        const auto den = U256::fromU64(2).fieldMul(p1.y);
        const auto m = num.fieldMul(den.modInv(kP));
        const auto x3 = m.fieldMul(m).subMod(p1.x, kP).subMod(p2.x, kP);
        const auto y3 = m.fieldMul(p1.x.subMod(x3, kP)).subMod(p1.y, kP);
        return {false, x3, y3};
    }
    const auto m = p2.y.subMod(p1.y, kP).fieldMul(p2.x.subMod(p1.x, kP).modInv(kP));
    const auto x3 = m.fieldMul(m).subMod(p1.x, kP).subMod(p2.x, kP);
    const auto y3 = m.fieldMul(p1.x.subMod(x3, kP)).subMod(p1.y, kP);
    return {false, x3, y3};
}

Point scalarMultInternal(U256 k, const Point& point) {
    Point result;
    Point addend = point;
    while (!k.isZero()) {
        if (k.d[0] & 1) {
            result = pointAddInternal(result, addend);
        }
        addend = pointAddInternal(addend, addend);
        k = k.shr1();
    }
    return result;
}

std::pair<U256, U256> parseDerSignature(std::span<const std::uint8_t> data) {
    if (data.size() < 8 || data[0] != 0x30) {
        throw Secp256k1Error("invalid DER signature");
    }
    if (static_cast<std::size_t>(data[1]) + 2 != data.size()) {
        throw Secp256k1Error("invalid DER signature length");
    }
    if (data[2] != 0x02) {
        throw Secp256k1Error("invalid DER signature r marker");
    }
    const auto rLen = data[3];
    const auto r = U256::fromBE(data.subspan(4, rLen));
    const std::size_t offset = 4 + rLen;
    if (data[offset] != 0x02) {
        throw Secp256k1Error("invalid DER signature s marker");
    }
    const auto sLen = data[offset + 1];
    const auto s = U256::fromBE(data.subspan(offset + 2, sLen));
    if (r.isZero() || s.isZero() || r >= kN || s >= kN) {
        throw Secp256k1Error("signature r/s out of range");
    }
    return {r, s};
}

bool hasEvenY(const Point& p) { return (p.y.d[0] & 1) == 0; }

U256 modNFromField(const U256& x) {
    U256 r = x;
    while (r >= kN) {
        r = U256::subRaw(r, kN, nullptr);
    }
    return r;
}

std::vector<std::uint8_t> derEncode(U256 r, U256 s) {
    auto strip = [](const U256& v) {
        auto bytes = v.toBE();
        std::size_t start = 0;
        while (start + 1 < bytes.size() && bytes[start] == 0) {
            ++start;
        }
        return std::vector<std::uint8_t>(bytes.begin() + static_cast<std::ptrdiff_t>(start), bytes.end());
    };
    const auto rBytes = strip(r);
    const auto sBytes = strip(s);
    std::vector<std::uint8_t> out;
    out.push_back(0x30);
    out.push_back(static_cast<std::uint8_t>(4 + rBytes.size() + sBytes.size()));
    out.push_back(0x02);
    out.push_back(static_cast<std::uint8_t>(rBytes.size()));
    out.insert(out.end(), rBytes.begin(), rBytes.end());
    out.push_back(0x02);
    out.push_back(static_cast<std::uint8_t>(sBytes.size()));
    out.insert(out.end(), sBytes.begin(), sBytes.end());
    return out;
}

U256 halfN() {
    U256 n = kN;
    return n.shr1();
}

#ifdef CPBITNODE_USE_NATIVE_SECP256K1
secp256k1_context* nativeContext() {
    static secp256k1_context* ctx = secp256k1_context_create(SECP256K1_CONTEXT_VERIFY);
    return ctx;
}
#endif

}  // namespace

Secp256k1Point secp256k1Generator() { return toExternal({false, kGx, kGy}); }

bool verifyDerSignature(std::span<const std::uint8_t> pubkey, std::span<const std::uint8_t> messageHash,
                        std::span<const std::uint8_t> signature) {
    if (messageHash.size() != 32) {
        throw Secp256k1Error("message hash must be 32 bytes");
    }
#ifdef CPBITNODE_USE_NATIVE_SECP256K1
    if (pubkey.empty() || signature.empty()) {
        return false;
    }
    secp256k1_pubkey parsedPubkey;
    secp256k1_ecdsa_signature parsedSignature;
    if (secp256k1_ec_pubkey_parse(nativeContext(), &parsedPubkey, pubkey.data(), pubkey.size()) != 1) {
        return false;
    }
    if (secp256k1_ecdsa_signature_parse_der(nativeContext(), &parsedSignature, signature.data(), signature.size()) != 1) {
        return false;
    }
    return secp256k1_ecdsa_verify(nativeContext(), &parsedSignature, messageHash.data(), &parsedPubkey) == 1;
#else
    try {
        const auto [r, s] = parseDerSignature(signature);
        const auto q = decompressPubkey(pubkey);
        const auto z = modNFromField(U256::fromBE(messageHash));
        const auto w = s.modInv(kN);
        const auto u1 = z.mulMod(w, kN);
        const auto u2 = r.mulMod(w, kN);
        const auto g = Point{false, kGx, kGy};
        const auto pt = pointAddInternal(scalarMultInternal(u1, g), scalarMultInternal(u2, q));
        if (pt.inf) return false;
        return modNFromField(pt.x) == r;
    } catch (const Secp256k1Error&) {
        return false;
    }
#endif
}

std::vector<std::uint8_t> signDer(std::uint64_t privateKey, std::span<const std::uint8_t> messageHash) {
    auto pk = U256::fromU64(privateKey);
    if (pk.isZero() || pk >= kN) {
        throw Secp256k1Error("invalid private key");
    }
    if (messageHash.size() != 32) {
        throw Secp256k1Error("message hash must be 32 bytes");
    }
    const auto z = U256::fromBE(messageHash);
    const auto g = Point{false, kGx, kGy};
    for (std::uint64_t nonce = 1; nonce < 1000; ++nonce) {
        const auto k = U256::fromU64(nonce);
        const auto pt = scalarMultInternal(k, g);
        if (pt.inf) continue;
        auto r = modNFromField(pt.x);
        if (r.isZero()) continue;
        auto s = k.modInv(kN).mulMod(z.addMod(r.mulMod(pk, kN), kN), kN);
        if (s.isZero()) continue;
        if (s.cmp(halfN()) > 0) {
            s = kN.subMod(s, kN);
        }
        return derEncode(r, s);
    }
    throw Secp256k1Error("failed to sign message");
}

std::optional<Secp256k1Point> liftXOnlyPubkey(std::span<const std::uint8_t, 32> xCoord) {
    const auto x = U256::fromBE(xCoord);
    if (x >= kP) return std::nullopt;
    const auto y2 = x.fieldMul(x).fieldMul(x).addMod(kB, kP);
    auto y = y2.fieldModExp(secp256k1SqrtExponent());
    if (y.fieldMul(y) != y2) return std::nullopt;
    if ((y.d[0] & 1) != 0) {
        y = kP.subMod(y, kP);
    }
    return toExternal({false, x, y});
}

bool verifySchnorrSignature(std::span<const std::uint8_t, 32> pubkeyXonly,
                            std::span<const std::uint8_t> message,
                            std::span<const std::uint8_t, 64> signature) {
#ifdef CPBITNODE_USE_NATIVE_SECP256K1
    secp256k1_xonly_pubkey pubkey;
    if (message.size() != 32 || signature.empty()) {
        return false;
    }
    if (secp256k1_xonly_pubkey_parse(nativeContext(), &pubkey, pubkeyXonly.data()) != 1) {
        return false;
    }
    return secp256k1_schnorrsig_verify(nativeContext(), signature.data(), message.data(), message.size(), &pubkey) == 1;
#else
    try {
        const auto pubkeyPoint = liftXOnlyPubkey(pubkeyXonly);
        if (!pubkeyPoint) return false;
        const auto p = toInternal(*pubkeyPoint);
        const auto rx = U256::fromBE(signature.subspan(0, 32));
        const auto s = U256::fromBE(signature.subspan(32, 32));
        if (rx >= kP || s >= kN) return false;

        std::vector<std::uint8_t> challengeMsg;
        challengeMsg.insert(challengeMsg.end(), signature.begin(), signature.begin() + 32);
        challengeMsg.insert(challengeMsg.end(), pubkeyXonly.begin(), pubkeyXonly.end());
        challengeMsg.insert(challengeMsg.end(), message.begin(), message.end());
        auto e = U256::fromBE(script::bitcoinTaggedHash("BIP0340/challenge", challengeMsg));
        e = modNFromField(e);

        const auto g = Point{false, kGx, kGy};
        const auto lhs = scalarMultInternal(s, g);
        const auto rhsAdj = scalarMultInternal(kN.subMod(e, kN), p);
        const auto rPt = pointAddInternal(lhs, rhsAdj);
        if (rPt.inf) return false;
        return hasEvenY(rPt) && rPt.x == rx;
    } catch (...) {
        return false;
    }
#endif
}

std::vector<std::uint8_t> signBip340Schnorr(std::uint64_t secretKey, std::span<const std::uint8_t> message) {
    auto d0 = U256::fromU64(secretKey);
    d0 = modNFromField(d0);
    if (d0.isZero()) {
        throw Secp256k1Error("invalid secret key");
    }
    const auto g = Point{false, kGx, kGy};
    auto pPoint = scalarMultInternal(d0, g);
    if (pPoint.inf) {
        throw Secp256k1Error("invalid public point");
    }
    auto d = d0;
    if (!hasEvenY(pPoint)) {
        d = kN.subMod(d0, kN);
        pPoint = scalarMultInternal(d, g);
        if (pPoint.inf) {
            throw Secp256k1Error("invalid public point");
        }
    }
    const auto pkXbytes = pPoint.x.toBE();

    std::vector<std::uint8_t> auxSeed;
    auxSeed.insert(auxSeed.end(), {'p', 'b', 'n', '(', 'a', 'u', 'x', ')'});
    const auto dBytes = d.toBE();
    auxSeed.insert(auxSeed.end(), dBytes.begin(), dBytes.end());
    auxSeed.insert(auxSeed.end(), message.begin(), message.end());
    const auto auxRand = sha256Digest(auxSeed);
    const auto auxHash = script::bitcoinTaggedHash("BIP0340/aux", auxRand);
    std::vector<std::uint8_t> tBytes(32);
    for (int i = 0; i < 32; ++i) {
        tBytes[static_cast<std::size_t>(i)] = dBytes[static_cast<std::size_t>(i)] ^ auxHash[i];
    }

    std::vector<std::uint8_t> nonceMsg;
    nonceMsg.insert(nonceMsg.end(), tBytes.begin(), tBytes.end());
    nonceMsg.insert(nonceMsg.end(), pkXbytes.begin(), pkXbytes.end());
    nonceMsg.insert(nonceMsg.end(), message.begin(), message.end());
    auto k0 = modNFromField(U256::fromBE(script::bitcoinTaggedHash("BIP0340/nonce", nonceMsg)));
    if (k0.isZero()) {
        throw Secp256k1Error("signing failure (retry)");
    }
    auto rPoint = scalarMultInternal(k0, g);
    if (rPoint.inf) {
        throw Secp256k1Error("signing failure (retry)");
    }
    auto k = k0;
    if (!hasEvenY(rPoint)) {
        k = kN.subMod(k0, kN);
    }

    const auto rXbytes = rPoint.x.toBE();
    std::vector<std::uint8_t> challengeMsg;
    challengeMsg.insert(challengeMsg.end(), rXbytes.begin(), rXbytes.end());
    challengeMsg.insert(challengeMsg.end(), pkXbytes.begin(), pkXbytes.end());
    challengeMsg.insert(challengeMsg.end(), message.begin(), message.end());
    auto e = modNFromField(U256::fromBE(script::bitcoinTaggedHash("BIP0340/challenge", challengeMsg)));

    const auto sigS = k.addMod(e.mulMod(d, kN), kN);
    std::vector<std::uint8_t> sig(64);
    std::memcpy(sig.data(), rXbytes.data(), 32);
    const auto sBytes = sigS.toBE();
    std::memcpy(sig.data() + 32, sBytes.data(), 32);

    if (!verifySchnorrSignature(pkXbytes, message, std::span<const std::uint8_t, 64>(sig.data(), 64))) {
        throw Secp256k1Error("internal Schnorr signing failed sanity check");
    }
    return sig;
}

std::optional<Secp256k1Point> scalarMult(std::uint64_t scalar, const Secp256k1Point& point) {
    const auto p = toInternal(point);
    if (p.inf) return std::nullopt;
    const auto result = scalarMultInternal(U256::fromU64(scalar), p);
    if (result.inf) return std::nullopt;
    return toExternal(result);
}

Secp256k1Point pointAdd(const Secp256k1Point& p1, const Secp256k1Point& p2) {
    return toExternal(pointAddInternal(toInternal(p1), toInternal(p2)));
}

std::pair<int, std::array<std::uint8_t, 32>> taprootTweakPubkeyXonly(
    std::span<const std::uint8_t, 32> internalXonly, std::span<const std::uint8_t> merkleRoot) {
#ifdef CPBITNODE_USE_NATIVE_SECP256K1
    const auto tweak = script::taprootTweakPubkeyHash(internalXonly, merkleRoot);
    secp256k1_xonly_pubkey internal;
    secp256k1_pubkey output;
    if (secp256k1_xonly_pubkey_parse(nativeContext(), &internal, internalXonly.data()) != 1) {
        throw Secp256k1Error("invalid internal x-only key");
    }
    if (secp256k1_xonly_pubkey_tweak_add(nativeContext(), &output, &internal, tweak.data()) != 1) {
        throw Secp256k1Error("taproot tweak failed");
    }
    secp256k1_xonly_pubkey outputXonly;
    int parity = 0;
    secp256k1_xonly_pubkey_from_pubkey(nativeContext(), &outputXonly, &parity, &output);
    std::array<std::uint8_t, 32> serialized{};
    secp256k1_xonly_pubkey_serialize(nativeContext(), serialized.data(), &outputXonly);
    return {parity, serialized};
#else
    const auto tweak = script::taprootTweakPubkeyHash(internalXonly, merkleRoot);
    auto t = U256::fromBE(tweak);
    if (t >= kN) {
        throw Secp256k1Error("TapTweak out of range");
    }
    const auto pOpt = liftXOnlyPubkey(internalXonly);
    if (!pOpt) {
        throw Secp256k1Error("invalid internal x-only key");
    }
    const auto p = toInternal(*pOpt);
    const auto g = Point{false, kGx, kGy};
    const auto q = pointAddInternal(p, scalarMultInternal(t, g));
    if (q.inf) {
        throw Secp256k1Error("taproot tweak failed");
    }
    const int parity = hasEvenY(q) ? 0 : 1;
    return {parity, q.x.toBE()};
#endif
}

}  // namespace cpbitnode::consensus
