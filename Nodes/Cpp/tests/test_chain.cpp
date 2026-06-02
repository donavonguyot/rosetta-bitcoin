#include "test_support.hpp"

#include "cpbitnode/chain/genesis.hpp"
#include "cpbitnode/chain/params.hpp"

#include <stdexcept>

void registerChainTests();

namespace {

#define EXPECT_THROW(expr) \
    do { \
        bool threw = false; \
        try { \
            expr; \
        } catch (const std::exception&) { \
            threw = true; \
        } \
        if (!threw) { \
            std::cerr << "FAIL: " << __FILE__ << ":" << __LINE__ << " expected throw for " #expr "\n"; \
            ++g_failures; \
        } \
    } while (0)

void testTestnet4GenesisHash() {
    const auto& chain = cpbitnode::chain::testnet4();
    EXPECT_EQ(chain.genesisHash, "00000000da84f2bafbbc53dee25a72ae507ff4914b867c565be350b0da8bf043");
    EXPECT_EQ(chain.defaultPort, 48333u);
    EXPECT_EQ(chain.magic.size(), 4u);
}

void testRegtestParams() {
    const auto& chain = cpbitnode::chain::regtest();
    EXPECT_EQ(chain.defaultPort, 18444u);
    EXPECT_EQ(chain.genesisHash, "5b58ed692589ae1b707709a37ec6f67081cedc112b89ffe8c9a5432a34cbb4e8");
}

void testGenesisHeaderForKnownChains() {
    const auto t4 = cpbitnode::chain::genesisHeaderFor("testnet4");
    EXPECT_EQ(t4.nonce, 393743547u);
    const auto reg = cpbitnode::chain::genesisHeaderFor("regtest");
    EXPECT_EQ(reg.nonce, 2u);
}

void testGenesisHeaderForUnknownChain() {
    EXPECT_THROW(cpbitnode::chain::genesisHeaderFor("mainnet"));
}

void testGetChainResolvesKnownNames() {
    EXPECT_EQ(cpbitnode::chain::getChain("testnet4").name, "testnet4");
    EXPECT_EQ(cpbitnode::chain::getChain("TESTNET4").name, "testnet4");
    EXPECT_EQ(cpbitnode::chain::getChain("RegTest").name, "regtest");
}

void testGetChainRejectsUnknown() {
    EXPECT_THROW(cpbitnode::chain::getChain("signet"));
}

void testTestnet4DnsSeedsPopulated() {
    const auto& chain = cpbitnode::chain::testnet4();
    EXPECT_TRUE(!chain.dnsSeeds.empty());
}

}  // namespace

void registerChainTests() {
    RUN_TEST(testTestnet4GenesisHash);
    RUN_TEST(testRegtestParams);
    RUN_TEST(testGenesisHeaderForKnownChains);
    RUN_TEST(testGenesisHeaderForUnknownChain);
    RUN_TEST(testGetChainResolvesKnownNames);
    RUN_TEST(testGetChainRejectsUnknown);
    RUN_TEST(testTestnet4DnsSeedsPopulated);
}
