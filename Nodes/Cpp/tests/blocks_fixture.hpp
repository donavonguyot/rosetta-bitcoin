#pragma once

#include "cpbitnode/chain/params.hpp"
#include "cpbitnode/storage/blocks.hpp"

#include <array>
#include <cstddef>
#include <fstream>
#include <filesystem>
#include <stdexcept>
#include <string>
#include <vector>

namespace cpbitnode::testfixtures {

inline std::filesystem::path fixtureBlocksDir() {
    return std::filesystem::path(__FILE__).parent_path() / "fixtures" / "blocks";
}

inline constexpr std::array<const char*, 5> kTestnet4BlockHashes = {
    "0000000012982b6d5f621229286b880e909984df669c2afabb102ce311b13f28",
    "000000001fed1a914651afc36574003c5300cac5df738c3976f28d54f7096253",
    "000000008ddb4258595f9d8079a0b83fdc2816c9e3511acc739c16f5bce14e56",
    "000000008f5794caa45c418a0184303e848e9d6756e4d77234c9aada983b4265",
    "00000000ccefd2182ad4bb311c866233d32aae0a85f9568588ffd8e0432b7355",
};

inline constexpr std::array<std::size_t, 5> kTestnet4BlockOffsets = {0, 266, 532, 798, 1064};
inline constexpr std::size_t kTestnet4BlockPayloadSize = 258;

inline std::vector<std::uint8_t> readFixtureBlock(std::size_t offset, std::size_t size = kTestnet4BlockPayloadSize) {
    const auto& params = chain::testnet4();
    storage::BlockStore store(fixtureBlocksDir(), params.magic);
    return store.read("blk00000.dat", offset, size);
}

inline std::vector<std::uint8_t> readFixtureHex(const char* filename) {
    const auto path = std::filesystem::path(__FILE__).parent_path() / "fixtures" / filename;
    std::ifstream in(path);
    if (!in) {
        throw std::runtime_error("missing fixture: " + path.string());
    }
    std::string hex;
    in >> hex;
    std::vector<std::uint8_t> out;
    out.reserve(hex.size() / 2);
    for (std::size_t index = 0; index + 1 < hex.size(); index += 2) {
        out.push_back(static_cast<std::uint8_t>(std::stoi(hex.substr(index, 2), nullptr, 16)));
    }
    return out;
}

}  // namespace cpbitnode::testfixtures
