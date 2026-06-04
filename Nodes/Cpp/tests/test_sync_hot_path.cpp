#include "test_support.hpp"

#include "cpbitnode/chain/params.hpp"
#include "cpbitnode/db/node_state.hpp"
#include "cpbitnode/messages/block.hpp"
#include "cpbitnode/messages/block_header.hpp"
#include "cpbitnode/storage/blocks.hpp"
#include "cpbitnode/sync/blocks.hpp"
#include "p2p_test_helpers.hpp"

#include <deque>
#include <filesystem>
#include <memory>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

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

std::vector<std::uint8_t> makeBlockPayload(std::uint32_t nonce) {
    cpbitnode::messages::BlockHeader header;
    header.version = 1;
    header.prevBlock.assign(32, static_cast<std::uint8_t>(nonce));
    header.merkleRoot.assign(32, static_cast<std::uint8_t>(nonce + 1));
    header.timestamp = 1000 + nonce;
    header.bits = 0x1d00ffff;
    header.nonce = nonce;
    return cpbitnode::messages::serializeBlockHeader(header);
}

cpbitnode::p2p::PeerConnection makePeer(cpbitnode::db::NodeStateStore& store,
                                        const cpbitnode::chain::ChainParams& chain,
                                        cpbitnode::testp2p::MockTransport** transportOut,
                                        std::deque<std::pair<std::string, std::vector<std::uint8_t>>>* reads) {
    cpbitnode::p2p::PeerConnection::Options options;
    options.host = "127.0.0.1";
    options.port = chain.defaultPort;
    options.chain = &chain;
    options.tracker = &store;
    cpbitnode::p2p::PeerConnection peer(options);
    auto transport = std::make_unique<cpbitnode::testp2p::MockTransport>();
    *transportOut = transport.get();
    peer.setTransportForTest(std::move(transport));
    peer.setReadMessageOverrideForTest([reads](double timeoutSeconds) {
        (void)timeoutSeconds;
        if (reads->empty()) {
            throw std::runtime_error("read timeout");
        }
        auto item = std::move(reads->front());
        reads->pop_front();
        return item;
    });
    return peer;
}

bool hasEventMessage(cpbitnode::db::NodeStateStore& store, const std::string& needle) {
    for (const auto& row : store.recentEvents(50)) {
        const auto it = row.find("message");
        if (it != row.end() && it->second.find(needle) != std::string::npos) {
            return true;
        }
    }
    return false;
}

bool capabilityEnabled(cpbitnode::db::NodeStateStore& store, const std::string& capabilityId) {
    const auto caps = store.wireCapabilityMap();
    const auto it = caps.find(capabilityId);
    return it != caps.end() && it->second == 1;
}

int capabilityValue(cpbitnode::db::NodeStateStore& store, const std::string& capabilityId) {
    const auto caps = store.wireCapabilityMap();
    const auto it = caps.find(capabilityId);
    return it == caps.end() ? 0 : it->second;
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

void testQuietBatchedFetchRecordsNoTrackerWrites() {
    const auto dir = tempSyncDir("cpbitnode_sync_hot_path_quiet_batch");
    auto store = cpbitnode::db::openRocksDbNodeStateStore(dir.string());
    const auto& chain = cpbitnode::chain::testnet4();
    cpbitnode::testp2p::MockTransport* transport = nullptr;
    std::deque<std::pair<std::string, std::vector<std::uint8_t>>> reads;
    auto peer = makePeer(*store, chain, &transport, &reads);
    const int beforeGetdata = capabilityValue(*store, "blocks.getdata.send");
    const int beforeBlockRecv = capabilityValue(*store, "blocks.block.recv");

    const auto payload = makeBlockPayload(1);
    const auto hash = cpbitnode::messages::blockHashFromPayload(payload);
    reads.emplace_back(std::string(cpbitnode::messages::BlockMessage::kCommand), payload);
    cpbitnode::p2p::BlockRequestStats stats;
    const auto results =
        peer.requestBlocks({hash}, 5.0, cpbitnode::p2p::BlockRequestOptions{false}, &stats);

    EXPECT_EQ(results.size(), static_cast<std::size_t>(1));
    EXPECT_TRUE(results[0].has_value());
    EXPECT_TRUE(stats.sentGetData);
    EXPECT_TRUE(stats.receivedBlock);
    EXPECT_TRUE(cpbitnode::testp2p::writeContainsCommand(transport->writes(),
                                                         cpbitnode::messages::GetDataMessage::kCommand));
    EXPECT_EQ(capabilityValue(*store, "blocks.getdata.send"), beforeGetdata);
    EXPECT_EQ(capabilityValue(*store, "blocks.block.recv"), beforeBlockRecv);
    EXPECT_TRUE(!hasEventMessage(*store, "Sent getdata"));

    std::filesystem::remove_all(dir);
}

void testDefaultBatchedFetchStillRecordsTrackerWrites() {
    const auto dir = tempSyncDir("cpbitnode_sync_hot_path_default_batch");
    auto store = cpbitnode::db::openRocksDbNodeStateStore(dir.string());
    const auto& chain = cpbitnode::chain::testnet4();
    cpbitnode::testp2p::MockTransport* transport = nullptr;
    std::deque<std::pair<std::string, std::vector<std::uint8_t>>> reads;
    auto peer = makePeer(*store, chain, &transport, &reads);
    const int beforeGetdata = capabilityValue(*store, "blocks.getdata.send");
    const int beforeBlockRecv = capabilityValue(*store, "blocks.block.recv");

    const auto payload = makeBlockPayload(2);
    const auto hash = cpbitnode::messages::blockHashFromPayload(payload);
    reads.emplace_back(std::string(cpbitnode::messages::BlockMessage::kCommand), payload);
    const auto results = peer.requestBlocks({hash}, 5.0);

    EXPECT_EQ(results.size(), static_cast<std::size_t>(1));
    EXPECT_TRUE(results[0].has_value());
    EXPECT_TRUE(cpbitnode::testp2p::writeContainsCommand(transport->writes(),
                                                         cpbitnode::messages::GetDataMessage::kCommand));
    EXPECT_EQ(store->wireCapabilityMap().at("blocks.getdata.send"), 1);
    EXPECT_EQ(store->wireCapabilityMap().at("blocks.block.recv"), 1);
    EXPECT_TRUE(hasEventMessage(*store, "Sent getdata"));

    std::filesystem::remove_all(dir);
}

void testQuietStreamingFetchReturnsOutOfOrderBlocksWithoutTrackerWrites() {
    const auto dir = tempSyncDir("cpbitnode_sync_hot_path_quiet_stream");
    auto store = cpbitnode::db::openRocksDbNodeStateStore(dir.string());
    const auto& chain = cpbitnode::chain::testnet4();
    cpbitnode::testp2p::MockTransport* transport = nullptr;
    std::deque<std::pair<std::string, std::vector<std::uint8_t>>> reads;
    auto peer = makePeer(*store, chain, &transport, &reads);
    const int beforeGetdata = capabilityValue(*store, "blocks.getdata.send");
    const int beforeBlockRecv = capabilityValue(*store, "blocks.block.recv");

    const auto payload1 = makeBlockPayload(3);
    const auto payload2 = makeBlockPayload(4);
    const auto hash1 = cpbitnode::messages::blockHashFromPayload(payload1);
    const auto hash2 = cpbitnode::messages::blockHashFromPayload(payload2);
    reads.emplace_back(std::string(cpbitnode::messages::BlockMessage::kCommand), payload2);
    reads.emplace_back(std::string(cpbitnode::messages::BlockMessage::kCommand), payload1);

    std::vector<std::size_t> seenIndexes;
    cpbitnode::p2p::BlockRequestStats stats;
    const bool ok = peer.requestBlocksStreaming(
        {hash1, hash2}, 2,
        [&seenIndexes](std::size_t index, std::vector<std::uint8_t> payload, long long fetchWaitUs) {
            (void)payload;
            EXPECT_TRUE(fetchWaitUs >= 0);
            seenIndexes.push_back(index);
            return true;
        },
        5.0, cpbitnode::p2p::BlockRequestOptions{false}, &stats);

    EXPECT_TRUE(ok);
    EXPECT_EQ(seenIndexes.size(), static_cast<std::size_t>(2));
    EXPECT_EQ(seenIndexes[0], static_cast<std::size_t>(1));
    EXPECT_EQ(seenIndexes[1], static_cast<std::size_t>(0));
    EXPECT_TRUE(stats.sentGetData);
    EXPECT_TRUE(stats.receivedBlock);
    EXPECT_TRUE(cpbitnode::testp2p::writeContainsCommand(transport->writes(),
                                                         cpbitnode::messages::GetDataMessage::kCommand));
    EXPECT_EQ(capabilityValue(*store, "blocks.getdata.send"), beforeGetdata);
    EXPECT_EQ(capabilityValue(*store, "blocks.block.recv"), beforeBlockRecv);
    EXPECT_TRUE(!hasEventMessage(*store, "Sent getdata"));

    std::filesystem::remove_all(dir);
}

}  // namespace

void registerSyncHotPathTests() {
    RUN_TEST(testBoundedTargetDoesNotMarkBlocksCurrent);
    RUN_TEST(testUnboundedCaughtUpMarksBlocksCurrent);
    RUN_TEST(testQuietBatchedFetchRecordsNoTrackerWrites);
    RUN_TEST(testDefaultBatchedFetchStillRecordsTrackerWrites);
    RUN_TEST(testQuietStreamingFetchReturnsOutOfOrderBlocksWithoutTrackerWrites);
}
