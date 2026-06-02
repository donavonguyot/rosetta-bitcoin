#include "cpbitnode/consensus/coinbase.hpp"

#include <sstream>

namespace cpbitnode::consensus {

std::optional<std::int64_t> decodeBip34Height(std::span<const std::uint8_t> scriptSig) {
    if (scriptSig.empty()) {
        return std::nullopt;
    }
    const auto opcode = scriptSig[0];
    if (opcode == 0) {
        return 0;
    }
    if (opcode >= 0x51 && opcode <= 0x60) {
        return static_cast<std::int64_t>(opcode - 0x50);
    }
    if (opcode >= 1 && opcode <= 75) {
        if (scriptSig.size() < static_cast<std::size_t>(1 + opcode)) {
            return std::nullopt;
        }
        const auto data = scriptSig.subspan(1, static_cast<std::size_t>(opcode));
        if (data.empty()) {
            return std::nullopt;
        }
        std::int64_t result = 0;
        for (std::size_t i = 0; i < data.size(); ++i) {
            result += static_cast<std::int64_t>(data[i]) << (8 * i);
        }
        return result;
    }
    return std::nullopt;
}

void validateBip34Height(const messages::Transaction& coinbase, std::int32_t height) {
    if (height == 0) {
        return;
    }
    if (coinbase.inputs.empty()) {
        throw CoinbaseError("coinbase has no inputs");
    }
    const auto encoded = decodeBip34Height(coinbase.inputs[0].scriptSig);
    if (!encoded.has_value() || *encoded != height) {
        std::ostringstream oss;
        oss << "BIP34 height mismatch: expected " << height << ", got ";
        if (encoded.has_value()) {
            oss << *encoded;
        } else {
            oss << "null";
        }
        oss << " in coinbase scriptSig";
        throw CoinbaseError(oss.str());
    }
}

bool isOpReturn(std::span<const std::uint8_t> scriptPubKey) {
    return !scriptPubKey.empty() && scriptPubKey[0] == 0x6A;
}

bool isSpendableOutput(std::span<const std::uint8_t> scriptPubKey) {
    return !scriptPubKey.empty() && !isOpReturn(scriptPubKey);
}

}  // namespace cpbitnode::consensus
