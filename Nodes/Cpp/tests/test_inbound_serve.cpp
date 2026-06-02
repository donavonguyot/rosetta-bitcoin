#include "test_support.hpp"
#include "p2p_test_helpers.hpp"

#include "cpbitnode/chain/genesis.hpp"
#include "cpbitnode/chain/params.hpp"
#include "cpbitnode/config/settings.hpp"
#include "cpbitnode/consensus/witness.hpp"
#include "cpbitnode/db/tracker.hpp"
#include "cpbitnode/messages/block.hpp"
#include "cpbitnode/messages/compact_block.hpp"
#include "cpbitnode/messages/headers.hpp"
#include "cpbitnode/messages/inventory.hpp"
#include "cpbitnode/messages/transaction.hpp"
#include "cpbitnode/mempool/mempool.hpp"
#include "cpbitnode/p2p/peer.hpp"
#include "cpbitnode/p2p/server.hpp"
#include "cpbitnode/storage/blocks.hpp"
#include "cpbitnode/sync/headers.hpp"
#include "cpbitnode/wire/frame.hpp"

#include <filesystem>
#include <iomanip>
#include <sstream>

void registerInboundServeTests();

namespace {

using cpbitnode::chain::testnet4;
using cpbitnode::config::Settings;
using cpbitnode::db::ProjectTracker;
using cpbitnode::messages::BlockHeader;
using cpbitnode::messages::GetDataMessage;
using cpbitnode::messages::GetHeadersMessage;
using cpbitnode::messages::InventoryVector;
using cpbitnode::messages::PingMessage;
using cpbitnode::messages::PongMessage;
using cpbitnode::p2p::PeerConnection;
using cpbitnode::p2p::dispatchInboundMessage;
using cpbitnode::p2p::handleInboundGetdata;
using cpbitnode::p2p::serveInboundSession;
using cpbitnode::testp2p::MockTransport;
using cpbitnode::testp2p::commandFromWrite;
using cpbitnode::testp2p::remoteVersionVerackFrames;
using cpbitnode::testp2p::writeContainsCommand;

std::string bytesToHex(std::span<const std::uint8_t> data) {
    std::ostringstream oss;
    for (const auto byte : data) {
        oss << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(byte);
    }
    return oss.str();
}

std::pair<std::vector<std::uint8_t>, BlockHeader> height1BlockWire(const BlockHeader& genesis) {
    BlockHeader h1;
    h1.version = genesis.version;
    h1.prevBlock = genesis.blockHash();
    h1.merkleRoot = std::vector<std::uint8_t>(32, 0x12);
    h1.timestamp = genesis.timestamp + 600;
    h1.bits = genesis.bits;
    h1.nonce = genesis.nonce + 1;
    return {cpbitnode::messages::serializeBlockWire(h1, {}), h1};
}

PeerConnection makeTestPeer(ProjectTracker& tracker, cpbitnode::mempool::Mempool* pool = nullptr) {
    PeerConnection::Options options;
    options.host = "127.0.0.1";
    options.port = 49200;
    options.chain = &testnet4();
    options.tracker = &tracker;
    options.settings = Settings{};
    options.mempool = pool;
    PeerConnection peer(std::move(options));
    peer.setTransportForTest(std::make_unique<MockTransport>());
    return peer;
}


void testInboundPingDispatchesPong() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_in_ping.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    auto peer = makeTestPeer(tracker);
    auto transport = std::make_unique<MockTransport>();
    const auto* transportRaw = transport.get();
    peer.setTransportForTest(std::move(transport));

    const PingMessage ping{0xABCD};
    peer.dispatchMessage(PingMessage::kCommand, ping.serialize());
    EXPECT_TRUE(writeContainsCommand(transportRaw->writes(), PongMessage::kCommand));
}

void testInboundAcceptInboundHandshakeCompletes() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_accept_ok.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    Settings settings;
    auto peer = makeTestPeer(tracker);
    auto transport = std::make_unique<MockTransport>();
    transport->enqueueRead(remoteVersionVerackFrames(testnet4(), 12));
    peer.setTransportForTest(std::move(transport));
    peer.acceptInbound();
    EXPECT_TRUE(peer.isConnected());
    EXPECT_TRUE(peer.remoteVersion() != nullptr);
}

void testInboundGetdataBlockHashMismatchNotfound() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_gd_mismatch.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    const auto genesis = cpbitnode::sync::ensureGenesis(tracker, testnet4());
    const auto [payload, h1] = height1BlockWire(genesis);

    cpbitnode::storage::BlockStore local(path.parent_path() / "blocks_gd_mm", testnet4().magic);
    const auto written = local.write(payload);
    tracker.recordHeader(1, h1.blockHashHex(), genesis.blockHashHex(), h1.timestamp, bytesToHex(h1.serialize()));
    tracker.recordBlock(1, h1.blockHashHex(), written.fileName, static_cast<int>(written.offset),
                        static_cast<int>(written.size));

    auto peer = makeTestPeer(tracker);
    auto transport = std::make_unique<MockTransport>();
    const auto* transportRaw = transport.get();
    peer.setTransportForTest(std::move(transport));

    InventoryVector iv;
    iv.type = cpbitnode::messages::MSG_BLOCK;
    iv.hash = std::vector<std::uint8_t>(32, 0xBB);
    GetDataMessage gd;
    gd.inventory.push_back(std::move(iv));
    handleInboundGetdata(peer, tracker, testnet4(), local, gd.serialize(), nullptr);
    EXPECT_EQ(transportRaw->writes().size(), 1u);
    EXPECT_EQ(commandFromWrite(transportRaw->writes()[0]), std::string(cpbitnode::messages::NotFoundMessage::kCommand));
}

void testInboundGetdataMissingBlockRecordNotfound() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_gd_norec.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    auto peer = makeTestPeer(tracker);
    auto transport = std::make_unique<MockTransport>();
    const auto* transportRaw = transport.get();
    peer.setTransportForTest(std::move(transport));
    cpbitnode::storage::BlockStore local(path.parent_path() / "blocks_gd_norec", testnet4().magic);

    InventoryVector iv;
    iv.type = cpbitnode::messages::MSG_BLOCK;
    iv.hash = std::vector<std::uint8_t>(32, 0xCC);
    GetDataMessage gd;
    gd.inventory.push_back(std::move(iv));
    handleInboundGetdata(peer, tracker, testnet4(), local, gd.serialize(), nullptr);
    EXPECT_EQ(transportRaw->writes().size(), 1u);
    EXPECT_EQ(commandFromWrite(transportRaw->writes()[0]), std::string(cpbitnode::messages::NotFoundMessage::kCommand));
}

void testInboundGetdataForwardsUnknownInventoryTypes() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_gd_fwd.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    auto peer = makeTestPeer(tracker);
    auto transport = std::make_unique<MockTransport>();
    const auto* transportRaw = transport.get();
    peer.setTransportForTest(std::move(transport));
    cpbitnode::storage::BlockStore local(path.parent_path() / "blocks_gd_fwd", testnet4().magic);

    InventoryVector iv;
    iv.type = 4;
    iv.hash = std::vector<std::uint8_t>(32, 0xDD);
    GetDataMessage gd;
    gd.inventory.push_back(std::move(iv));
    handleInboundGetdata(peer, tracker, testnet4(), local, gd.serialize(), nullptr);
    EXPECT_EQ(transportRaw->writes().size(), 0u);
}

void testServeInboundSessionHandshakeFailIncrementsBan() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_sess_ban.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    cpbitnode::storage::BlockStore local(path.parent_path() / "blocks_sess_ban", testnet4().magic);
    Settings settings;
    serveInboundSession(std::make_unique<MockTransport>(), "10.9.9.11", 8333, testnet4(), tracker, settings, local,
                        nullptr, {});
    EXPECT_TRUE(tracker.getPeerEndpointBanScore("10.9.9.11", 8333) > 0);
}

void testInboundGetdataBlockReadsBlockStore() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_gd_blk.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    const auto genesis = cpbitnode::sync::ensureGenesis(tracker, testnet4());
    const auto [payload, h1] = height1BlockWire(genesis);

    cpbitnode::storage::BlockStore local(path.parent_path() / "blocks_gd", testnet4().magic);
    const auto written = local.write(payload);
    tracker.recordHeader(1, h1.blockHashHex(), genesis.blockHashHex(), h1.timestamp, bytesToHex(h1.serialize()));
    tracker.recordBlock(1, h1.blockHashHex(), written.fileName, static_cast<int>(written.offset),
                        static_cast<int>(written.size));

    auto peer = makeTestPeer(tracker);
    auto transport = std::make_unique<MockTransport>();
    const auto* transportRaw = transport.get();
    peer.setTransportForTest(std::move(transport));

    InventoryVector iv;
    iv.type = cpbitnode::messages::MSG_BLOCK;
    iv.hash = h1.blockHash();
    GetDataMessage gd;
    gd.inventory.push_back(std::move(iv));
    handleInboundGetdata(peer, tracker, testnet4(), local, gd.serialize(), nullptr);

    bool sawBlock = false;
    for (const auto& write : transportRaw->writes()) {
        if (commandFromWrite(write) == std::string(cpbitnode::messages::BlockMessage::kCommand)) {
            sawBlock = true;
        }
    }
    EXPECT_TRUE(sawBlock);
    const auto caps = tracker.wireCapabilityMap();
    EXPECT_EQ(caps.at("serve.getdata.blocks"), 1);
}

void testInboundGetdataEmptyInventoryNoSend() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_gd_empty.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    auto peer = makeTestPeer(tracker);
    auto transport = std::make_unique<MockTransport>();
    const auto* transportRaw = transport.get();
    peer.setTransportForTest(std::move(transport));
    cpbitnode::storage::BlockStore local(path.parent_path() / "blocks_empty", testnet4().magic);
    handleInboundGetdata(peer, tracker, testnet4(), local, GetDataMessage{}.serialize(), nullptr);
    EXPECT_EQ(transportRaw->writes().size(), 0u);
}

void testInboundGetdataBlockMissingNotfound() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_gd_nf.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    auto peer = makeTestPeer(tracker);
    auto transport = std::make_unique<MockTransport>();
    const auto* transportRaw = transport.get();
    peer.setTransportForTest(std::move(transport));
    cpbitnode::storage::BlockStore local(path.parent_path() / "blocks_nf", testnet4().magic);
    InventoryVector want;
    want.type = cpbitnode::messages::MSG_WITNESS_BLOCK;
    want.hash = std::vector<std::uint8_t>(32, 0xAA);
    GetDataMessage gd;
    gd.inventory.push_back(std::move(want));
    handleInboundGetdata(peer, tracker, testnet4(), local, gd.serialize(), nullptr);
    EXPECT_EQ(transportRaw->writes().size(), 1u);
    EXPECT_EQ(commandFromWrite(transportRaw->writes()[0]), std::string(cpbitnode::messages::NotFoundMessage::kCommand));
}

void testInboundGetdataWitnessTxSerializesWithWitness() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_gd_wtx.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    cpbitnode::mempool::Mempool pool;
    cpbitnode::messages::Transaction tx;
    tx.version = 2;
    tx.inputs.push_back(cpbitnode::messages::TxIn{
        cpbitnode::messages::OutPoint{std::vector<std::uint8_t>(32, 0xDE), 2}, {}, 0xFFFFFFFF});
    tx.outputs.push_back(cpbitnode::messages::TxOut{4321, {0x51}});
    tx.lockTime = 0;
    tx.witness = {{{0xCA, 0xFE}}};
    EXPECT_TRUE(pool.add(tx));
    const auto wtid = cpbitnode::consensus::transactionWtxid(tx);

    auto peer = makeTestPeer(tracker, &pool);
    auto transport = std::make_unique<MockTransport>();
    const auto* transportRaw = transport.get();
    peer.setTransportForTest(std::move(transport));
    cpbitnode::storage::BlockStore local(path.parent_path() / "blocks_wtx", testnet4().magic);
    InventoryVector want;
    want.type = cpbitnode::messages::MSG_WITNESS_TX;
    want.hash = wtid;
    GetDataMessage gd;
    gd.inventory.push_back(std::move(want));
    handleInboundGetdata(peer, tracker, testnet4(), local, gd.serialize(), &pool);

    bool sawTx = false;
    for (const auto& write : transportRaw->writes()) {
        if (commandFromWrite(write) == std::string(cpbitnode::messages::Transaction::kCommand)) {
            sawTx = true;
            const auto header = cpbitnode::wire::parseHeader(write);
            const auto payload =
                std::span<const std::uint8_t>(write.data() + cpbitnode::wire::kHeaderSize, header.length);
            cpbitnode::messages::Transaction restored;
            std::tie(restored, std::ignore) = cpbitnode::messages::deserializeTransaction(payload);
            EXPECT_EQ(restored.witness.size(), 1u);
        }
    }
    EXPECT_TRUE(sawTx);
    EXPECT_EQ(tracker.wireCapabilityMap().at("serve.getdata.txs"), 1);
}

void testDispatchInboundGetheadersMarksCapability() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_dhdr.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    const auto genesis = cpbitnode::sync::ensureGenesis(tracker, testnet4());
    BlockHeader bh1;
    bh1.version = genesis.version;
    bh1.prevBlock = genesis.blockHash();
    bh1.merkleRoot = std::vector<std::uint8_t>(32, 0x77);
    bh1.timestamp = genesis.timestamp + 600;
    bh1.bits = genesis.bits;
    bh1.nonce = genesis.nonce + 2;
    tracker.recordHeader(1, bh1.blockHashHex(), genesis.blockHashHex(), bh1.timestamp, bytesToHex(bh1.serialize()));

    auto peer = makeTestPeer(tracker);
    auto transport = std::make_unique<MockTransport>();
    const auto* transportRaw = transport.get();
    peer.setTransportForTest(std::move(transport));
    GetHeadersMessage gh;
    gh.version = 70016;
    gh.locatorHashes = {genesis.blockHash()};
    gh.hashStop = std::vector<std::uint8_t>(32, 0x00);
    cpbitnode::storage::BlockStore local(path.parent_path() / "blocks_dhdr", testnet4().magic);
    Settings settings;
    dispatchInboundMessage(peer, tracker, testnet4(), settings, local, nullptr, GetHeadersMessage::kCommand,
                           gh.serialize());
    EXPECT_EQ(transportRaw->writes().size(), 1u);
    EXPECT_EQ(commandFromWrite(transportRaw->writes()[0]), std::string(cpbitnode::messages::HeadersMessage::kCommand));
    EXPECT_EQ(tracker.wireCapabilityMap().at("serve.getheaders"), 1);
}

void testServeInboundSessionHandshakeFailDoesNotCrash() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_sess_fail.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    cpbitnode::storage::BlockStore local(path.parent_path() / "blocks_fail", testnet4().magic);
    Settings settings;
    serveInboundSession(std::make_unique<MockTransport>(), "10.9.9.9", 8333, testnet4(), tracker, settings, local,
                        nullptr, {});
}

}  // namespace

void registerInboundServeTests() {
    RUN_TEST(testInboundPingDispatchesPong);
    RUN_TEST(testInboundAcceptInboundHandshakeCompletes);
    RUN_TEST(testInboundGetdataBlockHashMismatchNotfound);
    RUN_TEST(testInboundGetdataMissingBlockRecordNotfound);
    RUN_TEST(testInboundGetdataForwardsUnknownInventoryTypes);
    RUN_TEST(testServeInboundSessionHandshakeFailIncrementsBan);
    RUN_TEST(testInboundGetdataBlockReadsBlockStore);
    RUN_TEST(testInboundGetdataEmptyInventoryNoSend);
    RUN_TEST(testInboundGetdataBlockMissingNotfound);
    RUN_TEST(testInboundGetdataWitnessTxSerializesWithWitness);
    RUN_TEST(testDispatchInboundGetheadersMarksCapability);
    RUN_TEST(testServeInboundSessionHandshakeFailDoesNotCrash);
}
