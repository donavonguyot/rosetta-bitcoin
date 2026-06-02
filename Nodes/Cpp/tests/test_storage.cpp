#include "test_support.hpp"

#include "blocks_fixture.hpp"

#include "cpbitnode/chain/params.hpp"
#include "cpbitnode/storage/blocks.hpp"

#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

void registerStorageTests();

namespace {

void testBlockStoreWriteAndRead() {
    const auto blocksDir = std::filesystem::temp_directory_path() / "cpbitnode_block_store_test";
    std::filesystem::remove_all(blocksDir);
    const std::vector<std::uint8_t> magic = {0x1c, 0x16, 0x3f, 0x28};
    cpbitnode::storage::BlockStore store(blocksDir, magic);
    const std::vector<std::uint8_t> blockBytes(120, 0x01);
    const auto result = store.write(blockBytes);
    EXPECT_EQ(result.size, 120U);
    const auto restored = store.read(result.fileName, result.offset, result.size);
    EXPECT_BYTES_EQ(restored, blockBytes);
    std::filesystem::remove_all(blocksDir);
}

void testBlockStoreReadRejectsSizeMismatch() {
    const auto blocksDir = std::filesystem::temp_directory_path() / "cpbitnode_block_store_bad_size";
    std::filesystem::remove_all(blocksDir);
    const std::vector<std::uint8_t> magic = {0x1c, 0x16, 0x3f, 0x28};
    cpbitnode::storage::BlockStore store(blocksDir, magic);
    const std::vector<std::uint8_t> blockBytes(120, 0x01);
    const auto result = store.write(blockBytes);
    bool threw = false;
    try {
        (void)store.read(result.fileName, result.offset, 119);
    } catch (const std::invalid_argument&) {
        threw = true;
    }
    EXPECT_TRUE(threw);
    std::filesystem::remove_all(blocksDir);
}

void testBlockStoreVerifyMagic() {
    const auto& params = cpbitnode::chain::testnet4();
    cpbitnode::storage::BlockStore store(cpbitnode::testfixtures::fixtureBlocksDir(), params.magic);
    EXPECT_TRUE(store.hasDataFile(0));
    EXPECT_TRUE(store.verifyMagic());
}

void testFixtureBlocksReadable() {
    for (const auto offset : cpbitnode::testfixtures::kTestnet4BlockOffsets) {
        const auto payload = cpbitnode::testfixtures::readFixtureBlock(offset);
        EXPECT_EQ(payload.size(), cpbitnode::testfixtures::kTestnet4BlockPayloadSize);
    }
}

void testFixtureBlockRoundtripThroughLocalStore() {
    const auto blocksDir = std::filesystem::temp_directory_path() / "cpbitnode_fixture_roundtrip";
    std::filesystem::remove_all(blocksDir);
    const auto payload = cpbitnode::testfixtures::readFixtureBlock(0);
    const auto& params = cpbitnode::chain::testnet4();
    cpbitnode::storage::BlockStore local(blocksDir, params.magic);
    const auto written = local.write(payload);
    const auto restored = local.read(written.fileName, written.offset, written.size);
    EXPECT_BYTES_EQ(restored, payload);
    std::filesystem::remove_all(blocksDir);
}

void testBlockStoreRejectsBadMagicLength() {
    const auto blocksDir = std::filesystem::temp_directory_path() / "cpbitnode_block_store_bad_magic";
    std::filesystem::remove_all(blocksDir);
    const std::vector<std::uint8_t> magic = {0x01, 0x02, 0x03};
    bool threw = false;
    try {
        (void)cpbitnode::storage::BlockStore(blocksDir, magic);
    } catch (const std::invalid_argument&) {
        threw = true;
    }
    EXPECT_TRUE(threw);
    std::filesystem::remove_all(blocksDir);
}

void testBlockStoreReadMissingFileThrows() {
    const auto blocksDir = std::filesystem::temp_directory_path() / "cpbitnode_block_store_missing";
    std::filesystem::remove_all(blocksDir);
    const std::vector<std::uint8_t> magic = {0x1c, 0x16, 0x3f, 0x28};
    cpbitnode::storage::BlockStore store(blocksDir, magic);
    bool threw = false;
    try {
        (void)store.read("blk00999.dat", 0, 10);
    } catch (const std::runtime_error& ex) {
        threw = true;
        EXPECT_TRUE(std::string(ex.what()).find("failed to open") != std::string::npos);
    }
    EXPECT_TRUE(threw);
    std::filesystem::remove_all(blocksDir);
}

void testBlockStoreReadRejectsMagicMismatch() {
    const auto blocksDir = std::filesystem::temp_directory_path() / "cpbitnode_block_store_magic_mismatch";
    std::filesystem::remove_all(blocksDir);
    const std::vector<std::uint8_t> magic = {0x1c, 0x16, 0x3f, 0x28};
    cpbitnode::storage::BlockStore store(blocksDir, magic);
    const auto written = store.write(std::vector<std::uint8_t>(8, 0x02));
    cpbitnode::storage::BlockStore otherStore(blocksDir, std::vector<std::uint8_t>{0xAA, 0xBB, 0xCC, 0xDD});
    bool threw = false;
    try {
        (void)otherStore.read(written.fileName, written.offset, written.size);
    } catch (const std::invalid_argument& ex) {
        threw = true;
        EXPECT_TRUE(std::string(ex.what()).find("magic mismatch") != std::string::npos);
    }
    EXPECT_TRUE(threw);
    std::filesystem::remove_all(blocksDir);
}

void testBlockStoreVerifyMagicOnFreshFile() {
    const auto blocksDir = std::filesystem::temp_directory_path() / "cpbitnode_block_store_empty_magic";
    std::filesystem::remove_all(blocksDir);
    const std::vector<std::uint8_t> magic = {0x1c, 0x16, 0x3f, 0x28};
    cpbitnode::storage::BlockStore store(blocksDir, magic);
    EXPECT_TRUE(store.hasDataFile(0));
    EXPECT_TRUE(!store.verifyMagic());
    (void)store.write(std::vector<std::uint8_t>(4, 0x01));
    EXPECT_TRUE(store.verifyMagic());
    std::filesystem::remove_all(blocksDir);
}

void testBlockStoreVerifyMagicDetectsCorruption() {
    const auto blocksDir = std::filesystem::temp_directory_path() / "cpbitnode_block_store_bad_file_magic";
    std::filesystem::remove_all(blocksDir);
    const std::vector<std::uint8_t> magic = {0x1c, 0x16, 0x3f, 0x28};
    cpbitnode::storage::BlockStore store(blocksDir, magic);
    (void)store.write(std::vector<std::uint8_t>(4, 0x01));
    std::ofstream corrupt(blocksDir / "blk00000.dat", std::ios::binary | std::ios::in | std::ios::out);
    corrupt.put(static_cast<char>(0x00));
    corrupt.close();
    EXPECT_TRUE(!store.verifyMagic());
    std::filesystem::remove_all(blocksDir);
}

void testBlockStoreReadUnexpectedEof() {
    const auto blocksDir = std::filesystem::temp_directory_path() / "cpbitnode_block_store_eof";
    std::filesystem::remove_all(blocksDir);
    const std::vector<std::uint8_t> magic = {0x1c, 0x16, 0x3f, 0x28};
    cpbitnode::storage::BlockStore store(blocksDir, magic);
    const auto written = store.write(std::vector<std::uint8_t>(16, 0x05));
    std::filesystem::resize_file(blocksDir / written.fileName, written.offset + 4);
    bool threw = false;
    try {
        (void)store.read(written.fileName, written.offset, written.size);
    } catch (const std::runtime_error& ex) {
        threw = true;
        EXPECT_TRUE(std::string(ex.what()).find("Unexpected EOF") != std::string::npos);
    }
    EXPECT_TRUE(threw);
    std::filesystem::remove_all(blocksDir);
}

}  // namespace

void registerStorageTests() {
    RUN_TEST(testBlockStoreWriteAndRead);
    RUN_TEST(testBlockStoreReadRejectsSizeMismatch);
    RUN_TEST(testBlockStoreVerifyMagic);
    RUN_TEST(testFixtureBlocksReadable);
    RUN_TEST(testFixtureBlockRoundtripThroughLocalStore);
    RUN_TEST(testBlockStoreRejectsBadMagicLength);
    RUN_TEST(testBlockStoreReadMissingFileThrows);
    RUN_TEST(testBlockStoreReadRejectsMagicMismatch);
    RUN_TEST(testBlockStoreVerifyMagicOnFreshFile);
    RUN_TEST(testBlockStoreVerifyMagicDetectsCorruption);
    RUN_TEST(testBlockStoreReadUnexpectedEof);
}
