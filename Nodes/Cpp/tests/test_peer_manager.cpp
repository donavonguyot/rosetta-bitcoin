#include "test_support.hpp"
#include "p2p_test_helpers.hpp"

#include "cpbitnode/chain/params.hpp"
#include "cpbitnode/config/settings.hpp"
#include "cpbitnode/db/tracker.hpp"
#include "cpbitnode/p2p/manager.hpp"
#include "cpbitnode/p2p/peer.hpp"
#include "cpbitnode/sync/headers.hpp"

#include <filesystem>
#include <memory>
#include <stdexcept>

void registerPeerManagerTests();

namespace {

using cpbitnode::chain::testnet4;
using cpbitnode::config::Settings;
using cpbitnode::db::ProjectTracker;
using cpbitnode::p2p::PeerConnection;
using cpbitnode::p2p::PeerManager;
using cpbitnode::testp2p::MockTransport;
using cpbitnode::testp2p::remoteVersionVerackFrames;

struct FakePeerState {
    bool connectCalled = false;
    bool discoverCalled = false;
    bool throwOnDiscover = false;
};

class FakePeer final : public PeerConnection {
public:
    FakePeer(PeerConnection::Options options, FakePeerState* state)
        : PeerConnection(std::move(options)), state_(state) {}

    void connect() override {
        state_->connectCalled = true;
        setTransportForTest(std::make_unique<MockTransport>());
    }

    void discoverPeers() override {
        state_->discoverCalled = true;
        if (state_->throwOnDiscover) {
            throw std::runtime_error("peer closed during getaddr");
        }
    }

    bool isConnected() const override { return true; }

    int syncHeaders() override { return 0; }

private:
    FakePeerState* state_;
};

}  // namespace

namespace {

void testConnectPeersKeepsPeerWhenDiscoverRaises() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_discovery_mgr.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    Settings settings;
    settings.maxOutboundPeers = 3;
    PeerManager mgr(testnet4(), tracker, settings);
    auto state = std::make_shared<FakePeerState>();
    state->throwOnDiscover = true;
    mgr.setPeerFactoryForTest([&](const std::string& host, int port) {
        PeerConnection::Options options;
        options.host = host;
        options.port = port;
        options.chain = &testnet4();
        options.tracker = &tracker;
        return std::make_unique<FakePeer>(std::move(options), state.get());
    });
    mgr.connectPeers({{"203.0.113.1", 48333}}, 0, true);
    EXPECT_EQ(mgr.connections().size(), 1u);
    EXPECT_TRUE(state->connectCalled);
    EXPECT_TRUE(state->discoverCalled);
}

void testBootstrapSkipsDiscoverWhenSkipGetaddr() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_skip_getaddr.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    Settings settings;
    settings.maxOutboundPeers = 3;
    settings.skipGetaddr = true;
    PeerManager mgr(testnet4(), tracker, settings);
    auto state = std::make_shared<FakePeerState>();
    mgr.setPeerFactoryForTest([&](const std::string& host, int port) {
        PeerConnection::Options options;
        options.host = host;
        options.port = port;
        options.chain = &testnet4();
        options.tracker = &tracker;
        return std::make_unique<FakePeer>(std::move(options), state.get());
    });
    mgr.bootstrap({{"203.0.113.99", 48333}});
    EXPECT_EQ(mgr.connections().size(), 1u);
    EXPECT_TRUE(!state->discoverCalled);
}

void testBootstrapManualPeersOnlyUsesManualList() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_manual_only.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    Settings settings;
    PeerManager mgr(testnet4(), tracker, settings);
    mgr.setPeerFactoryForTest([&](const std::string& host, int port) {
        PeerConnection::Options options;
        options.host = host;
        options.port = port;
        options.chain = &testnet4();
        options.tracker = &tracker;
        static FakePeerState manualState;
        return std::make_unique<FakePeer>(std::move(options), &manualState);
    });
    const std::vector<std::pair<std::string, int>> manual = {{"203.0.113.99", 48333}};
    mgr.bootstrap(manual);
    EXPECT_EQ(mgr.connections().size(), 1u);
    EXPECT_EQ(mgr.connections().front()->host(), "203.0.113.99");
}

void testSyncHeadersRetriesAcrossPeers() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_sync_headers.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    Settings settings;
    PeerManager mgr(testnet4(), tracker, settings);

    struct CountingPeer final : public PeerConnection {
        CountingPeer(PeerConnection::Options options, int* calls, bool fail)
            : PeerConnection(std::move(options)), calls_(calls), fail_(fail) {
            setTransportForTest(std::make_unique<MockTransport>());
        }
        void connect() override {}
        bool isConnected() const override { return true; }
        int syncHeaders() override {
            *calls_ += 1;
            if (fail_) {
                throw std::runtime_error("header sync failed");
            }
            return 3;
        }

    private:
        int* calls_;
        bool fail_;
    };

    int callsFirst = 0;
    int callsSecond = 0;
    int factoryIndex = 0;
    mgr.setPeerFactoryForTest([&](const std::string& host, int port) {
        PeerConnection::Options options;
        options.host = host;
        options.port = port;
        options.chain = &testnet4();
        options.tracker = &tracker;
        if (factoryIndex++ == 0) {
            return std::make_unique<CountingPeer>(std::move(options), &callsFirst, true);
        }
        return std::make_unique<CountingPeer>(std::move(options), &callsSecond, false);
    });
    mgr.connectPeers({{"203.0.113.1", 48333}, {"203.0.113.2", 48333}}, 0, false);
    const int stored = mgr.syncHeaders();
    EXPECT_EQ(stored, 3);
    EXPECT_EQ(callsFirst, 1);
    EXPECT_EQ(callsSecond, 1);
}

void testConnectPeersSkipsDuplicateEndpoint() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_dup_peer.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    Settings settings;
    settings.maxOutboundPeers = 3;
    PeerManager mgr(testnet4(), tracker, settings);
    int factoryCalls = 0;
    mgr.setPeerFactoryForTest([&](const std::string& host, int port) {
        ++factoryCalls;
        PeerConnection::Options options;
        options.host = host;
        options.port = port;
        options.chain = &testnet4();
        options.tracker = &tracker;
        return std::make_unique<FakePeer>(std::move(options), new FakePeerState());
    });
    mgr.connectPeers({{"203.0.113.7", 48333}, {"203.0.113.7", 48333}}, 0, false);
    EXPECT_EQ(mgr.connections().size(), 1u);
    EXPECT_EQ(factoryCalls, 1);
}

void testConnectPeersIncrementsBanOnHandshakeFail() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_hs_ban.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    Settings settings;
    settings.maxOutboundPeers = 2;
    PeerManager mgr(testnet4(), tracker, settings);
    mgr.setPeerFactoryForTest([&](const std::string& host, int port) {
        PeerConnection::Options options;
        options.host = host;
        options.port = port;
        options.chain = &testnet4();
        options.tracker = &tracker;
        class HandshakeFailPeer final : public PeerConnection {
        public:
            explicit HandshakeFailPeer(Options opts) : PeerConnection(std::move(opts)) {
                setTransportForTest(std::make_unique<MockTransport>());
            }
            void connect() override { PeerConnection::connect(); }
        };
        return std::make_unique<HandshakeFailPeer>(std::move(options));
    });
    mgr.connectPeers({{"203.0.113.8", 48333}}, 0, false);
    EXPECT_EQ(mgr.connections().size(), 0u);
    EXPECT_TRUE(tracker.getPeerEndpointBanScore("203.0.113.8", 48333) > 0);
}

void testBootstrapThrowsWhenAllConnectFail() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_boot_fail.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    Settings settings;
    settings.skipGetaddr = true;
    PeerManager mgr(testnet4(), tracker, settings);
    mgr.setPeerFactoryForTest([&](const std::string& host, int port) {
        PeerConnection::Options options;
        options.host = host;
        options.port = port;
        options.chain = &testnet4();
        options.tracker = &tracker;
        class HandshakeFailPeer final : public PeerConnection {
        public:
            explicit HandshakeFailPeer(Options opts) : PeerConnection(std::move(opts)) {
                setTransportForTest(std::make_unique<MockTransport>());
            }
            void connect() override { PeerConnection::connect(); }
        };
        return std::make_unique<HandshakeFailPeer>(std::move(options));
    });
    bool threw = false;
    try {
        mgr.bootstrap({{"203.0.113.9", 48333}});
    } catch (const std::runtime_error& exc) {
        threw = std::string(exc.what()).find("Could not connect") != std::string::npos;
    }
    EXPECT_TRUE(threw);
}

void testConnectPeersRespectsMaxOutbound() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_max_out.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    Settings settings;
    settings.maxOutboundPeers = 1;
    PeerManager mgr(testnet4(), tracker, settings);
    mgr.setPeerFactoryForTest([&](const std::string& host, int port) {
        PeerConnection::Options options;
        options.host = host;
        options.port = port;
        options.chain = &testnet4();
        options.tracker = &tracker;
        return std::make_unique<FakePeer>(std::move(options), new FakePeerState());
    });
    mgr.connectPeers({{"203.0.113.21", 48333}, {"203.0.113.22", 48333}}, 0, false);
    EXPECT_EQ(mgr.connections().size(), 1u);
}

void testSyncHeadersBestEffortWhenLocalHeadersCoverBlocks() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_hdr_best_effort.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    cpbitnode::sync::ensureGenesis(tracker, testnet4());
    tracker.recordHeader(1, "hash1", testnet4().genesisHash, 601);
    tracker.recordHeader(2, "hash2", "hash1", 602);
    cpbitnode::sync::repairSyncState(tracker, testnet4());

    Settings settings;
    settings.blocksTargetHeight = 2;
    PeerManager mgr(testnet4(), tracker, settings);

    struct FailingHeaderPeer final : public PeerConnection {
        FailingHeaderPeer(PeerConnection::Options options) : PeerConnection(std::move(options)) {
            setTransportForTest(std::make_unique<MockTransport>());
        }
        void connect() override {}
        bool isConnected() const override { return true; }
        int syncHeaders() override { throw std::runtime_error("header sync failed"); }
    };

    mgr.setPeerFactoryForTest([&](const std::string& host, int port) {
        PeerConnection::Options options;
        options.host = host;
        options.port = port;
        options.chain = &testnet4();
        options.tracker = &tracker;
        return std::make_unique<FailingHeaderPeer>(std::move(options));
    });
    mgr.connectPeers({{"203.0.113.30", 48333}}, 0, false);
    const int stored = mgr.syncHeaders(true);
    EXPECT_EQ(stored, 0);
    const auto state = tracker.getSyncState(testnet4().name);
    EXPECT_EQ((*state).at("sync_status"), "headers_current");
}

void testConnectPeersUsesRealHandshakeWhenFactoryReturnsPeerConnection() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_real_hs.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    Settings settings;
    settings.skipGetaddr = true;
    PeerManager mgr(testnet4(), tracker, settings);
    mgr.setPeerFactoryForTest([&](const std::string& host, int port) {
        PeerConnection::Options options;
        options.host = host;
        options.port = port;
        options.chain = &testnet4();
        options.tracker = &tracker;
        options.settings = settings;
        auto peer = std::make_unique<PeerConnection>(std::move(options));
        auto transport = std::make_unique<MockTransport>();
        transport->enqueueRead(remoteVersionVerackFrames(testnet4(), 42));
        peer->setTransportForTest(std::move(transport));
        return peer;
    });
    mgr.bootstrap({{"203.0.113.31", 48333}});
    EXPECT_EQ(mgr.connections().size(), 1u);
    EXPECT_TRUE(mgr.connections().front()->isConnected());
    EXPECT_TRUE(mgr.connections().front()->remoteVersion() != nullptr);
}

}  // namespace

void registerPeerManagerTests() {
    RUN_TEST(testConnectPeersKeepsPeerWhenDiscoverRaises);
    RUN_TEST(testBootstrapSkipsDiscoverWhenSkipGetaddr);
    RUN_TEST(testBootstrapManualPeersOnlyUsesManualList);
    RUN_TEST(testSyncHeadersRetriesAcrossPeers);
    RUN_TEST(testConnectPeersSkipsDuplicateEndpoint);
    RUN_TEST(testConnectPeersIncrementsBanOnHandshakeFail);
    RUN_TEST(testBootstrapThrowsWhenAllConnectFail);
    RUN_TEST(testConnectPeersRespectsMaxOutbound);
    RUN_TEST(testSyncHeadersBestEffortWhenLocalHeadersCoverBlocks);
    RUN_TEST(testConnectPeersUsesRealHandshakeWhenFactoryReturnsPeerConnection);
}
