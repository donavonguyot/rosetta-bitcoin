#pragma once

#include <array>
#include <cstdint>
#include <optional>
#include <span>
#include <stdexcept>
#include <utility>
#include <vector>

namespace cpbitnode::consensus {

class Secp256k1Error : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

struct Secp256k1Point {
    bool infinity = true;
    std::array<std::uint8_t, 32> x{};
    std::array<std::uint8_t, 32> y{};
};

Secp256k1Point secp256k1Generator();

bool verifyDerSignature(std::span<const std::uint8_t> pubkey, std::span<const std::uint8_t> messageHash,
                        std::span<const std::uint8_t> signature);
std::vector<std::uint8_t> signDer(std::uint64_t privateKey, std::span<const std::uint8_t> messageHash);

std::optional<Secp256k1Point> liftXOnlyPubkey(std::span<const std::uint8_t, 32> xCoord);
bool verifySchnorrSignature(std::span<const std::uint8_t, 32> pubkeyXonly,
                            std::span<const std::uint8_t> message,
                            std::span<const std::uint8_t, 64> signature);
std::vector<std::uint8_t> signBip340Schnorr(std::uint64_t secretKey, std::span<const std::uint8_t> message);

std::optional<Secp256k1Point> scalarMult(std::uint64_t scalar, const Secp256k1Point& point);
Secp256k1Point pointAdd(const Secp256k1Point& p1, const Secp256k1Point& p2);

std::pair<int, std::array<std::uint8_t, 32>> taprootTweakPubkeyXonly(
    std::span<const std::uint8_t, 32> internalXonly, std::span<const std::uint8_t> merkleRoot);

}  // namespace cpbitnode::consensus
