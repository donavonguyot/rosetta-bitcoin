#include "test_support.hpp"

#include "blocks_fixture.hpp"
#include "cpbitnode/chain/genesis.hpp"
#include "cpbitnode/chain/params.hpp"
#include "cpbitnode/db/tracker.hpp"
#include "cpbitnode/messages/inventory.hpp"
#include "cpbitnode/p2p/headerServing.hpp"
#include "cpbitnode/storage/blocks.hpp"
#include "cpbitnode/sync/headers.hpp"

#include <filesystem>
#include <iomanip>
#include <sstream>
#include <vector>

void registerHeaderServingTests();

namespace {

std::string bytesToHex(std::span<const std::uint8_t> data) {
    std::ostringstream oss;
    for (const auto byte : data) {
        oss << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(byte);
    }
    return oss.str();
}

using cpbitnode::messages::BlockHeader;
using cpbitnode::messages::GetHeadersMessage;
using cpbitnode::p2p::kHeaderBatchMax;
using cpbitnode::p2p::buildHeadersResponse;
using cpbitnode::p2p::findCommonForkHeight;
using cpbitnode::p2p::resolveHeaderRecord;

std::vector<std::uint8_t> makeHash(std::uint8_t fill) { return std::vector<std::uint8_t>(32, fill); }

void testGetHeadersMessageRoundtrip() {
    GetHeadersMessage msg;
    msg.version = 70016;
    msg.locatorHashes = {makeHash(0xaa), cpbitnode::chain::testnet4Genesis().blockHash()};
    msg.hashStop = makeHash(0x00);
    const auto raw = msg.serialize();
    const auto decoded = GetHeadersMessage::deserialize(raw);
    EXPECT_EQ(decoded.version, msg.version);
    EXPECT_EQ(decoded.locatorHashes.size(), msg.locatorHashes.size());
    EXPECT_BYTES_EQ(decoded.hashStop, msg.hashStop);
}

void testFindCommonForkHeightSkipsUnknownThenHitsGenesis() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_fork.db";
    std::filesystem::remove(path);
    cpbitnode::db::ProjectTracker tracker(path.string());
    cpbitnode::sync::ensureGenesis(tracker, cpbitnode::chain::testnet4());
    const auto g = cpbitnode::chain::testnet4Genesis().blockHash();
    EXPECT_EQ(findCommonForkHeight(tracker, {makeHash(0xee), g}), 0);
}

void testBuildHeadersResponseGenesisOnlyUnknownLocator() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_gen_only.db";
    std::filesystem::remove(path);
    cpbitnode::db::ProjectTracker tracker(path.string());
    const auto genesis = cpbitnode::sync::ensureGenesis(tracker, cpbitnode::chain::testnet4());
    GetHeadersMessage gh;
    gh.version = 70016;
    gh.locatorHashes = {makeHash(0xbb)};
    gh.hashStop = makeHash(0x00);
    const auto reply = buildHeadersResponse(tracker, cpbitnode::chain::testnet4(), gh, nullptr);
    EXPECT_EQ(reply.headers.size(), 1u);
    EXPECT_EQ(reply.headers[0].blockHashHex(), genesis.blockHashHex());
}

void testBuildHeadersResponseReturnsSuccessorsAfterLocator() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_chs.db";
    std::filesystem::remove(path);
    cpbitnode::db::ProjectTracker tracker(path.string());
    const auto g = cpbitnode::sync::ensureGenesis(tracker, cpbitnode::chain::testnet4());
    BlockHeader h1;
    h1.version = g.version;
    h1.prevBlock = g.blockHash();
    h1.merkleRoot = makeHash(0x12);
    h1.timestamp = g.timestamp + 600;
    h1.bits = g.bits;
    h1.nonce = g.nonce + 1;
    tracker.recordHeader(1, h1.blockHashHex(), g.blockHashHex(), h1.timestamp, bytesToHex(h1.serialize()));
    GetHeadersMessage gh;
    gh.version = 70016;
    gh.locatorHashes = {g.blockHash()};
    gh.hashStop = makeHash(0x00);
    const auto reply = buildHeadersResponse(tracker, cpbitnode::chain::testnet4(), gh, nullptr);
    EXPECT_EQ(reply.headers.size(), 1u);
    EXPECT_EQ(reply.headers[0].blockHashHex(), h1.blockHashHex());
}

void testBuildHeadersResponseTruncatesAt2000Headers() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_batch.db";
    std::filesystem::remove(path);
    cpbitnode::db::ProjectTracker tracker(path.string());
    const auto tip = cpbitnode::sync::ensureGenesis(tracker, cpbitnode::chain::testnet4());
    auto prev = tip.blockHash();
    auto prevHex = tip.blockHashHex();
    for (int height = 1; height <= kHeaderBatchMax + 1; ++height) {
        BlockHeader hdr;
        hdr.version = tip.version;
        hdr.prevBlock = prev;
        hdr.merkleRoot = std::vector<std::uint8_t>(32, static_cast<std::uint8_t>(height & 0xff));
        hdr.timestamp = tip.timestamp + 600 * height;
        hdr.bits = tip.bits;
        hdr.nonce = tip.nonce + height;
        tracker.recordHeader(height, hdr.blockHashHex(), prevHex, hdr.timestamp, bytesToHex(hdr.serialize()));
        prev = hdr.blockHash();
        prevHex = hdr.blockHashHex();
    }
    GetHeadersMessage gh;
    gh.version = 70016;
    gh.locatorHashes = {tip.blockHash()};
    gh.hashStop = makeHash(0x00);
    const auto reply = buildHeadersResponse(tracker, cpbitnode::chain::testnet4(), gh, nullptr);
    EXPECT_EQ(static_cast<int>(reply.headers.size()), kHeaderBatchMax);
}

void testResolveHeaderFromBlockStoreWhenSerializedMissing() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_blk_hdr.db";
    std::filesystem::remove(path);
    cpbitnode::db::ProjectTracker tracker(path.string());
    cpbitnode::sync::ensureGenesis(tracker, cpbitnode::chain::testnet4());
    const auto& params = cpbitnode::chain::testnet4();
    cpbitnode::storage::BlockStore fixtureStore(cpbitnode::testfixtures::fixtureBlocksDir(), params.magic);
    const auto payload = fixtureStore.read("blk00000.dat", 0, cpbitnode::testfixtures::kTestnet4BlockPayloadSize);
    const auto blocksDir = path.parent_path() / "blocks_store";
    cpbitnode::storage::BlockStore local(blocksDir, params.magic);
    const auto writeResult = local.write(payload);
    constexpr const char* kBlock1HashHex = "0000000012982b6d5f621229286b880e909984df669c2afabb102ce311b13f28";
    tracker.recordHeader(1, kBlock1HashHex, params.genesisHash, 1714777861);
    tracker.recordBlock(1, kBlock1HashHex, writeResult.fileName, static_cast<int>(writeResult.offset),
                        static_cast<int>(writeResult.size));
    const auto hdr = resolveHeaderRecord(tracker, params, 1, &local);
    EXPECT_TRUE(hdr.has_value());
    if (hdr) {
        EXPECT_EQ(hdr->blockHashHex(), kBlock1HashHex);
    }
}

void testHeaderBatchLimitConstants() { EXPECT_EQ(kHeaderBatchMax, 2000); }

}  // namespace

void registerHeaderServingTests() {
    RUN_TEST(testGetHeadersMessageRoundtrip);
    RUN_TEST(testFindCommonForkHeightSkipsUnknownThenHitsGenesis);
    RUN_TEST(testBuildHeadersResponseGenesisOnlyUnknownLocator);
    RUN_TEST(testBuildHeadersResponseReturnsSuccessorsAfterLocator);
    RUN_TEST(testBuildHeadersResponseTruncatesAt2000Headers);
    RUN_TEST(testResolveHeaderFromBlockStoreWhenSerializedMissing);
    RUN_TEST(testHeaderBatchLimitConstants);
}
