#include "test_support.hpp"

#include "cpbitnode/db/node_state.hpp"

#include <cstdint>
#include <filesystem>
#include <iomanip>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

#include <rocksdb/db.h>
#include <rocksdb/options.h>
#include <rocksdb/version.h>

void registerNativeStoreTests();

namespace {

std::vector<std::uint8_t> txid(std::uint8_t value) {
    return std::vector<std::uint8_t>(32, value);
}

std::filesystem::path tempStoreDir(const std::string& name) {
    const auto dir = std::filesystem::temp_directory_path() / name;
    std::filesystem::remove_all(dir);
    std::filesystem::create_directories(dir);
    return dir;
}

void testRocksDbStoreMultiGetAndHeightIndex() {
    const auto dir = tempStoreDir("cpbitnode_native_store_multiget");
    auto store = cpbitnode::db::openRocksDbNodeStateStore(dir.string());
    const auto a = txid(0x11);
    const auto b = txid(0x12);
    const auto missing = txid(0x22);

    store->addUtxo(a, 0, 7, 50, {0x51}, false);
    store->addUtxo(b, 2, 7, 75, {0x52}, true);
    EXPECT_EQ(store->utxoCount(), 2);

    const auto loaded = store->getUtxos({{a, 0}, {missing, 0}, {b, 2}, {a, 0}});
    EXPECT_EQ(static_cast<int>(loaded.size()), 4);
    EXPECT_TRUE(loaded[0].has_value());
    EXPECT_TRUE(!loaded[1].has_value());
    EXPECT_TRUE(loaded[2].has_value());
    EXPECT_TRUE(loaded[3].has_value());
    EXPECT_BYTES_EQ(loaded[0]->txid, a);
    EXPECT_BYTES_EQ(loaded[2]->txid, b);
    EXPECT_BYTES_EQ(loaded[3]->txid, a);

    store->deleteUtxosCreatedAtHeight(6);
    EXPECT_EQ(store->utxoCount(), 2);
    store->deleteUtxosCreatedAtHeight(7);
    EXPECT_EQ(store->utxoCount(), 0);
    EXPECT_TRUE(!store->getUtxo(a, 0).has_value());
    EXPECT_TRUE(!store->getUtxo(b, 2).has_value());

    std::filesystem::remove_all(dir);
}

void testRocksDbStoreBatchedHeaders() {
    const auto dir = tempStoreDir("cpbitnode_native_store_headers");
    auto store = cpbitnode::db::openRocksDbNodeStateStore(dir.string());
    const std::string headerHexA(160, '0');
    const std::string headerHexB = std::string(158, '0') + "01";

    store->recordHeaders({
        cpbitnode::db::HeaderRecord{1, std::string(64, '1'), std::string(64, '0'), 1, headerHexA},
        cpbitnode::db::HeaderRecord{2, std::string(64, '2'), std::string(64, '1'), 2, headerHexB},
    });
    EXPECT_EQ(store->headerCount(), 3);
    EXPECT_TRUE(store->getHeaderSerializedHex(1).has_value());
    EXPECT_TRUE(store->getHeaderSerializedHex(2).has_value());

    store->recordHeader(3, std::string(64, '3'), std::string(64, '2'), 3, headerHexA);
    EXPECT_EQ(store->headerCount(), 4);
    EXPECT_TRUE(store->getHeaderSerializedHex(3).has_value());

    std::filesystem::remove_all(dir);
}

void testRocksDbStoreCommitBlockUpdatesTipIndexUndoAndCounters() {
    const auto dir = tempStoreDir("cpbitnode_native_store_commit");
    auto store = cpbitnode::db::openRocksDbNodeStateStore(dir.string());
    const auto spent = txid(0x33);
    const auto createdA = txid(0x44);
    const auto createdB = txid(0x55);
    const std::string hash(64, 'a');

    store->addUtxo(spent, 1, 3, 100, {0x53}, false);
    cpbitnode::db::BlockCommit commit;
    commit.chain = "testnet4";
    commit.height = 4;
    commit.blockHash = hash;
    commit.spends = {{spent, 1}};
    commit.creates = {
        {createdA, 0, 4, 75, {0x51}, false},
        {createdB, 2, 4, 25, {0x52}, true},
    };
    commit.undo = {{spent, 1, 3, 100, {0x53}, false}};
    commit.blockIndex = cpbitnode::db::StoredBlockRow{4, hash, "blk00000.dat", 8, 80};

    store->commitBlock(commit);

    EXPECT_EQ(store->getValidatedHeight("testnet4"), 4);
    EXPECT_EQ(store->getValidatedHash("testnet4"), hash);
    EXPECT_EQ(store->utxoCount(), 2);
    EXPECT_EQ(store->getMeta("metric_blocks_validated_total").value_or(""), "1");
    EXPECT_TRUE(!store->getUtxo(spent, 1).has_value());
    EXPECT_TRUE(store->getUtxo(createdA, 0).has_value());
    EXPECT_TRUE(store->getUtxo(createdB, 2).has_value());
    const auto row = store->getBlock(4);
    EXPECT_TRUE(row.has_value());
    EXPECT_EQ(row->blockHash, hash);

    const auto undo = store->takeUtxoUndo("testnet4", 4);
    EXPECT_EQ(static_cast<int>(undo.size()), 1);
    EXPECT_BYTES_EQ(undo.front().txid, spent);

    bool threw = false;
    try {
        cpbitnode::db::BlockCommit bad = commit;
        bad.height = 5;
        bad.blockHash = std::string(64, 'b');
        bad.spends = {{{0x01}, 0}};
        store->commitBlock(bad);
    } catch (const std::invalid_argument&) {
        threw = true;
    }
    EXPECT_TRUE(threw);
    EXPECT_EQ(store->getValidatedHeight("testnet4"), 4);
    EXPECT_EQ(store->getValidatedHash("testnet4"), hash);
    EXPECT_EQ(store->utxoCount(), 2);
    EXPECT_EQ(store->getMeta("metric_blocks_validated_total").value_or(""), "1");

    store->deleteUtxosCreatedAtHeight(4);
    EXPECT_EQ(store->utxoCount(), 0);
    EXPECT_TRUE(!store->getUtxo(createdA, 0).has_value());
    EXPECT_TRUE(!store->getUtxo(createdB, 2).has_value());

    std::filesystem::remove_all(dir);
}

void testRocksDbStoreRejectsLegacyGeneration() {
    const auto dir = tempStoreDir("cpbitnode_native_store_legacy_reject");
    const auto dbDir = dir / "chainstate-rocksdb";
    std::filesystem::create_directories(dbDir);
    rocksdb::Options options;
    options.create_if_missing = true;
#if ROCKSDB_MAJOR >= 9
    std::unique_ptr<rocksdb::DB> legacy;
    auto status = rocksdb::DB::Open(options, dbDir.string(), &legacy);
#else
    rocksdb::DB* legacyRaw = nullptr;
    auto status = rocksdb::DB::Open(options, dbDir.string(), &legacyRaw);
    std::unique_ptr<rocksdb::DB> legacy(legacyRaw);
#endif
    EXPECT_TRUE(status.ok());
    status = legacy->Put(rocksdb::WriteOptions(), "meta/generation_id", "old-string-generation");
    EXPECT_TRUE(status.ok());
    legacy.reset();

    bool threw = false;
    try {
        (void)cpbitnode::db::openRocksDbNodeStateStore(dir.string());
    } catch (const std::runtime_error& exc) {
        threw = true;
        EXPECT_TRUE(std::string(exc.what()).find("rebuild required") != std::string::npos);
    }
    EXPECT_TRUE(threw);
    std::filesystem::remove_all(dir);
}

}  // namespace

void registerNativeStoreTests() {
    RUN_TEST(testRocksDbStoreMultiGetAndHeightIndex);
    RUN_TEST(testRocksDbStoreBatchedHeaders);
    RUN_TEST(testRocksDbStoreCommitBlockUpdatesTipIndexUndoAndCounters);
    RUN_TEST(testRocksDbStoreRejectsLegacyGeneration);
}
