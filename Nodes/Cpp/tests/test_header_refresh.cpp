#include "test_support.hpp"

#include "cpbitnode/chain/params.hpp"
#include "cpbitnode/config/settings.hpp"
#include "cpbitnode/db/tracker.hpp"
#include "cpbitnode/sync/headerRefresh.hpp"
#include "cpbitnode/sync/headers.hpp"

#include <filesystem>

void registerHeaderRefreshTests();

namespace {

using cpbitnode::chain::testnet4;
using cpbitnode::config::Settings;
using cpbitnode::db::ProjectTracker;
using cpbitnode::sync::dbHeadersAlignedWithSyncState;
using cpbitnode::sync::decideHeaderRefreshAction;
using cpbitnode::sync::ensureGenesis;
using cpbitnode::sync::HeaderRefreshAction;
using cpbitnode::sync::headerRefreshLogMessage;

void testDbHeadersAlignedWithSyncState() {
    EXPECT_TRUE(!dbHeadersAlignedWithSyncState(0, 10));
    EXPECT_TRUE(dbHeadersAlignedWithSyncState(100, 100));
    EXPECT_TRUE(dbHeadersAlignedWithSyncState(100, 102));
    EXPECT_TRUE(!dbHeadersAlignedWithSyncState(100, 90));
}

void testDecideHeaderRefreshSkipSyncSkipHeaders() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_hr_skip_sync.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    ensureGenesis(tracker, testnet4());
    Settings settings;
    settings.syncSkipHeaders = true;
    const auto action = decideHeaderRefreshAction(settings, tracker, testnet4(), 0, 1000);
    EXPECT_TRUE(action == HeaderRefreshAction::SkipSyncSkipHeaders);
    EXPECT_EQ(headerRefreshLogMessage(action), "SYNC_SKIP_HEADERS=1: skipping networked header sync");
}

void testDecideHeaderRefreshSkipLocalHeadersCoverTarget() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_hr_target.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    ensureGenesis(tracker, testnet4());
    tracker.recordHeader(1, "hash1", testnet4().genesisHash, 601);
    Settings settings;
    settings.blocksTargetHeight = 1;
    const auto action = decideHeaderRefreshAction(settings, tracker, testnet4(), 0, 1000);
    EXPECT_TRUE(action == HeaderRefreshAction::SkipLocalHeadersCoverTarget);
}

void testDecideHeaderRefreshSkipAlignedDbAheadOfPeer() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_hr_aligned.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    ensureGenesis(tracker, testnet4());
    tracker.recordHeader(1, "hash1", testnet4().genesisHash, 601);
    tracker.recordHeader(2, "hash2", "hash1", 602);
    Settings settings;
    const auto action = decideHeaderRefreshAction(settings, tracker, testnet4(), 2, 500000);
    EXPECT_TRUE(action == HeaderRefreshAction::SkipAlignedDbAheadOfPeer);
}

void testDecideHeaderRefreshNetworkSyncWhenBehind() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_hr_network.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    ensureGenesis(tracker, testnet4());
    Settings settings;
    const auto action = decideHeaderRefreshAction(settings, tracker, testnet4(), 0, 500000);
    EXPECT_TRUE(action == HeaderRefreshAction::NetworkSync);
    EXPECT_EQ(headerRefreshLogMessage(action), "network_sync");
}

void testHeaderRefreshLogMessageCoversAllActions() {
    EXPECT_EQ(headerRefreshLogMessage(HeaderRefreshAction::SkipNoHeaderRefresh),
              "header_refresh_skipped_no_header_refresh_flag");
    EXPECT_EQ(headerRefreshLogMessage(HeaderRefreshAction::SkipNearPeerTip), "skip_near_peer_tip");
    EXPECT_EQ(headerRefreshLogMessage(HeaderRefreshAction::SkipSyncSkipHeaders),
              "SYNC_SKIP_HEADERS=1: skipping networked header sync");
    EXPECT_EQ(headerRefreshLogMessage(HeaderRefreshAction::SkipLocalHeadersCoverTarget),
              "header_refresh_skipped_local_headers_cover_target");
    EXPECT_EQ(headerRefreshLogMessage(HeaderRefreshAction::SkipAlignedDbAheadOfPeer),
              "skip_aligned_db_ahead_of_peer");
    EXPECT_EQ(headerRefreshLogMessage(HeaderRefreshAction::NetworkSync), "network_sync");
}

void testDecideHeaderRefreshSkipWhenPeerHeightUnknown() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_hr_unknown_peer.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    ensureGenesis(tracker, testnet4());
    Settings settings;
    const auto action = decideHeaderRefreshAction(settings, tracker, testnet4(), 0, -1);
    EXPECT_TRUE(action == HeaderRefreshAction::NetworkSync);
}

}  // namespace

void registerHeaderRefreshTests() {
    RUN_TEST(testDbHeadersAlignedWithSyncState);
    RUN_TEST(testDecideHeaderRefreshSkipSyncSkipHeaders);
    RUN_TEST(testDecideHeaderRefreshSkipLocalHeadersCoverTarget);
    RUN_TEST(testDecideHeaderRefreshSkipAlignedDbAheadOfPeer);
    RUN_TEST(testDecideHeaderRefreshNetworkSyncWhenBehind);
    RUN_TEST(testHeaderRefreshLogMessageCoversAllActions);
    RUN_TEST(testDecideHeaderRefreshSkipWhenPeerHeightUnknown);
}
