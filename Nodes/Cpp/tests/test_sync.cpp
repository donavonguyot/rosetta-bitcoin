#include "test_support.hpp"
#include "blocks_fixture.hpp"
#include "p2p_test_helpers.hpp"

#include "cpbitnode/chain/params.hpp"
#include "cpbitnode/config/settings.hpp"
#include "cpbitnode/db/tracker.hpp"
#include "cpbitnode/messages/block.hpp"
#include "cpbitnode/messages/block_header.hpp"
#include "cpbitnode/messages/handshake.hpp"
#include "cpbitnode/messages/headers.hpp"
#include "cpbitnode/messages/inventory.hpp"
#include "cpbitnode/p2p/manager.hpp"
#include "cpbitnode/p2p/peer.hpp"
#include "cpbitnode/storage/blocks.hpp"
#include "cpbitnode/sync/blocks.hpp"
#include "cpbitnode/sync/headerRefresh.hpp"
#include "cpbitnode/sync/headers.hpp"
#include "cpbitnode/sync/syncDatadirLock.hpp"

#include <filesystem>
#include <optional>
#include <vector>

void registerSyncTests();

namespace {

using cpbitnode::chain::testnet4;
using cpbitnode::config::Settings;
using cpbitnode::db::ProjectTracker;
using cpbitnode::p2p::PeerConnection;
using cpbitnode::p2p::PeerManager;
using cpbitnode::storage::BlockStore;
using cpbitnode::sync::decideHeaderRefreshAction;
using cpbitnode::sync::ensureGenesis;
using cpbitnode::sync::HeaderRefreshAction;
using cpbitnode::sync::headersSyncDone;
using cpbitnode::sync::markHeadersCurrent;
using cpbitnode::sync::repairSyncState;
using cpbitnode::sync::syncBlocksBatch;
using cpbitnode::testfixtures::kTestnet4BlockHashes;
using cpbitnode::testfixtures::readFixtureBlock;
using cpbitnode::testp2p::MockTransport;
using cpbitnode::messages::BlockHeader;
using cpbitnode::messages::BlockMessage;
using cpbitnode::messages::HeadersMessage;
using cpbitnode::messages::InventoryVector;
using cpbitnode::messages::MSG_WITNESS_BLOCK;
using cpbitnode::messages::NotFoundMessage;
using cpbitnode::messages::VersionMessage;
using cpbitnode::messages::serializeHeadersMessage;
using cpbitnode::sync::ExclusiveDataDirSyncLock;

void seedHeadersAfterGenesis(ProjectTracker& tracker) {
    tracker.recordHeader(1, "hash1", testnet4().genesisHash, 601);
    tracker.recordHeader(2, "hash2", "hash1", 602);
}

class BlockReturningPeer final : public PeerConnection {
public:
    BlockReturningPeer(PeerConnection::Options options, std::vector<std::uint8_t> payload)
        : PeerConnection(std::move(options)), payload_(std::move(payload)) {
        setTransportForTest(std::make_unique<MockTransport>());
    }

    void connect() override {}

    bool isConnected() const override { return true; }

    std::optional<std::vector<std::uint8_t>> requestBlock(const std::vector<std::uint8_t>& blockHash,
                                                           double timeoutSeconds) override {
        (void)blockHash;
        (void)timeoutSeconds;
        return payload_;
    }

private:
    std::vector<std::uint8_t> payload_;
};

void testHeadersSyncDoneEmptyBatch() {
    EXPECT_TRUE(headersSyncDone(100, 200, 0));
}

void testHeadersSyncDoneAtPeerHeight() {
    EXPECT_TRUE(headersSyncDone(200, 200, 2000));
    EXPECT_TRUE(!headersSyncDone(199, 200, 2000));
}

void testMarkHeadersCurrentUpdatesSyncState() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_headers_current.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    ensureGenesis(tracker, testnet4());
    tracker.upsertSyncState(testnet4().name, 0, testnet4().genesisHash, tracker.headerCount(), "headers_syncing");
    markHeadersCurrent(tracker, testnet4());
    const auto state = tracker.getSyncState(testnet4().name);
    EXPECT_TRUE(state.has_value());
    EXPECT_EQ((*state).at("sync_status"), "headers_current");
}

void testListMissingBlockHeights() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_missing_blocks.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    ensureGenesis(tracker, testnet4());
    tracker.recordHeader(1, "hash1", testnet4().genesisHash, 100);
    tracker.recordHeader(2, "hash2", "hash1", 200);
    auto missing = tracker.listMissingBlockHeights(10);
    EXPECT_EQ(missing.size(), 2u);
    EXPECT_EQ(missing[0], 1);
    EXPECT_EQ(missing[1], 2);
    tracker.recordBlock(1, "hash1", "blk00000.dat", 0, 100);
    missing = tracker.listMissingBlockHeights(10);
    EXPECT_EQ(missing.size(), 1u);
    EXPECT_EQ(missing[0], 2);
}

void testDecideHeaderRefreshSkipsNoHeaderRefresh() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_refresh_skip.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    ensureGenesis(tracker, testnet4());
    seedHeadersAfterGenesis(tracker);
    Settings settings;
    settings.noHeaderRefresh = true;
    const auto action = decideHeaderRefreshAction(settings, tracker, testnet4(), 0, 500000);
    EXPECT_TRUE(action == HeaderRefreshAction::SkipNoHeaderRefresh);
}

void testDecideHeaderRefreshSkipsNearPeerTip() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_refresh_near.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    ensureGenesis(tracker, testnet4());
    tracker.recordHeader(1, "hash1", testnet4().genesisHash, 601);
    tracker.upsertSyncState(testnet4().name, 1, "hash1", tracker.headerCount(), "headers_syncing");
    Settings settings;
    const auto action = decideHeaderRefreshAction(settings, tracker, testnet4(), 1, 2);
    EXPECT_TRUE(action == HeaderRefreshAction::SkipNearPeerTip);
}

void testDatadirLockHeld() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_sync_lock";
    std::filesystem::remove_all(path);
    std::filesystem::create_directories(path);
    cpbitnode::sync::ExclusiveDataDirSyncLock first(path);
    bool threw = false;
    try {
        cpbitnode::sync::ExclusiveDataDirSyncLock second(path);
    } catch (const std::runtime_error& exc) {
        threw = std::string(exc.what()).find("Another cpbitnode-sync") != std::string::npos;
    }
    EXPECT_TRUE(threw);
}

void testMockHeaderSyncEmptyBatchMarksCurrent() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_mock_header_sync.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    ensureGenesis(tracker, testnet4());

    PeerConnection::Options options;
    options.host = "127.0.0.1";
    options.port = 48333;
    options.chain = &testnet4();
    options.tracker = &tracker;
    PeerConnection peer(std::move(options));
    peer.setTransportForTest(std::make_unique<MockTransport>());

    const HeadersMessage empty;
    const auto headersPayload = serializeHeadersMessage(empty);
    peer.setReadMessageOverrideForTest([&](double) {
        return std::pair<std::string, std::vector<std::uint8_t>>{std::string(HeadersMessage::kCommand),
                                                                 headersPayload};
    });

    const int stored = peer.syncHeaders();
    EXPECT_EQ(stored, 0);
    const auto state = tracker.getSyncState(testnet4().name);
    EXPECT_TRUE(state.has_value());
    EXPECT_EQ((*state).at("sync_status"), "headers_current");
}

void testMockBlockSyncDownloadsFixtureBlock() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_mock_block_sync.db";
    std::filesystem::remove(path);
    const auto blocksPath = std::filesystem::temp_directory_path() / "cpbitnode_mock_block_sync_blocks";
    std::filesystem::remove_all(blocksPath);
    ProjectTracker tracker(path.string());
    ensureGenesis(tracker, testnet4());
    tracker.recordHeader(1, kTestnet4BlockHashes[0], testnet4().genesisHash, 1714777861);

    BlockStore blockStore(blocksPath, testnet4().magic);
    const auto payload = readFixtureBlock(0);

    PeerConnection::Options options;
    options.host = "127.0.0.1";
    options.port = 48333;
    options.chain = &testnet4();
    options.tracker = &tracker;
    BlockReturningPeer peer(std::move(options), payload);

    const int downloaded = syncBlocksBatch({&peer}, tracker, testnet4(), blockStore, 8, 0, 0);
    EXPECT_EQ(downloaded, 1);
    EXPECT_EQ(tracker.getValidatedHeight(testnet4().name), 1);
    EXPECT_EQ(tracker.blockCount(), 1);
}

void testPeerManagerSkipsNetworkedHeadersWhenConfigured() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_mgr_refresh_skip.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    ensureGenesis(tracker, testnet4());
    seedHeadersAfterGenesis(tracker);
    repairSyncState(tracker, testnet4());

    Settings settings;
    settings.noHeaderRefresh = true;
    PeerManager manager(testnet4(), tracker, settings);

    struct HeaderSyncProbePeer final : public PeerConnection {
        HeaderSyncProbePeer(PeerConnection::Options options, bool* called)
            : PeerConnection(std::move(options)), called_(called) {
            setTransportForTest(std::make_unique<MockTransport>());
        }
        void connect() override {}
        bool isConnected() const override { return true; }
        int syncHeaders() override {
            *called_ = true;
            return 0;
        }

    private:
        bool* called_;
    };

    bool headerSyncCalled = false;
    manager.setPeerFactoryForTest([&](const std::string& host, int port) {
        PeerConnection::Options options;
        options.host = host;
        options.port = port;
        options.chain = &testnet4();
        options.tracker = &tracker;
        options.settings = settings;
        return std::make_unique<HeaderSyncProbePeer>(std::move(options), &headerSyncCalled);
    });
    manager.bootstrap({{"127.0.0.1", 48333}});

    const auto action = decideHeaderRefreshAction(settings, tracker, testnet4(), 0, 500000);
    if (action != HeaderRefreshAction::NetworkSync) {
        markHeadersCurrent(tracker, testnet4());
    } else {
        manager.syncHeaders();
    }
    EXPECT_TRUE(!headerSyncCalled);
    const auto state = tracker.getSyncState(testnet4().name);
    EXPECT_EQ((*state).at("sync_status"), "headers_current");
}

void testDatadirLockReleasedAfterScope() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_sync_lock_release";
    std::filesystem::remove_all(path);
    std::filesystem::create_directories(path);
    {
        ExclusiveDataDirSyncLock first(path);
    }
    bool threw = false;
    try {
        ExclusiveDataDirSyncLock second(path);
    } catch (const std::runtime_error&) {
        threw = true;
    }
    EXPECT_TRUE(!threw);
}

void testMockRequestBlockNotfound() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_req_nf.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    ensureGenesis(tracker, testnet4());

    PeerConnection::Options options;
    options.host = "127.0.0.1";
    options.port = 48333;
    options.chain = &testnet4();
    options.tracker = &tracker;
    PeerConnection peer(std::move(options));
    peer.setTransportForTest(std::make_unique<MockTransport>());
    VersionMessage version;
    version.startHeight = 1;
    peer.setRemoteVersionForTest(version);

    const std::vector<std::uint8_t> wantHash(32, 0xAB);
    InventoryVector missing;
    missing.type = MSG_WITNESS_BLOCK;
    missing.hash = wantHash;
    NotFoundMessage nf;
    nf.inventory.push_back(missing);
    const auto nfPayload = nf.serialize();

    peer.setReadMessageOverrideForTest([&](double) {
        return std::pair<std::string, std::vector<std::uint8_t>>{std::string(NotFoundMessage::kCommand), nfPayload};
    });

    const auto payload = peer.requestBlock(wantHash, 5.0);
    EXPECT_TRUE(!payload.has_value());
    EXPECT_EQ(tracker.wireCapabilityMap().at("blocks.notfound"), 1);
}

void testMockRequestBlockHashMismatch() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_req_mismatch.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    ensureGenesis(tracker, testnet4());

    PeerConnection::Options options;
    options.host = "127.0.0.1";
    options.port = 48333;
    options.chain = &testnet4();
    options.tracker = &tracker;
    PeerConnection peer(std::move(options));
    peer.setTransportForTest(std::make_unique<MockTransport>());

    const std::vector<std::uint8_t> wantHash(32, 0xCD);
    const auto wrongBlock = readFixtureBlock(0);
    peer.setReadMessageOverrideForTest([&](double) {
        return std::pair<std::string, std::vector<std::uint8_t>>{std::string(BlockMessage::kCommand), wrongBlock};
    });

    const auto payload = peer.requestBlock(wantHash, 5.0);
    EXPECT_TRUE(!payload.has_value());
}

void testMockRequestHeadersReturnsBatch() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_req_headers.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    const auto genesis = ensureGenesis(tracker, testnet4());

    PeerConnection::Options options;
    options.host = "127.0.0.1";
    options.port = 48333;
    options.chain = &testnet4();
    options.tracker = &tracker;
    PeerConnection peer(std::move(options));
    peer.setTransportForTest(std::make_unique<MockTransport>());

    BlockHeader h1;
    h1.version = genesis.version;
    h1.prevBlock = genesis.blockHash();
    h1.merkleRoot = std::vector<std::uint8_t>(32, 0x55);
    h1.timestamp = genesis.timestamp + 600;
    h1.bits = genesis.bits;
    h1.nonce = genesis.nonce + 3;
    HeadersMessage reply;
    reply.headers.push_back(h1);
    const auto headersPayload = serializeHeadersMessage(reply);
    peer.setReadMessageOverrideForTest([&](double) {
        return std::pair<std::string, std::vector<std::uint8_t>>{std::string(HeadersMessage::kCommand),
                                                                 headersPayload};
    });

    const auto locator = std::vector<std::vector<std::uint8_t>>{genesis.blockHash()};
    const auto message = peer.requestHeaders(locator);
    EXPECT_EQ(message.headers.size(), 1u);
    EXPECT_EQ(tracker.wireCapabilityMap().at("headers.getheaders.send"), 1);
    EXPECT_EQ(tracker.wireCapabilityMap().at("headers.headers.recv"), 1);
}

void testMockHeaderSyncSkipsWhenNearPeerTip() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_mock_header_skip.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    ensureGenesis(tracker, testnet4());
    tracker.recordHeader(1, "hash1", testnet4().genesisHash, 601);
    tracker.upsertSyncState(testnet4().name, 1, "hash1", tracker.headerCount(), "headers_syncing");

    PeerConnection::Options options;
    options.host = "127.0.0.1";
    options.port = 48333;
    options.chain = &testnet4();
    options.tracker = &tracker;
    PeerConnection peer(std::move(options));
    peer.setTransportForTest(std::make_unique<MockTransport>());
    VersionMessage version;
    version.startHeight = 1;
    peer.setRemoteVersionForTest(version);

    const int stored = peer.syncHeaders();
    EXPECT_EQ(stored, 0);
    const auto state = tracker.getSyncState(testnet4().name);
    EXPECT_EQ((*state).at("sync_status"), "headers_current");
}

}  // namespace

void registerSyncTests() {
    RUN_TEST(testHeadersSyncDoneEmptyBatch);
    RUN_TEST(testHeadersSyncDoneAtPeerHeight);
    RUN_TEST(testMarkHeadersCurrentUpdatesSyncState);
    RUN_TEST(testListMissingBlockHeights);
    RUN_TEST(testDecideHeaderRefreshSkipsNoHeaderRefresh);
    RUN_TEST(testDecideHeaderRefreshSkipsNearPeerTip);
    RUN_TEST(testDatadirLockHeld);
    RUN_TEST(testDatadirLockReleasedAfterScope);
    RUN_TEST(testMockHeaderSyncEmptyBatchMarksCurrent);
    RUN_TEST(testMockHeaderSyncSkipsWhenNearPeerTip);
    RUN_TEST(testMockBlockSyncDownloadsFixtureBlock);
    RUN_TEST(testPeerManagerSkipsNetworkedHeadersWhenConfigured);
    RUN_TEST(testMockRequestBlockNotfound);
    RUN_TEST(testMockRequestBlockHashMismatch);
    RUN_TEST(testMockRequestHeadersReturnsBatch);
}
