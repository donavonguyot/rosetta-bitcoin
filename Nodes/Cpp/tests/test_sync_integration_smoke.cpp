#include "test_support.hpp"

#include "cpbitnode/chain/params.hpp"
#include "cpbitnode/config/settings.hpp"
#include "cpbitnode/db/tracker.hpp"
#include "cpbitnode/p2p/manager.hpp"
#include "cpbitnode/p2p/peer.hpp"
#include "cpbitnode/storage/blocks.hpp"
#include "cpbitnode/sync/headerRefresh.hpp"
#include "cpbitnode/sync/headers.hpp"

#include <filesystem>
#include <memory>

void registerSyncIntegrationSmokeTests();

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
using cpbitnode::sync::markHeadersCurrent;
using cpbitnode::sync::repairSyncState;

void seedHeadersAfterGenesis(ProjectTracker& tracker) {
    tracker.recordHeader(1, "hash1", testnet4().genesisHash, 601);
    tracker.recordHeader(2, "hash2", "hash1", 602);
}

class FakeConnectedPeer final : public PeerConnection {
public:
    explicit FakeConnectedPeer(ProjectTracker& tracker) : PeerConnection(makeOptions(tracker)) {}

    void connect() override {}
    bool isConnected() const override { return true; }

private:
    static PeerConnection::Options makeOptions(ProjectTracker& tracker) {
        PeerConnection::Options options;
        options.host = "127.0.0.1";
        options.port = 48333;
        options.chain = &testnet4();
        options.tracker = &tracker;
        return options;
    }
};

void testNoHeaderRefreshSkipsNetworkHeaderSync() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_smoke_nhr.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    ensureGenesis(tracker, testnet4());
    seedHeadersAfterGenesis(tracker);
    repairSyncState(tracker, testnet4());

    Settings settings;
    settings.noHeaderRefresh = true;
    settings.skipGetaddr = true;

    const auto refreshAction = decideHeaderRefreshAction(settings, tracker, testnet4(), 2, 500000);
    EXPECT_TRUE(refreshAction != HeaderRefreshAction::NetworkSync);
    markHeadersCurrent(tracker, testnet4());
    const auto state = tracker.getSyncState(testnet4().name);
    EXPECT_TRUE(state.has_value());
    EXPECT_EQ(state->at("sync_status"), "headers_current");
}

void testPeerManagerBootstrapWithManualPeerUsesMockFactory() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_smoke_boot.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    ensureGenesis(tracker, testnet4());
    markHeadersCurrent(tracker, testnet4());
    Settings settings;
    settings.skipGetaddr = true;
    PeerManager mgr(testnet4(), tracker, settings);
    mgr.setPeerFactoryForTest([&](const std::string&, int) {
        return std::make_unique<FakeConnectedPeer>(tracker);
    });
    mgr.bootstrap({{"127.0.0.1", 48333}});
    EXPECT_EQ(mgr.connections().size(), 1u);
    BlockStore blockStore((path.parent_path() / "blocks_smoke").string(), testnet4().magic);
    EXPECT_EQ(mgr.syncBlocks(blockStore), 0);
}

}  // namespace

void registerSyncIntegrationSmokeTests() {
    RUN_TEST(testNoHeaderRefreshSkipsNetworkHeaderSync);
    RUN_TEST(testPeerManagerBootstrapWithManualPeerUsesMockFactory);
}
