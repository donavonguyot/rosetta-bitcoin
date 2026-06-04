#include "cpbitnode/sync/validate.hpp"

#include "cpbitnode/consensus/merkle.hpp"
#include "cpbitnode/messages/transaction.hpp"

#include <algorithm>
#include <array>
#include <sstream>

namespace cpbitnode::sync {
namespace {

bool leUInt256LessOrEqual(std::span<const std::uint8_t> hash, std::span<const std::uint8_t> target) {
    if (hash.size() != 32 || target.size() != 32) {
        return false;
    }
    for (int index = 31; index >= 0; --index) {
        if (hash[static_cast<std::size_t>(index)] < target[static_cast<std::size_t>(index)]) {
            return true;
        }
        if (hash[static_cast<std::size_t>(index)] > target[static_cast<std::size_t>(index)]) {
            return false;
        }
    }
    return true;
}

std::string displayHex(std::span<const std::uint8_t> bytes) {
    static const char* kHex = "0123456789abcdef";
    std::string out;
    out.reserve(bytes.size() * 2);
    for (auto it = bytes.rbegin(); it != bytes.rend(); ++it) {
        out.push_back(kHex[(*it >> 4) & 0xf]);
        out.push_back(kHex[*it & 0xf]);
    }
    return out;
}

}  // namespace

std::array<std::uint8_t, 32> compactToTargetLE(std::uint32_t bits) {
    const int exponent = static_cast<int>(bits >> 24);
    const int mantissa = static_cast<int>(bits & 0x007fffff);
    if (mantissa == 0) {
        std::ostringstream oss;
        oss << "Invalid compact bits: 0x" << std::hex << bits;
        throw HeaderValidationError(oss.str());
    }

    std::array<std::uint8_t, 32> target{};
    if (exponent <= 3) {
        const int shift = 8 * (3 - exponent);
        std::uint64_t value = static_cast<std::uint64_t>(mantissa) >> shift;
        for (int index = 0; index < 8 && value > 0; ++index) {
            target[static_cast<std::size_t>(index)] = static_cast<std::uint8_t>(value & 0xff);
            value >>= 8;
        }
        return target;
    }

    const int offset = exponent - 3;
    if (offset >= 32) {
        target.fill(0xff);
        return target;
    }
    target[static_cast<std::size_t>(offset)] = static_cast<std::uint8_t>(mantissa & 0xff);
    if (offset + 1 < 32) {
        target[static_cast<std::size_t>(offset + 1)] = static_cast<std::uint8_t>((mantissa >> 8) & 0xff);
    }
    if (offset + 2 < 32) {
        target[static_cast<std::size_t>(offset + 2)] = static_cast<std::uint8_t>((mantissa >> 16) & 0xff);
    }
    return target;
}

bool headerMeetsTarget(const messages::BlockHeader& header) {
    const auto target = compactToTargetLE(header.bits);
    const auto hash = header.blockHash();
    return leUInt256LessOrEqual(hash, target);
}

void validateHeader(const messages::BlockHeader& header, std::span<const std::uint8_t> expectedPrev) {
    if (expectedPrev.size() != 32) {
        throw HeaderValidationError("expected_prev must be 32 bytes");
    }
    if (header.prevBlock.size() != 32 ||
        !std::equal(header.prevBlock.begin(), header.prevBlock.end(), expectedPrev.begin(), expectedPrev.end())) {
        throw HeaderValidationError("prev_block mismatch: expected " + displayHex(expectedPrev) + ", got " +
                                    displayHex(header.prevBlock));
    }
    if (!headerMeetsTarget(header)) {
        std::ostringstream oss;
        oss << "proof of work failed for bits 0x" << std::hex << header.bits;
        throw HeaderValidationError(oss.str());
    }
}

void validateDecodedBlock(const consensus::Block& block, std::span<const std::uint8_t> expectedPrev,
                          const std::vector<std::uint8_t>* expectedHash) {
    try {
        validateHeader(block.header, expectedPrev);
    } catch (const HeaderValidationError& exc) {
        throw BlockValidationError(exc.what());
    }

    if (expectedHash != nullptr) {
        const auto actualHash = block.header.blockHash();
        if (actualHash != *expectedHash) {
            throw BlockValidationError("block hash mismatch: expected " + displayHex(*expectedHash) + ", got " +
                                       block.header.blockHashHex());
        }
    }

    if (block.transactions.empty()) {
        throw BlockValidationError("block has no transactions");
    }
    if (!messages::transactionIsCoinbase(block.transactions.front())) {
        throw BlockValidationError("first transaction must be coinbase");
    }

    const auto merkleRoot = consensus::blockMerkleRoot(block.transactions);
    if (merkleRoot != block.header.merkleRoot) {
        throw BlockValidationError("merkle root mismatch: expected " + displayHex(block.header.merkleRoot) +
                                   ", computed " + displayHex(merkleRoot));
    }
}

consensus::Block validateBlock(std::span<const std::uint8_t> payload, std::span<const std::uint8_t> expectedPrev,
                               const std::vector<std::uint8_t>* expectedHash) {
    if (payload.size() < kMinBlockPayloadBytes) {
        throw BlockValidationError("block payload too small: " + std::to_string(payload.size()) + " bytes");
    }
    if (payload.size() > kMaxBlockPayloadBytes) {
        throw BlockValidationError("block payload too large: " + std::to_string(payload.size()) + " bytes");
    }

    consensus::Block block;
    try {
        block = consensus::Block::deserialize(payload);
    } catch (const std::exception& exc) {
        throw BlockValidationError(exc.what());
    }

    validateDecodedBlock(block, expectedPrev, expectedHash);

    return block;
}

}  // namespace cpbitnode::sync
