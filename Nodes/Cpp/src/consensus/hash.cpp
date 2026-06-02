#include "cpbitnode/consensus/hash.hpp"

#include "cpbitnode/consensus/ripemd160.hpp"
#include "cpbitnode/consensus/sha256.hpp"

namespace cpbitnode::consensus {

std::vector<std::uint8_t> sha256Digest(std::span<const std::uint8_t> data) {
    return sha256(data);
}

std::vector<std::uint8_t> hash160(std::span<const std::uint8_t> data) {
    return ripemd160Digest(sha256(data));
}

}  // namespace cpbitnode::consensus
