#include "test_support.hpp"

#include "cpbitnode/chain/params.hpp"
#include "cpbitnode/config/settings.hpp"
#include "cpbitnode/db/tracker.hpp"
#include "cpbitnode/messages/handshake.hpp"
#include "cpbitnode/node.hpp"
#include "cpbitnode/p2p/peer.hpp"

#include <filesystem>
#include <memory>

void registerNodeTests();

namespace {

using cpbitnode::chain::testnet4;
using cpbitnode::config::Settings;
using cpbitnode::db::ProjectTracker;
using cpbitnode::messages::VersionMessage;
using cpbitnode::p2p::PeerConnection;

class FakeConnectedPeer final : public PeerConnection {
public:
    FakeConnectedPeer(ProjectTracker& tracker, Settings settings, int startHeight = 0, int syncHeaderReturn = 0)
        : PeerConnection(makeOptions(tracker, std::move(settings), startHeight)), syncHeaderReturn_(syncHeaderReturn) {
        VersionMessage version;
        version.startHeight = startHeight;
        version.version = 70016;
        setRemoteVersionForTest(version);
    }

    void connect() override {}
    bool isConnected() const override { return true; }
    int syncHeaders() override { return syncHeaderReturn_; }

private:
    int syncHeaderReturn_;
    static PeerConnection::Options makeOptions(ProjectTracker& tracker, Settings settings, int startHeight) {
        PeerConnection::Options options;
        options.host = "203.0.113.77";
        options.port = testnet4().defaultPort;
        options.chain = &testnet4();
        options.tracker = &tracker;
        options.settings = std::move(settings);
        options.startHeight = startHeight;
        return options;
    }
};

class FailingPeerFixed final : public PeerConnection {
public:
    explicit FailingPeerFixed(ProjectTracker& tracker) : PeerConnection(makeOptions(tracker)) {}

    void connect() override { throw std::runtime_error("connect failed"); }

private:
    static PeerConnection::Options makeOptions(ProjectTracker& tracker) {
        PeerConnection::Options options;
        options.host = "203.0.113.78";
        options.port = testnet4().defaultPort;
        options.chain = &testnet4();
        options.tracker = &tracker;
        options.settings.skipGetaddr = true;
        return options;
    }
};

Settings baseNodeSettings(const std::filesystem::path& base) {
    Settings settings;
    settings.dataDir = base.string();
    settings.syncOnly = true;
    settings.noHeaderRefresh = true;
    settings.skipGetaddr = true;
    settings.peers = "203.0.113.77:48333";
    settings.maxOutboundPeers = 1;
    settings.metricsHttpPort = 0;
    return settings;
}

void testRunNodeSyncOnlyWithMockPeer() {
    const auto base = std::filesystem::temp_directory_path() / "cpbitnode_run_node_sync_only";
    std::filesystem::remove_all(base);
    std::filesystem::create_directories(base);

    Settings settings = baseNodeSettings(base);

    const int code = cpbitnode::runNode(
        settings, [](const std::string&, int, ProjectTracker& tracker) {
            Settings peerSettings;
            peerSettings.skipGetaddr = true;
            return std::make_unique<FakeConnectedPeer>(tracker, peerSettings);
        });
    EXPECT_EQ(code, 0);

    ProjectTracker tracker(settings.resolvedDbPath());
    const auto state = tracker.getSyncState(testnet4().name);
    EXPECT_TRUE(state.has_value());
    EXPECT_EQ(state->at("sync_status"), "running");
}

void testRunNodeWithMetricsServerEnabled() {
    const auto base = std::filesystem::temp_directory_path() / "cpbitnode_run_node_metrics";
    std::filesystem::remove_all(base);
    std::filesystem::create_directories(base);
    Settings settings = baseNodeSettings(base);
    settings.metricsHttpPort = 0;
    const int code = cpbitnode::runNode(
        settings, [](const std::string&, int, ProjectTracker& tracker) {
            return std::make_unique<FakeConnectedPeer>(tracker, Settings{});
        });
    EXPECT_EQ(code, 0);
}

void testRunNodeSyncSkipHeadersPath() {
    const auto base = std::filesystem::temp_directory_path() / "cpbitnode_run_node_skip_headers";
    std::filesystem::remove_all(base);
    Settings settings = baseNodeSettings(base);
    settings.noHeaderRefresh = false;
    settings.syncSkipHeaders = true;
    const int code = cpbitnode::runNode(
        settings, [](const std::string&, int, ProjectTracker& tracker) {
            Settings peerSettings;
            peerSettings.skipGetaddr = true;
            return std::make_unique<FakeConnectedPeer>(tracker, peerSettings, 100);
        });
    EXPECT_EQ(code, 0);
    ProjectTracker tracker(settings.resolvedDbPath());
    const auto state = tracker.getSyncState(testnet4().name);
    EXPECT_TRUE(state.has_value());
    EXPECT_EQ(state->at("sync_status"), "running");
}

void testRunNodeBootstrapFailureRecordsError() {
    const auto base = std::filesystem::temp_directory_path() / "cpbitnode_run_node_bootstrap_fail";
    std::filesystem::remove_all(base);
    Settings settings = baseNodeSettings(base);
    bool threw = false;
    try {
        (void)cpbitnode::runNode(settings, [](const std::string&, int, ProjectTracker& tracker) {
            return std::make_unique<FailingPeerFixed>(tracker);
        });
    } catch (const std::runtime_error&) {
        threw = true;
    }
    EXPECT_TRUE(threw);
    ProjectTracker tracker(settings.resolvedDbPath());
    const auto state = tracker.getSyncState(testnet4().name);
    EXPECT_TRUE(state.has_value());
    EXPECT_EQ(state->at("sync_status"), "error");
}

void testRunNodeHeaderRefreshNetworkSyncPath() {
    const auto base = std::filesystem::temp_directory_path() / "cpbitnode_run_node_hdr_sync";
    std::filesystem::remove_all(base);
    Settings settings = baseNodeSettings(base);
    settings.noHeaderRefresh = false;
    settings.syncSkipHeaders = false;
    const int code = cpbitnode::runNode(
        settings, [](const std::string&, int, ProjectTracker& tracker) {
            Settings peerSettings;
            peerSettings.skipGetaddr = true;
            return std::make_unique<FakeConnectedPeer>(tracker, peerSettings, 500, 3);
        });
    EXPECT_EQ(code, 0);
}

void testRunNodeRegtestChainName() {
    const auto base = std::filesystem::temp_directory_path() / "cpbitnode_run_node_regtest";
    std::filesystem::remove_all(base);
    Settings settings = baseNodeSettings(base);
    settings.chain = "regtest";
    settings.peers = "203.0.113.77:18444";
    const int code = cpbitnode::runNode(
        settings, [](const std::string&, int, ProjectTracker& tracker) {
            return std::make_unique<FakeConnectedPeer>(tracker, Settings{});
        });
    EXPECT_EQ(code, 0);
    ProjectTracker tracker(settings.resolvedDbPath());
    EXPECT_EQ(tracker.getMeta("chain").value_or(""), "regtest");
}

void testRunNodeRebuildValidatedChainFlag() {
    const auto base = std::filesystem::temp_directory_path() / "cpbitnode_run_node_rebuild";
    std::filesystem::remove_all(base);
    Settings settings = baseNodeSettings(base);
    settings.rebuildValidatedChain = true;
    const int code = cpbitnode::runNode(
        settings, [](const std::string&, int, ProjectTracker& tracker) {
            return std::make_unique<FakeConnectedPeer>(tracker, Settings{});
        });
    EXPECT_EQ(code, 0);
}

}  // namespace

void registerNodeTests() {
    RUN_TEST(testRunNodeSyncOnlyWithMockPeer);
    RUN_TEST(testRunNodeWithMetricsServerEnabled);
    RUN_TEST(testRunNodeSyncSkipHeadersPath);
    RUN_TEST(testRunNodeBootstrapFailureRecordsError);
    RUN_TEST(testRunNodeHeaderRefreshNetworkSyncPath);
    RUN_TEST(testRunNodeRegtestChainName);
    RUN_TEST(testRunNodeRebuildValidatedChainFlag);
}
