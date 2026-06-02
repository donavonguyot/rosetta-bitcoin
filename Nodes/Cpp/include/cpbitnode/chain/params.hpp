#pragma once

#include <cstdint>
#include <span>
#include <string>
#include <vector>

namespace cpbitnode::chain {

struct ChainParams {
    std::string name;
    std::vector<std::uint8_t> magic;
    std::uint16_t defaultPort = 0;
    std::string genesisHash;
    std::vector<std::string> dnsSeeds;
    std::int32_t protocolVersion = 70016;
};

const ChainParams& testnet4();
const ChainParams& regtest();
const ChainParams& getChain(const std::string& name);

}  // namespace cpbitnode::chain
