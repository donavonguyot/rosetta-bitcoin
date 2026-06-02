#include "test_support.hpp"
#include "p2p_test_helpers.hpp"

#include "cpbitnode/chain/params.hpp"
#include "cpbitnode/config/settings.hpp"
#include "cpbitnode/db/tracker.hpp"
#include "cpbitnode/messages/address.hpp"
#include "cpbitnode/messages/handshake.hpp"
#include "cpbitnode/messages/fee_filter.hpp"
#include "cpbitnode/messages/mempool_query.hpp"
#include "cpbitnode/p2p/discovery.hpp"
#include "cpbitnode/p2p/manager.hpp"
#include "cpbitnode/wire/frame.hpp"
#include <chrono>
#include <filesystem>

void registerP2pTests();

namespace {

using cpbitnode::messages::FeeFilterMessage;
using cpbitnode::messages::GetAddrMessage;
using cpbitnode::messages::AddrMessage;
using cpbitnode::messages::MempoolRequestMessage;
using cpbitnode::messages::NetworkAddress;
using cpbitnode::messages::SendHeadersMessage;
using cpbitnode::messages::VerAckMessage;
using cpbitnode::messages::VersionMessage;
using cpbitnode::messages::NODE_NETWORK;
using cpbitnode::messages::NODE_WITNESS;
using cpbitnode::chain::testnet4;
using cpbitnode::config::Settings;
using cpbitnode::db::ProjectTracker;
using cpbitnode::p2p::PeerConnection;
using cpbitnode::p2p::PeerManager;
using cpbitnode::p2p::mergePeerCandidates;
using cpbitnode::testp2p::MockTransport;
using cpbitnode::testp2p::framedMessage;
using Clock = std::chrono::steady_clock;

void testGetAddrMessageIsEmpty() {
    EXPECT_TRUE(GetAddrMessage{}.serialize().empty());
}
void testAddrMessageRoundtrip() {
    const NetworkAddress address{NODE_NETWORK, "203.0.113.10", 48333};
    const AddrMessage message{{address}};
    const auto payload = message.serialize();
    const auto restored = AddrMessage::deserialize(payload);
    EXPECT_EQ(restored.addresses[0].ip, "203.0.113.10");
    EXPECT_EQ(restored.addresses[0].port, 48333);
}

void testRecordPeerAddressAndList() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_p2p_peers.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    tracker.recordPeerAddress("203.0.113.10", 48333, 1, "getaddr");
    tracker.recordPeerAddress("198.51.100.4", 48333, 0, "addr");
    const auto endpoints = tracker.listPeerAddressEndpoints(10);
    bool foundA = false;
    bool foundB = false;
    for (const auto& [host, port] : endpoints) {
        if (host == "203.0.113.10" && port == 48333) {
            foundA = true;
        }
        if (host == "198.51.100.4" && port == 48333) {
            foundB = true;
        }
    }
    EXPECT_TRUE(foundA);
    EXPECT_TRUE(foundB);
}

void testMergePeerCandidatesPrefersManualAndDeduplicates() {
    const auto merged = mergePeerCandidates(
        testnet4(), {{"203.0.113.1", 48333}},
        {{"203.0.113.1", 48333}, {"203.0.113.2", 48333}}, {{"127.0.0.1", 48333}}, {{"203.0.113.3", 48333}});
    EXPECT_EQ(merged.size(), 3u);
    EXPECT_EQ(merged[0].first, "203.0.113.1");
    EXPECT_EQ(merged[1].first, "203.0.113.2");
    EXPECT_EQ(merged[2].first, "203.0.113.3");
}

void testKeepaliveSendsPingAndDisconnectsStale() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_keepalive.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    PeerConnection::Options options;
    options.host = "127.0.0.1";
    options.port = 48333;
    options.chain = &testnet4();
    options.tracker = &tracker;
    options.pingIntervalSeconds = 1.0;
    options.staleTimeoutSeconds = 2.0;
    PeerConnection peer(std::move(options));
    peer.setTransportForTest(std::make_unique<MockTransport>());

    const auto now = Clock::now();
    peer.setActivityTimestampsForTest(now - std::chrono::seconds(3), now - std::chrono::seconds(3));
    bool stale = false;
    try {
        peer.keepaliveTick();
    } catch (const std::runtime_error& exc) {
        stale = std::string(exc.what()) == "Peer stale";
    }
    EXPECT_TRUE(stale);

    auto transport = std::make_unique<MockTransport>();
    const auto* transportPtr = transport.get();
    peer.setTransportForTest(std::move(transport));
    peer.setActivityTimestampsForTest(Clock::now(), Clock::now() - std::chrono::seconds(2));
    peer.keepaliveTick();
    EXPECT_EQ(transportPtr->writes().size(), 1u);
}

void testLightweightOutboundHandshakeTrueForSkipFlags() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_lw.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    Settings settings;
    settings.noHeaderRefresh = true;
    PeerConnection::Options options;
    options.host = "127.0.0.1";
    options.port = 48333;
    options.chain = &testnet4();
    options.tracker = &tracker;
    options.settings = settings;
    PeerConnection peer(std::move(options));
    EXPECT_TRUE(peer.lightweightOutboundHandshake());

    Settings settings2;
    settings2.syncSkipHeaders = true;
    PeerConnection::Options options2;
    options2.host = "127.0.0.1";
    options2.port = 48333;
    options2.chain = &testnet4();
    options2.tracker = &tracker;
    options2.settings = settings2;
    PeerConnection peer2(std::move(options2));
    EXPECT_TRUE(peer2.lightweightOutboundHandshake());
}

void testLightweightOutboundHandshakeFalseByDefault() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_lw2.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    PeerConnection::Options options;
    options.host = "127.0.0.1";
    options.port = 48333;
    options.chain = &testnet4();
    options.tracker = &tracker;
    PeerConnection peer(std::move(options));
    EXPECT_TRUE(!peer.lightweightOutboundHandshake());
}

std::vector<std::uint8_t> handshakeResponseFrames(int startHeight) {
    const NetworkAddress addr{NODE_NETWORK | NODE_WITNESS, "203.0.113.1", 48333};
    const auto remoteVersion =
        VersionMessage::build(70016, NODE_NETWORK | NODE_WITNESS, addr, addr, "/remote:0.1/", startHeight);
    std::vector<std::uint8_t> out;
    const auto versionFrame =
        framedMessage(testnet4().magic, VersionMessage::kCommand, remoteVersion.serialize());
    const auto verackFrame = framedMessage(testnet4().magic, VerAckMessage::kCommand, VerAckMessage{}.serialize());
    out.insert(out.end(), versionFrame.begin(), versionFrame.end());
    out.insert(out.end(), verackFrame.begin(), verackFrame.end());
    return out;
}

bool writeContainsCommand(const std::vector<std::vector<std::uint8_t>>& writes, const std::string& command) {
    for (const auto& frame : writes) {
        if (frame.size() >= cpbitnode::wire::kHeaderSize) {
            if (cpbitnode::wire::parseHeader(frame).command == command) {
                return true;
            }
        }
    }
    return false;
}

void testDeferredHandshakeDefersFeefilterUntilComplete() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_deferred.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    tracker.upsertSyncState(testnet4().name, 0, testnet4().genesisHash, 1, "starting");

    Settings settings;
    settings.minRelayFeerateSatVb = 1;
    PeerConnection::Options options;
    options.host = "203.0.113.88";
    options.port = 48333;
    options.chain = &testnet4();
    options.tracker = &tracker;
    options.settings = settings;
    PeerConnection peer(std::move(options));

    auto transport = std::make_unique<MockTransport>();
    const auto* transportRaw = transport.get();
    transport->enqueueRead(handshakeResponseFrames(100));
    peer.setTransportForTest(std::move(transport));
    peer.connect();

    EXPECT_TRUE(!writeContainsCommand(transportRaw->writes(), FeeFilterMessage::kCommand));
    EXPECT_TRUE(!writeContainsCommand(transportRaw->writes(), MempoolRequestMessage::kCommand));
    EXPECT_TRUE(writeContainsCommand(transportRaw->writes(), SendHeadersMessage::kCommand));

    tracker.upsertSyncState(testnet4().name, 0, testnet4().genesisHash, 1, "headers_current");
    peer.completeDeferredHandshake();
    EXPECT_TRUE(writeContainsCommand(transportRaw->writes(), FeeFilterMessage::kCommand));
    EXPECT_TRUE(writeContainsCommand(transportRaw->writes(), MempoolRequestMessage::kCommand));
}

void testPeerManagerCompleteDeferredHandshake() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_mgr_deferred.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    tracker.upsertSyncState(testnet4().name, 0, testnet4().genesisHash, 1, "headers_current");
    Settings settings;
    settings.skipGetaddr = true;
    settings.minRelayFeerateSatVb = 1;
    PeerManager mgr(testnet4(), tracker, settings);
    mgr.setPeerFactoryForTest([&](const std::string&, int) {
        class HandshakePeer final : public PeerConnection {
        public:
            explicit HandshakePeer(ProjectTracker& tracker, Settings settings)
                : PeerConnection(makeOptions(tracker, std::move(settings))) {
                auto transport = std::make_unique<MockTransport>();
                transport->enqueueRead(handshakeResponseFrames(50));
                setTransportForTest(std::move(transport));
            }

            void connect() override { PeerConnection::connect(); }

        private:
            static PeerConnection::Options makeOptions(ProjectTracker& tracker, Settings settings) {
                PeerConnection::Options options;
                options.host = "203.0.113.89";
                options.port = 48333;
                options.chain = &testnet4();
                options.tracker = &tracker;
                options.settings = settings;
                return options;
            }
        };
        return std::make_unique<HandshakePeer>(tracker, settings);
    });
    mgr.bootstrap({{"203.0.113.89", 48333}});
    EXPECT_EQ(mgr.connections().size(), 1u);
    mgr.completeDeferredHandshake();
    EXPECT_TRUE(mgr.connections()[0]->isConnected());
}

}  // namespace

void registerP2pTests() {
    RUN_TEST(testGetAddrMessageIsEmpty);
    RUN_TEST(testAddrMessageRoundtrip);
    RUN_TEST(testRecordPeerAddressAndList);
    RUN_TEST(testMergePeerCandidatesPrefersManualAndDeduplicates);
    RUN_TEST(testKeepaliveSendsPingAndDisconnectsStale);
    RUN_TEST(testLightweightOutboundHandshakeTrueForSkipFlags);
    RUN_TEST(testLightweightOutboundHandshakeFalseByDefault);
    RUN_TEST(testDeferredHandshakeDefersFeefilterUntilComplete);
    RUN_TEST(testPeerManagerCompleteDeferredHandshake);
}
