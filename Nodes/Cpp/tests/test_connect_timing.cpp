#include "test_support.hpp"

#include "blocks_fixture.hpp"

#include "cpbitnode/chain/params.hpp"
#include "cpbitnode/consensus/connect.hpp"
#include "cpbitnode/db/codec_v2.hpp"
#include "cpbitnode/db/node_state.hpp"

#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <sstream>

void registerConnectTimingTests();

namespace {

std::string connectFixtureBlockWithTimingEnv(bool enabled) {
    const auto dir = std::filesystem::temp_directory_path() /
                     (enabled ? "cpbitnode_connect_timing_on" : "cpbitnode_connect_timing_off");
    std::filesystem::remove_all(dir);
    auto store = cpbitnode::db::openRocksDbNodeStateStore(dir.string());
    const auto& chain = cpbitnode::chain::testnet4();
    store->resetValidatedChain(chain.name, chain.genesisHash);

    if (enabled) {
        setenv("CPBITNODE_SYNC_TIMING", "1", 1);
    } else {
        unsetenv("CPBITNODE_SYNC_TIMING");
    }
    std::ostringstream captured;
    auto* old = std::cerr.rdbuf(captured.rdbuf());
    cpbitnode::consensus::ConnectBlockOptions options;
    options.height = 1;
    options.chainName = chain.name;
    options.expectedPrev = cpbitnode::db::codec_v2::displayHexToInternal(chain.genesisHash);
    cpbitnode::consensus::connectBlock(*store, cpbitnode::testfixtures::readFixtureBlock(0), options);
    std::cerr.rdbuf(old);
    unsetenv("CPBITNODE_SYNC_TIMING");
    std::filesystem::remove_all(dir);
    return captured.str();
}

void testConnectTimingOnlyWhenEnabled() {
    const auto disabled = connectFixtureBlockWithTimingEnv(false);
    EXPECT_TRUE(disabled.find("cpbitnode_sync_timing") == std::string::npos);

    const auto enabled = connectFixtureBlockWithTimingEnv(true);
    EXPECT_TRUE(enabled.find("cpbitnode_sync_timing") != std::string::npos);
    EXPECT_TRUE(enabled.find("utxo_load=") != std::string::npos);
    EXPECT_TRUE(enabled.find("script_verify=") != std::string::npos);
    EXPECT_TRUE(enabled.find("utxo_apply=") != std::string::npos);
    EXPECT_TRUE(enabled.find("commit=") != std::string::npos);
    EXPECT_TRUE(enabled.find("block_connect_store_commit=") != std::string::npos);
}

}  // namespace

void registerConnectTimingTests() {
    RUN_TEST(testConnectTimingOnlyWhenEnabled);
}
