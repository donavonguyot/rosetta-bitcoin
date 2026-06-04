#include "test_support.hpp"

#include "cpbitnode/chain/params.hpp"
#include "cpbitnode/db/node_state.hpp"
#include "cpbitnode/storage/blocks.hpp"
#include "cpbitnode/sync/blocks.hpp"

#include <filesystem>
#include <string>

void registerSyncHotPathTests();

namespace {

std::filesystem::path tempSyncDir(const std::string& name) {
    const auto dir = std::filesystem::temp_directory_path() / name;
    std::filesystem::remove_all(dir);
    std::filesystem::create_directories(dir);
    return dir;
}

void seedHeaderHeights(cpbitnode::db::NodeStateStore& store) {
    const std::string headerHex(160, '0');
    store.recordHeaders({
        cpbitnode::db::HeaderRecord{1, std::string(64, '1'), std::string(64, '0'), 1, headerHex},
        cpbitnode::db::HeaderRecord{2, std::string(64, '2'), std::string(64, '1'), 2, headerHex},
    });
}

void testBoundedTargetDoesNotMarkBlocksCurrent() {
    const auto dir = tempSyncDir("cpbitnode_sync_hot_path_bounded");
    auto store = cpbitnode::db::openRocksDbNodeStateStore(dir.string());
    const auto& chain = cpbitnode::chain::testnet4();
    seedHeaderHeights(*store);
    store->setValidatedTip(1, std::string(64, '1'), chain.name);
    cpbitnode::storage::BlockStore blockStore(dir / "blocks", chain.magic);

    const int downloaded = cpbitnode::sync::syncBlocksBatch({nullptr}, *store, chain, blockStore, 10, 10, 0, 1);
    EXPECT_EQ(downloaded, 0);
    const auto state = store->getSyncState(chain.name);
    EXPECT_TRUE(!state.has_value() || state->at("sync_status") != "blocks_current");

    std::filesystem::remove_all(dir);
}

void testUnboundedCaughtUpMarksBlocksCurrent() {
    const auto dir = tempSyncDir("cpbitnode_sync_hot_path_current");
    auto store = cpbitnode::db::openRocksDbNodeStateStore(dir.string());
    const auto& chain = cpbitnode::chain::testnet4();
    seedHeaderHeights(*store);
    store->setValidatedTip(2, std::string(64, '2'), chain.name);
    cpbitnode::storage::BlockStore blockStore(dir / "blocks", chain.magic);

    const int downloaded = cpbitnode::sync::syncBlocksBatch({nullptr}, *store, chain, blockStore, 10, 10, 0, 0);
    EXPECT_EQ(downloaded, 0);
    const auto state = store->getSyncState(chain.name);
    EXPECT_TRUE(state.has_value());
    EXPECT_EQ(state->at("sync_status"), "blocks_current");

    std::filesystem::remove_all(dir);
}

}  // namespace

void registerSyncHotPathTests() {
    RUN_TEST(testBoundedTargetDoesNotMarkBlocksCurrent);
    RUN_TEST(testUnboundedCaughtUpMarksBlocksCurrent);
}
