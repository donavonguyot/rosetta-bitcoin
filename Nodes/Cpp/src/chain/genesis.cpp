#include "cpbitnode/chain/genesis.hpp"

#include <algorithm>
#include <cstring>
#include <iomanip>
#include <sstream>
#include <stdexcept>

namespace cpbitnode::chain {
namespace {

std::vector<std::uint8_t> fromHex(const std::string& hex) {
    if (hex.size() % 2 != 0) {
        throw std::runtime_error("invalid hex");
    }
    std::vector<std::uint8_t> out;
    out.reserve(hex.size() / 2);
    for (std::size_t i = 0; i < hex.size(); i += 2) {
        const auto byte = static_cast<std::uint8_t>(std::stoi(hex.substr(i, 2), nullptr, 16));
        out.push_back(byte);
    }
    return out;
}

std::vector<std::uint8_t> reverseBytes(std::vector<std::uint8_t> bytes) {
    std::reverse(bytes.begin(), bytes.end());
    return bytes;
}

}  // namespace

BlockHeader testnet4Genesis() {
    BlockHeader h;
    h.version = 1;
    h.prevBlock.assign(32, 0);
    h.merkleRoot = reverseBytes(fromHex("7aa0a7ae1e223414cb807e40cd57e667b718e42aaf9306db9102fe28912b7b4e"));
    h.timestamp = 1714777860;
    h.bits = 0x1D00FFFF;
    h.nonce = 393743547;
    return h;
}

BlockHeader regtestGenesis() {
    BlockHeader h;
    h.version = 1;
    h.prevBlock.assign(32, 0);
    h.merkleRoot = reverseBytes(fromHex("4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77a4cbf3bf478902f9c"));
    h.timestamp = 1296688602;
    h.bits = 0x207FFFFF;
    h.nonce = 2;
    return h;
}

BlockHeader genesisHeaderFor(const std::string& chainName) {
    if (chainName == "testnet4") {
        return testnet4Genesis();
    }
    if (chainName == "regtest") {
        return regtestGenesis();
    }
    throw std::runtime_error("No genesis header defined for chain " + chainName);
}

}  // namespace cpbitnode::chain
