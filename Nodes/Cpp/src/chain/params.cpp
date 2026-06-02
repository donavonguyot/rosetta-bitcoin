#include "cpbitnode/chain/params.hpp"

#include "cpbitnode/chain/genesis.hpp"

#include <cctype>
#include <map>
#include <stdexcept>

namespace cpbitnode::chain {
namespace {

ChainParams makeTestnet4() {
    ChainParams p;
    p.name = "testnet4";
    p.magic = {0x1c, 0x16, 0x3f, 0x28};
    p.defaultPort = 48333;
    p.genesisHash = blockHeaderHashHex(testnet4Genesis());
    p.dnsSeeds = {"seed.testnet4.bitcoin.sprovoost.nl", "seed.testnet4.wiz.biz"};
    p.protocolVersion = 70016;
    return p;
}

ChainParams makeRegtest() {
    ChainParams p;
    p.name = "regtest";
    p.magic = {0xfa, 0xbf, 0xb5, 0xda};
    p.defaultPort = 18444;
    p.genesisHash = blockHeaderHashHex(regtestGenesis());
    p.protocolVersion = 70016;
    return p;
}

}  // namespace

const ChainParams& testnet4() {
    static const ChainParams kParams = makeTestnet4();
    return kParams;
}

const ChainParams& regtest() {
    static const ChainParams kParams = makeRegtest();
    return kParams;
}

const ChainParams& getChain(const std::string& name) {
    static const std::map<std::string, ChainParams> kChains = {
        {"testnet4", makeTestnet4()},
        {"regtest", makeRegtest()},
    };
    std::string key = name;
    for (auto& c : key) {
        c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    }
    const auto it = kChains.find(key);
    if (it == kChains.end()) {
        throw std::runtime_error("Unknown chain " + name);
    }
    return it->second;
}

}  // namespace cpbitnode::chain
