#include "test_support.hpp"
#include "p2p_test_helpers.hpp"

#include "cpbitnode/chain/params.hpp"
#include "cpbitnode/config/settings.hpp"
#include "cpbitnode/consensus/witness.hpp"
#include "cpbitnode/db/tracker.hpp"
#include "cpbitnode/messages/address.hpp"
#include "cpbitnode/messages/fee_filter.hpp"
#include "cpbitnode/messages/handshake.hpp"
#include "cpbitnode/messages/inventory.hpp"
#include "cpbitnode/messages/transaction.hpp"
#include "cpbitnode/mempool/mempool.hpp"
#include "cpbitnode/metrics.hpp"
#include "cpbitnode/p2p/manager.hpp"
#include "cpbitnode/p2p/peer.hpp"
#include "cpbitnode/wire/frame.hpp"

#include <filesystem>
#include <memory>

void registerPeerTxRelayTests();

namespace {

using cpbitnode::chain::testnet4;
using cpbitnode::config::Settings;
using cpbitnode::db::ProjectTracker;
using cpbitnode::messages::AddrMessage;
using cpbitnode::messages::FeeFilterMessage;
using cpbitnode::messages::GetDataMessage;
using cpbitnode::messages::InvMessage;
using cpbitnode::messages::InventoryVector;
using cpbitnode::messages::NetworkAddress;
using cpbitnode::messages::NODE_NETWORK;
using cpbitnode::messages::PingMessage;
using cpbitnode::messages::PongMessage;
using cpbitnode::messages::Transaction;
using cpbitnode::p2p::PeerConnection;
using cpbitnode::p2p::PeerManager;
using cpbitnode::testp2p::FailingWriteTransport;
using cpbitnode::testp2p::MockTransport;
using cpbitnode::testp2p::writeContainsCommand;

Transaction sampleWireTx() {
    Transaction tx;
    tx.version = 2;
    tx.inputs.push_back(
        cpbitnode::messages::TxIn{cpbitnode::messages::OutPoint{std::vector<std::uint8_t>(32, 0xDE), 1}, {}, 0xFFFFFFFF});
    tx.outputs.push_back(cpbitnode::messages::TxOut{9876, {0x51}});
    tx.lockTime = 0;
    return tx;
}

std::string commandFromWrite(const std::vector<std::uint8_t>& frameBytes) {
    return cpbitnode::wire::parseHeader(frameBytes).command;
}

PeerConnection makeRelayPeer(ProjectTracker& tracker, cpbitnode::mempool::Mempool* pool,
                             MockTransport** outTransport = nullptr) {
    PeerConnection::Options options;
    options.host = "127.0.0.1";
    options.port = 48333;
    options.chain = &testnet4();
    options.tracker = &tracker;
    options.mempool = pool;
    PeerConnection peer(std::move(options));
    auto transport = std::make_unique<MockTransport>();
    if (outTransport != nullptr) {
        *outTransport = transport.get();
    }
    peer.setTransportForTest(std::move(transport));
    return peer;
}

class ConnectedMockPeer final : public PeerConnection {
public:
    explicit ConnectedMockPeer(PeerConnection::Options options) : PeerConnection(std::move(options)) {}

    void connect() override {}
    bool isConnected() const override { return true; }
};

std::unique_ptr<PeerConnection> makeConnectedPeer(ProjectTracker& tracker, const std::string& host, int port,
                                                  MockTransport** outTransport) {
    PeerConnection::Options options;
    options.host = host;
    options.port = port;
    options.chain = &testnet4();
    options.tracker = &tracker;
    auto peer = std::make_unique<ConnectedMockPeer>(std::move(options));
    auto transport = std::make_unique<MockTransport>();
    if (outTransport != nullptr) {
        *outTransport = transport.get();
    }
    peer->setTransportForTest(std::move(transport));
    return peer;
}

void testInvHandlerSendsGetdataForMissingTx() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_inv_tx.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    cpbitnode::mempool::Mempool pool;
    MockTransport* transportRaw = nullptr;
    auto peer = makeRelayPeer(tracker, &pool, &transportRaw);

    InventoryVector item;
    item.type = cpbitnode::messages::MSG_WITNESS_TX;
    item.hash = std::vector<std::uint8_t>(32, 0x33);
    InvMessage inv;
    inv.inventory.push_back(std::move(item));
    peer.dispatchMessage(InvMessage::kCommand, inv.serialize());

    EXPECT_TRUE(!transportRaw->writes().empty());
    EXPECT_EQ(commandFromWrite(transportRaw->writes().back()), std::string(GetDataMessage::kCommand));
    EXPECT_EQ(tracker.wireCapabilityMap().at("tx.inv.recv"), 1);
    EXPECT_EQ(tracker.wireCapabilityMap().at("tx.getdata.send"), 1);
}

void testInvHandlerSkipsGetdataWhenTxInMempool() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_inv_skip.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    cpbitnode::mempool::Mempool pool;
    const auto tx = sampleWireTx();
    EXPECT_TRUE(pool.add(tx));
    const auto wtid = cpbitnode::consensus::transactionWtxid(tx);

    MockTransport* transportRaw = nullptr;
    auto peer = makeRelayPeer(tracker, &pool, &transportRaw);
    InventoryVector item;
    item.type = cpbitnode::messages::MSG_WITNESS_TX;
    item.hash = wtid;
    InvMessage inv;
    inv.inventory.push_back(std::move(item));
    peer.dispatchMessage(InvMessage::kCommand, inv.serialize());
    EXPECT_EQ(transportRaw->writes().size(), 0u);
}

void testPeerManagerRelayAnnouncesToOtherPeers() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_relay_send.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    Settings settings;
    PeerManager mgr(testnet4(), tracker, settings);

    struct DualPeerState {
        MockTransport* sourceTransport = nullptr;
        MockTransport* sinkTransport = nullptr;
    };
    auto state = std::make_shared<DualPeerState>();
    int factoryIndex = 0;
    mgr.setPeerFactoryForTest([&](const std::string& host, int port) {
        MockTransport* transportRaw = nullptr;
        auto peer = makeConnectedPeer(tracker, host, port, &transportRaw);
        if (factoryIndex++ == 0) {
            state->sourceTransport = transportRaw;
        } else {
            state->sinkTransport = transportRaw;
        }
        return peer;
    });
    mgr.connectPeers({{"127.0.0.10", 1}, {"127.0.0.11", 2}}, 0, false);
    const auto tx = sampleWireTx();
    mgr.relayAcceptedTransaction(tx, *mgr.connections().front());

    EXPECT_TRUE(state->sourceTransport != nullptr);
    EXPECT_TRUE(state->sinkTransport != nullptr);
    EXPECT_EQ(state->sourceTransport->writes().size(), 0u);
    EXPECT_TRUE(!state->sinkTransport->writes().empty());
    EXPECT_EQ(commandFromWrite(state->sinkTransport->writes().back()), std::string(InvMessage::kCommand));
    EXPECT_EQ(cpbitnode::metrics::readMetaInt(tracker, cpbitnode::metrics::kMetaTxsRelayedTotal), 1);
    EXPECT_EQ(tracker.wireCapabilityMap().at("tx.inv.send"), 1);
}

void testPeerManagerRelaySkipsWhenBelowPeerFeefilter() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_relay_ff.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    Settings settings;
    PeerManager mgr(testnet4(), tracker, settings);

    struct PeerState {
        MockTransport* transport = nullptr;
    };
    auto state = std::make_shared<PeerState>();
    mgr.setPeerFactoryForTest([&](const std::string& host, int port) {
        MockTransport* transportRaw = nullptr;
        auto peer = makeConnectedPeer(tracker, host, port, &transportRaw);
        state->transport = transportRaw;
        peer->setPeerFeeFilterSatKvbForTest(1'000'000);
        return peer;
    });
    mgr.connectPeers({{"127.0.0.20", 1}}, 0, false);
    mgr.relayAcceptedTransaction(sampleWireTx(), *mgr.connections().front());
    EXPECT_TRUE(state->transport != nullptr);
    EXPECT_EQ(state->transport->writes().size(), 0u);
}

void testPingDispatchesPong() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_ping_pong.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    MockTransport* transportRaw = nullptr;
    auto peer = makeRelayPeer(tracker, nullptr, &transportRaw);
    const PingMessage ping{0x1234};
    peer.dispatchMessage(PingMessage::kCommand, ping.serialize());
    EXPECT_TRUE(writeContainsCommand(transportRaw->writes(), PongMessage::kCommand));
}

void testPongHandlerIsNoop() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_pong_noop.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    MockTransport* transportRaw = nullptr;
    auto peer = makeRelayPeer(tracker, nullptr, &transportRaw);
    const PongMessage pong{0x5678};
    peer.dispatchMessage(PongMessage::kCommand, pong.serialize());
    EXPECT_EQ(transportRaw->writes().size(), 0u);
}

void testFeeFilterUpdatesPeerFilter() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_ff_recv.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    auto peer = makeRelayPeer(tracker, nullptr);
    const FeeFilterMessage ff{250000};
    peer.dispatchMessage(FeeFilterMessage::kCommand, ff.serialize());
    EXPECT_TRUE(peer.peerFeeFilterSatKvb().has_value());
    EXPECT_EQ(*peer.peerFeeFilterSatKvb(), 250000);
}

void testAddrMessageRecordsPeerAddresses() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_addr_recv.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    auto peer = makeRelayPeer(tracker, nullptr);
    const NetworkAddress address{NODE_NETWORK, "203.0.113.44", 48333};
    const AddrMessage message{{address}};
    peer.dispatchMessage(AddrMessage::kCommand, message.serialize());
    const auto endpoints = tracker.listPeerAddressEndpoints(10);
    bool found = false;
    for (const auto& [host, port] : endpoints) {
        if (host == "203.0.113.44" && port == 48333) {
            found = true;
        }
    }
    EXPECT_TRUE(found);
}

void testMalformedTxMessageDoesNotCrash() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_bad_tx.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    cpbitnode::mempool::Mempool pool;
    MockTransport* transportRaw = nullptr;
    auto peer = makeRelayPeer(tracker, &pool, &transportRaw);
    peer.dispatchMessage(std::string(Transaction::kCommand), std::vector<std::uint8_t>{0x01, 0x02});
    EXPECT_EQ(transportRaw->writes().size(), 0u);
}

void testInvHandlerIgnoresBlockInventoryOnly() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_inv_block.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    MockTransport* transportRaw = nullptr;
    auto peer = makeRelayPeer(tracker, nullptr, &transportRaw);
    InventoryVector item;
    item.type = cpbitnode::messages::MSG_WITNESS_BLOCK;
    item.hash = std::vector<std::uint8_t>(32, 0x44);
    InvMessage inv;
    inv.inventory.push_back(std::move(item));
    peer.dispatchMessage(InvMessage::kCommand, inv.serialize());
    EXPECT_EQ(transportRaw->writes().size(), 0u);
}

void testPeerManagerRelaySendFailureIsBestEffort() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_relay_fail.db";
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
        auto peer = std::make_unique<ConnectedMockPeer>(std::move(options));
        if (host == "127.0.0.31") {
            peer->setTransportForTest(std::make_unique<FailingWriteTransport>());
        } else {
            peer->setTransportForTest(std::make_unique<MockTransport>());
        }
        return peer;
    });
    mgr.connectPeers({{"127.0.0.30", 1}, {"127.0.0.31", 2}}, 0, false);
    mgr.relayAcceptedTransaction(sampleWireTx(), *mgr.connections().front());
}

}  // namespace

void registerPeerTxRelayTests() {
    RUN_TEST(testInvHandlerSendsGetdataForMissingTx);
    RUN_TEST(testInvHandlerSkipsGetdataWhenTxInMempool);
    RUN_TEST(testPeerManagerRelayAnnouncesToOtherPeers);
    RUN_TEST(testPeerManagerRelaySkipsWhenBelowPeerFeefilter);
    RUN_TEST(testPingDispatchesPong);
    RUN_TEST(testPongHandlerIsNoop);
    RUN_TEST(testFeeFilterUpdatesPeerFilter);
    RUN_TEST(testAddrMessageRecordsPeerAddresses);
    RUN_TEST(testMalformedTxMessageDoesNotCrash);
    RUN_TEST(testInvHandlerIgnoresBlockInventoryOnly);
    RUN_TEST(testPeerManagerRelaySendFailureIsBestEffort);
}
