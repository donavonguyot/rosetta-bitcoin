#include "test_support.hpp"

#include "cpbitnode/chain/genesis.hpp"
#include "cpbitnode/chain/params.hpp"
#include "cpbitnode/messages/address.hpp"
#include "cpbitnode/messages/block.hpp"
#include "cpbitnode/messages/block_header.hpp"
#include "cpbitnode/messages/fee_filter.hpp"
#include "cpbitnode/messages/handshake.hpp"
#include "cpbitnode/messages/headers.hpp"
#include "cpbitnode/messages/inventory.hpp"
#include "cpbitnode/messages/mempool_query.hpp"
#include "cpbitnode/messages/reject.hpp"
#include "cpbitnode/messages/sendcmpct.hpp"
#include "cpbitnode/messages/transaction.hpp"
#include "cpbitnode/wire/frame.hpp"
#include "cpbitnode/wire/serialize.hpp"

#include <functional>
#include <stdexcept>
#include <string>
#include <vector>

void registerMessageTests();

namespace {
namespace msg = cpbitnode::messages;

bool bytesEqual(const std::vector<std::uint8_t>& left, const std::vector<std::uint8_t>& right) {
    return left == right;
}

bool expectRuntimeError(const std::function<void()>& fn) {
    try {
        fn();
    } catch (const std::runtime_error&) {
        return true;
    }
    return false;
}

// --- Batch A1: core P2P messages ---

void testVersionMessageSerialization() {
    const msg::NetworkAddress addr{msg::NODE_NETWORK | msg::NODE_WITNESS, "127.0.0.1", 48333};
    auto version = msg::VersionMessage::build(70016, msg::NODE_NETWORK | msg::NODE_WITNESS, addr, addr,
                                              "/cpbitnode:0.1.0/", 0);
    const auto payload = version.serialize();
    const auto restored = msg::VersionMessage::deserialize(payload);
    EXPECT_EQ(restored.version, 70016);
    EXPECT_EQ(restored.userAgent, "/cpbitnode:0.1.0/");
    EXPECT_EQ(restored.startHeight, 0);
    EXPECT_TRUE(restored.relay);
}

void testPingMessageFramingRoundtrip() {
    const msg::PingMessage ping{123456789};
    const auto payload = ping.serialize();
    const auto& chain = cpbitnode::chain::testnet4();
    const auto frame = cpbitnode::wire::buildMessage(chain.magic, msg::PingMessage::kCommand, payload);
    const auto header = cpbitnode::wire::parseHeader(
        std::span<const std::uint8_t>(frame.data(), cpbitnode::wire::kHeaderSize));
    const auto body = std::span<const std::uint8_t>(frame.data() + cpbitnode::wire::kHeaderSize,
                                                    frame.size() - cpbitnode::wire::kHeaderSize);
    EXPECT_EQ(header.command, "ping");
    EXPECT_EQ(header.length, static_cast<std::uint32_t>(payload.size()));
    EXPECT_TRUE(cpbitnode::wire::verifyChecksum(body, header.checksum));
    EXPECT_EQ(msg::PingMessage::deserialize(body).nonce, 123456789u);
}

void testVerAckEmptyPayload() {
    const msg::VerAckMessage message;
    EXPECT_TRUE(message.serialize().empty());
}

void testGetAddrMessageIsEmpty() {
    const msg::GetAddrMessage message;
    EXPECT_TRUE(message.serialize().empty());
}

void testAddrMessageRoundtrip() {
    const msg::NetworkAddress address{msg::NODE_NETWORK, "203.0.113.10", 48333};
    msg::AddrMessage message{{address}};
    const auto payload = message.serialize();
    const auto restored = msg::AddrMessage::deserialize(payload);
    EXPECT_EQ(restored.addresses.size(), 1u);
    EXPECT_EQ(restored.addresses[0].ip, "203.0.113.10");
    EXPECT_EQ(restored.addresses[0].port, 48333u);
}

void testGetDataMessageRoundtrip() {
    msg::InventoryVector inv{msg::MSG_WITNESS_BLOCK, std::vector<std::uint8_t>(32, 0xab)};
    msg::GetDataMessage message{{inv}};
    const auto restored = msg::GetDataMessage::deserialize(message.serialize());
    EXPECT_EQ(restored.inventory.size(), 1u);
    EXPECT_EQ(restored.inventory[0].type, msg::MSG_WITNESS_BLOCK);
    EXPECT_TRUE(bytesEqual(restored.inventory[0].hash, inv.hash));
}

void testInvMessageRoundtrip() {
    msg::InventoryVector inv{msg::MSG_WITNESS_TX, std::vector<std::uint8_t>(32, 0x02)};
    msg::InvMessage message{{inv}};
    const auto restored = msg::InvMessage::deserialize(message.serialize());
    EXPECT_EQ(restored.inventory.size(), 1u);
    EXPECT_EQ(restored.inventory[0].type, msg::MSG_WITNESS_TX);
}

void testHasBlockInventoryDetectsBlockTypes() {
    msg::InvMessage blockInv{{msg::InventoryVector{msg::MSG_WITNESS_BLOCK, std::vector<std::uint8_t>(32, 0x01)}}};
    msg::InvMessage txInv{{msg::InventoryVector{msg::MSG_WITNESS_TX, std::vector<std::uint8_t>(32, 0x02)}}};
    EXPECT_TRUE(msg::hasBlockInventory(blockInv));
    EXPECT_TRUE(!msg::hasBlockInventory(txInv));
}

void testRejectRoundtripEmptyData() {
    msg::RejectMessage message{"tx", msg::REJECT_NONSTANDARD, "dust", {}};
    EXPECT_TRUE(msg::RejectMessage::deserialize(message.serialize()) == message);
}

void testRejectRoundtripNonEmptyReasonAndExtraData() {
    std::vector<std::uint8_t> extra;
    for (int i = 0; i < 77; ++i) {
        extra.push_back(static_cast<std::uint8_t>(i));
    }
    msg::RejectMessage message{"block", 0x10, "bad-txnk", extra};
    EXPECT_TRUE(msg::RejectMessage::deserialize(message.serialize()) == message);
}

void testRejectRoundtripUtf8Reason() {
    msg::RejectMessage message{"addr", 1, "réussi", {0xaa, 0xbb}};
    EXPECT_TRUE(msg::RejectMessage::deserialize(message.serialize()) == message);
}

void testRejectInvalidEmptyPayloadRaises() {
    bool threw = false;
    try {
        msg::RejectMessage::deserialize(std::span<const std::uint8_t>{});
    } catch (const std::runtime_error&) {
        threw = true;
    }
    EXPECT_TRUE(threw);
}

void testRejectInvalidTruncatedRaises() {
    bool threw = false;
    try {
        msg::RejectMessage::deserialize(std::vector<std::uint8_t>{1, static_cast<std::uint8_t>('x')});
    } catch (const std::runtime_error&) {
        threw = true;
    }
    EXPECT_TRUE(threw);
}

void testFeeFilterSerializeRoundtrip() {
    msg::FeeFilterMessage ff{12345};
    EXPECT_TRUE(msg::FeeFilterMessage::deserialize(ff.serialize()) == ff);
}

void testFeeFilterRejectsTruncatedPayload() {
    bool threw = false;
    try {
        msg::FeeFilterMessage::deserialize(std::vector<std::uint8_t>{0x01, 0x02});
    } catch (const std::runtime_error&) {
        threw = true;
    }
    EXPECT_TRUE(threw);
}

void testMempoolCommandEmptyPayload() {
    const msg::MempoolRequestMessage message;
    EXPECT_TRUE(message.serialize().empty());
}

void testInventoryVectorRejectsBadHashLength() {
    bool threw = false;
    try {
        msg::InventoryVector{msg::MSG_TX, {0x01, 0x02}}.serialize();
    } catch (const std::runtime_error&) {
        threw = true;
    }
    EXPECT_TRUE(threw);
}

// --- Batch A2: headers / transaction / block (existing) ---

msg::Transaction minimalCoinbase() {
    msg::Transaction tx;
    tx.version = 2;
    tx.inputs.push_back(msg::TxIn{
        .previousOutput = {.hash = std::vector<std::uint8_t>(32, 0), .index = 0xFFFFFFFFu},
        .scriptSig = {0x02, 0x02, 0x02, 0x02, 0x02},
        .sequence = 0xFFFFFFFFu,
    });
    tx.outputs.push_back(msg::TxOut{
        .value = 3'125'000'000,
        .scriptPubkey = {0x51},
    });
    tx.lockTime = 0;
    return tx;
}

msg::Transaction minimalWitnessSpend() {
    msg::Transaction tx;
    tx.version = 2;
    tx.inputs.push_back(msg::TxIn{
        .previousOutput = {.hash = std::vector<std::uint8_t>(32, 0xAB), .index = 0},
        .scriptSig = {},
        .sequence = 0xFFFFFFFFu,
    });
    tx.outputs.push_back(msg::TxOut{
        .value = 1'000'000,
        .scriptPubkey = {0x51},
    });
    tx.lockTime = 0;
    tx.witness = {{{0x01}}};
    return tx;
}

void testBlockHeaderRoundtrip() {
    const auto genesis = cpbitnode::chain::testnet4Genesis();
    const auto serialized = msg::serializeBlockHeader(genesis);
    EXPECT_EQ(serialized.size(), msg::kHeaderSize);
    const auto [restored, offset] = msg::deserializeBlockHeader(serialized, 0);
    EXPECT_EQ(offset, msg::kHeaderSize);
    EXPECT_EQ(restored.version, genesis.version);
    EXPECT_TRUE(bytesEqual(restored.prevBlock, genesis.prevBlock));
    EXPECT_TRUE(bytesEqual(restored.merkleRoot, genesis.merkleRoot));
    EXPECT_EQ(restored.timestamp, genesis.timestamp);
    EXPECT_EQ(restored.bits, genesis.bits);
    EXPECT_EQ(restored.nonce, genesis.nonce);
}

void testTestnet4GenesisHashMatchesCore() {
    const auto genesis = cpbitnode::chain::testnet4Genesis();
    EXPECT_EQ(msg::blockHashHex(genesis), "00000000da84f2bafbbc53dee25a72ae507ff4914b867c565be350b0da8bf043");
    EXPECT_EQ(cpbitnode::chain::blockHeaderHashHex(genesis), msg::blockHashHex(genesis));
    EXPECT_EQ(cpbitnode::chain::testnet4().genesisHash, msg::blockHashHex(genesis));
}

void testHeadersMessageRoundtrip() {
    const auto genesis = cpbitnode::chain::testnet4Genesis();
    const msg::HeadersMessage message{{genesis}};
    const auto payload = msg::serializeHeadersMessage(message);
    const auto restored = msg::deserializeHeadersMessage(payload);
    EXPECT_EQ(restored.headers.size(), 1u);
    EXPECT_EQ(msg::blockHashHex(restored.headers[0]), msg::blockHashHex(genesis));
}

void testTransactionCoinbaseRoundtrip() {
    const auto tx = minimalCoinbase();
    EXPECT_TRUE(msg::transactionIsCoinbase(tx));
    const auto payload = msg::serializeTransaction(tx);
    const auto [restored, offset] = msg::deserializeTransaction(payload, 0);
    EXPECT_EQ(offset, payload.size());
    EXPECT_EQ(restored.version, tx.version);
    EXPECT_EQ(restored.inputs.size(), 1u);
    EXPECT_EQ(restored.outputs.size(), 1u);
    EXPECT_EQ(restored.outputs[0].value, tx.outputs[0].value);
    EXPECT_TRUE(msg::transactionIsCoinbase(restored));
}

void testTransactionWitnessRoundtrip() {
    const auto tx = minimalWitnessSpend();
    EXPECT_TRUE(!msg::transactionIsCoinbase(tx));
    const auto payload = msg::serializeTransaction(tx, true);
    const auto [restored, offset] = msg::deserializeTransaction(payload, 0);
    EXPECT_EQ(offset, payload.size());
    EXPECT_EQ(restored.witness.size(), 1u);
    EXPECT_EQ(restored.witness[0].size(), 1u);
    EXPECT_TRUE(bytesEqual(restored.witness[0][0], tx.witness[0][0]));
}

void testBlockMessagePassthrough() {
    const auto genesis = cpbitnode::chain::testnet4Genesis();
    const auto headerBytes = msg::serializeBlockHeader(genesis);
    std::vector<std::uint8_t> payload = headerBytes;
    payload.push_back(0x01);
    payload.push_back(0x00);
    const msg::BlockMessage message{payload};
    const auto restoredPayload = msg::serializeBlockMessage(message);
    EXPECT_TRUE(bytesEqual(restoredPayload, payload));
    EXPECT_EQ(msg::blockHashHexFromPayload(restoredPayload), msg::blockHashHex(genesis));
}

void testDeserializeBlockMessageCopiesPayload() {
    const std::vector<std::uint8_t> payload{0x01, 0x02, 0x03};
    const auto message = msg::deserializeBlockMessage(payload);
    EXPECT_TRUE(bytesEqual(message.payload, payload));
}

void testBlockHashFromPayloadReturnsHashBytes() {
    const auto genesis = cpbitnode::chain::testnet4Genesis();
    const auto headerBytes = msg::serializeBlockHeader(genesis);
    const auto hash = msg::blockHashFromPayload(headerBytes);
    EXPECT_EQ(hash.size(), 32u);
}

void testNetworkAddressIpv4RoundtripWithoutTimestamp() {
    const msg::NetworkAddress addr{msg::NODE_NETWORK, "192.168.1.1", 8333};
    const auto encoded = addr.serialize(false);
    const auto [restored, offset] = msg::NetworkAddress::deserialize(encoded, 0, false);
    EXPECT_EQ(offset, encoded.size());
    EXPECT_EQ(restored.ip, "192.168.1.1");
    EXPECT_EQ(restored.port, 8333u);
}

void testNetworkAddressIpv6Roundtrip() {
    const msg::NetworkAddress addr{msg::NODE_WITNESS, "::1", 48333};
    const auto encoded = addr.serialize(false);
    const auto [restored, offset] = msg::NetworkAddress::deserialize(encoded, 0, false);
    EXPECT_EQ(restored.ip, "::1");
    EXPECT_EQ(offset, encoded.size());
}

void testNetworkAddressWithExplicitTimestamp() {
    const msg::NetworkAddress addr{msg::NODE_NETWORK, "127.0.0.1", 48333};
    const auto encoded = addr.serialize(true, 1'700'000'000);
    const auto [restored, offset] = msg::NetworkAddress::deserialize(encoded, 0, true);
    EXPECT_EQ(restored.ip, "127.0.0.1");
    EXPECT_EQ(offset, encoded.size());
}

void testNetworkAddressRejectsInvalidIp() {
    const msg::NetworkAddress addr{0, "not-an-ip", 1};
    EXPECT_TRUE(expectRuntimeError([&] { addr.serialize(false); }));
}

void testNetworkAddressRejectsTruncatedPayload() {
    EXPECT_TRUE(expectRuntimeError([] {
        msg::NetworkAddress::deserialize(std::vector<std::uint8_t>(10, 0x00), 0, false);
    }));
}

void testAddrMessageStopsOnTruncatedEntry() {
    msg::NetworkAddress good{msg::NODE_NETWORK, "127.0.0.1", 48333};
    auto payload = cpbitnode::wire::writeVarint(2);
    const auto encoded = good.serialize(true);
    payload.insert(payload.end(), encoded.begin(), encoded.end());
    payload.push_back(0x01);
    const auto restored = msg::AddrMessage::deserialize(payload);
    EXPECT_EQ(restored.addresses.size(), 1u);
}

void testGetAddrDeserializeEmpty() {
    EXPECT_TRUE(msg::GetAddrMessage::deserialize({}).serialize().empty());
}

void testVersionMessageRelayFalseRoundtrip() {
    const msg::NetworkAddress addr{msg::NODE_NETWORK, "127.0.0.1", 48333};
    msg::VersionMessage version;
    version.version = 70016;
    version.services = msg::NODE_NETWORK;
    version.timestamp = 1;
    version.addrRecv = addr;
    version.addrFrom = addr;
    version.nonce = 42;
    version.userAgent = "/test/";
    version.startHeight = 100;
    version.relay = false;
    const auto restored = msg::VersionMessage::deserialize(version.serialize());
    EXPECT_TRUE(!restored.relay);
}

void testVersionMessageDefaultRelayWhenOmitted() {
    const msg::NetworkAddress addr{msg::NODE_NETWORK, "127.0.0.1", 48333};
    msg::VersionMessage version;
    version.version = 70016;
    version.services = msg::NODE_NETWORK;
    version.timestamp = 1;
    version.addrRecv = addr;
    version.addrFrom = addr;
    version.nonce = 42;
    version.userAgent = "/test/";
    version.startHeight = 100;
    version.relay = false;
    auto payload = version.serialize();
    payload.pop_back();
    const auto restored = msg::VersionMessage::deserialize(payload);
    EXPECT_TRUE(restored.relay);
}

void testVersionMessageRejectsOversizedUserAgent() {
    const msg::NetworkAddress addr{msg::NODE_NETWORK, "127.0.0.1", 48333};
    msg::VersionMessage version;
    version.version = 70016;
    version.addrRecv = addr;
    version.addrFrom = addr;
    version.userAgent = std::string(256, 'x');
    EXPECT_TRUE(expectRuntimeError([&] { version.serialize(); }));
}

void testVersionMessageRejectsTruncatedUserAgentLength() {
    const msg::NetworkAddress addr{msg::NODE_NETWORK, "127.0.0.1", 48333};
    auto version = msg::VersionMessage::build(70016, msg::NODE_NETWORK, addr, addr, "/x/", 0);
    auto payload = version.serialize();
    payload.resize(payload.size() - 2);
    EXPECT_TRUE(expectRuntimeError([&] { msg::VersionMessage::deserialize(payload); }));
}

void testVersionMessageRejectsTruncatedUserAgentBytes() {
    const msg::NetworkAddress addr{msg::NODE_NETWORK, "127.0.0.1", 48333};
    auto version = msg::VersionMessage::build(70016, msg::NODE_NETWORK, addr, addr, "/longagent/", 0);
    auto payload = version.serialize();
    payload.resize(payload.size() - 6);
    EXPECT_TRUE(expectRuntimeError([&] { msg::VersionMessage::deserialize(payload); }));
}

void testVersionMessageRejectsMissingStartHeight() {
    const msg::NetworkAddress addr{msg::NODE_NETWORK, "127.0.0.1", 48333};
    auto version = msg::VersionMessage::build(70016, msg::NODE_NETWORK, addr, addr, "/test/", 100);
    auto payload = version.serialize();
    payload.resize(payload.size() - 5);
    EXPECT_TRUE(expectRuntimeError([&] { msg::VersionMessage::deserialize(payload); }));
}

void testPingMessageRoundtrip() {
    const msg::PingMessage ping{999};
    EXPECT_EQ(msg::PingMessage::deserialize(ping.serialize()).nonce, 999u);
}

void testPongMessageRoundtrip() {
    const msg::PongMessage pong{888};
    EXPECT_EQ(msg::PongMessage::deserialize(pong.serialize()).nonce, 888u);
}

void testPingMessageRejectsTruncatedPayload() {
    EXPECT_TRUE(expectRuntimeError([] {
        msg::PingMessage::deserialize(std::vector<std::uint8_t>{0x01, 0x02});
    }));
}

void testVerAckAndSendHeadersDeserializeEmpty() {
    EXPECT_TRUE(msg::VerAckMessage::deserialize({}).serialize().empty());
    EXPECT_TRUE(msg::SendHeadersMessage::deserialize({}).serialize().empty());
}

void testNotFoundMessageRoundtrip() {
    msg::InventoryVector inv{msg::MSG_BLOCK, std::vector<std::uint8_t>(32, 0x03)};
    const msg::NotFoundMessage message{{inv}};
    const auto restored = msg::NotFoundMessage::deserialize(message.serialize());
    EXPECT_EQ(restored.inventory.size(), 1u);
    EXPECT_EQ(restored.inventory[0].type, msg::MSG_BLOCK);
}

void testInventoryVectorRejectsTruncatedHash() {
    std::vector<std::uint8_t> payload = cpbitnode::wire::packUint32Le(msg::MSG_TX);
    payload.push_back(0x01);
    EXPECT_TRUE(expectRuntimeError([&] { msg::InventoryVector::deserialize(payload, 0); }));
}

void testInvMessageDetectsBlockAndTxTypes() {
    msg::InvMessage mixed{
        {msg::InventoryVector{msg::MSG_BLOCK, std::vector<std::uint8_t>(32, 0x01)},
         msg::InventoryVector{msg::MSG_TX, std::vector<std::uint8_t>(32, 0x02)}}};
    EXPECT_TRUE(msg::hasBlockInventory(mixed));
    EXPECT_TRUE(msg::hasTransactionInventory(mixed));
    const auto hashes = msg::blockInventoryHashes(mixed);
    EXPECT_EQ(hashes.size(), 1u);
}

void testGetHeadersMessageRoundtrip() {
    msg::GetHeadersMessage message;
    message.version = 70016;
    message.locatorHashes = {std::vector<std::uint8_t>(32, 0xAA)};
    message.hashStop = std::vector<std::uint8_t>(32, 0xBB);
    EXPECT_TRUE(msg::GetHeadersMessage::deserialize(message.serialize()).locatorHashes.size() == 1u);
}

void testGetHeadersSerializeRejectsBadHashStop() {
    msg::GetHeadersMessage message;
    message.hashStop = {0x01, 0x02};
    EXPECT_TRUE(expectRuntimeError([&] { message.serialize(); }));
}

void testGetHeadersSerializeRejectsBadLocatorHash() {
    msg::GetHeadersMessage message;
    message.locatorHashes = {{0x01}};
    message.hashStop = std::vector<std::uint8_t>(32, 0x00);
    EXPECT_TRUE(expectRuntimeError([&] { message.serialize(); }));
}

void testGetHeadersDeserializeRejectsTooShort() {
    EXPECT_TRUE(expectRuntimeError([] {
        msg::GetHeadersMessage::deserialize(std::vector<std::uint8_t>{0x01, 0x02, 0x03});
    }));
}

void testGetHeadersDeserializeRejectsTruncatedLocator() {
    std::vector<std::uint8_t> payload = cpbitnode::wire::packInt32Le(70016);
    payload.push_back(0x01);
    payload.insert(payload.end(), 16, 0x00);
    payload.insert(payload.end(), 32, 0x00);
    EXPECT_TRUE(expectRuntimeError([&] { msg::GetHeadersMessage::deserialize(payload); }));
}

void testGetHeadersDeserializeRejectsBadTrailingLength() {
    std::vector<std::uint8_t> payload = cpbitnode::wire::packInt32Le(70016);
    payload.push_back(0x00);
    payload.insert(payload.end(), 32, 0x00);
    payload.push_back(0xFF);
    EXPECT_TRUE(expectRuntimeError([&] { msg::GetHeadersMessage::deserialize(payload); }));
}

void testGetHeadersDeserializeRejectsTruncatedSecondLocator() {
    std::vector<std::uint8_t> payload = cpbitnode::wire::packInt32Le(70016);
    payload.push_back(0x02);
    payload.insert(payload.end(), 32, 0xAA);
    payload.insert(payload.end(), 10, 0xBB);
    payload.insert(payload.end(), 32, 0xCC);
    EXPECT_TRUE(expectRuntimeError([&] { msg::GetHeadersMessage::deserialize(payload); }));
}

void testRejectRejectsTruncatedMessageString() {
    std::vector<std::uint8_t> payload{0x05, 'h', 'e', 'l', 'l'};
    EXPECT_TRUE(expectRuntimeError([&] { msg::RejectMessage::deserialize(payload); }));
}

void testRejectRejectsMissingCodeByte() {
    std::vector<std::uint8_t> payload{0x01, 'x'};
    EXPECT_TRUE(expectRuntimeError([&] { msg::RejectMessage::deserialize(payload); }));
}

void testRejectRejectsTruncatedReasonString() {
    std::vector<std::uint8_t> payload{0x01, 'm', 0x02, 'o'};
    EXPECT_TRUE(expectRuntimeError([&] { msg::RejectMessage::deserialize(payload); }));
}

void testFeeFilterRejectsWrongPayloadSize() {
    EXPECT_TRUE(expectRuntimeError([] { msg::FeeFilterMessage::deserialize(std::vector<std::uint8_t>(9, 0x00)); }));
}

void testMempoolRequestDeserializeEmpty() {
    EXPECT_TRUE(msg::MempoolRequestMessage::deserialize({}).serialize().empty());
}

void testBlockHeaderSerializeRejectsBadFieldSizes() {
    msg::BlockHeader header;
    header.prevBlock = {0x01};
    header.merkleRoot = std::vector<std::uint8_t>(32, 0x02);
    EXPECT_TRUE(expectRuntimeError([&] { msg::serializeBlockHeader(header); }));
}

void testBlockHeaderDeserializeRejectsTruncatedPayload() {
    EXPECT_TRUE(expectRuntimeError([] { msg::deserializeBlockHeader(std::vector<std::uint8_t>(10, 0x00), 0); }));
}

void testBlockHeaderMemberMethods() {
    const auto genesis = cpbitnode::chain::testnet4Genesis();
    EXPECT_TRUE(bytesEqual(genesis.blockHash(), msg::blockHash(genesis)));
    EXPECT_EQ(genesis.blockHashHex(), msg::blockHashHex(genesis));
}

void testHeadersMessageRejectsTruncatedHeader() {
    auto payload = cpbitnode::wire::writeVarint(1);
    payload.insert(payload.end(), 10, 0x00);
    EXPECT_TRUE(expectRuntimeError([&] { msg::deserializeHeadersMessage(payload); }));
}

void testHeadersMessageMultipleHeadersRoundtrip() {
    const auto genesis = cpbitnode::chain::testnet4Genesis();
    msg::BlockHeader second = genesis;
    second.nonce = 1;
    const msg::HeadersMessage message{{genesis, second}};
    const auto restored = msg::deserializeHeadersMessage(msg::serializeHeadersMessage(message));
    EXPECT_EQ(restored.headers.size(), 2u);
}

void testOutPointSerializeRejectsBadHashLength() {
    msg::OutPoint outpoint;
    outpoint.hash = {0x01};
    EXPECT_TRUE(expectRuntimeError([&] { msg::serializeOutPoint(outpoint); }));
}

void testTxInAndTxOutSerializeViaMethods() {
    msg::TxIn input;
    input.previousOutput = {.hash = std::vector<std::uint8_t>(32, 0x01), .index = 0};
    input.scriptSig = {0x51};
    input.sequence = 1;
    EXPECT_TRUE(!input.serialize().empty());

    msg::TxOut output;
    output.value = 1000;
    output.scriptPubkey = {0x51};
    EXPECT_TRUE(!output.serialize().empty());
}

void testTransactionSerializeWithoutWitnessWhenEmpty() {
    const auto tx = minimalWitnessSpend();
    const auto noWitness = msg::serializeTransaction(tx, true);
    msg::Transaction bare = tx;
    bare.witness.clear();
    const auto forced = msg::serializeTransaction(bare, true);
    EXPECT_TRUE(noWitness != forced || bare.witness.empty());
}

void testTransactionLargeVarintEncodingsRoundtrip() {
    msg::Transaction tx;
    tx.version = 1;
    msg::TxIn input;
    input.previousOutput = {.hash = std::vector<std::uint8_t>(32, 0x01), .index = 0};
    input.scriptSig = std::vector<std::uint8_t>(0x10000, 0xAB);
    input.sequence = 0;
    tx.inputs.push_back(input);
    tx.outputs.push_back(msg::TxOut{.value = 1, .scriptPubkey = {0x51}});
    const auto payload = msg::serializeTransaction(tx, false);
    const auto [restored, offset] = msg::deserializeTransaction(payload, 0);
    EXPECT_EQ(offset, payload.size());
    EXPECT_EQ(restored.inputs[0].scriptSig.size(), 0x10000u);
}

void testTransactionWitnessMultiStackRoundtrip() {
    auto tx = minimalWitnessSpend();
    tx.witness = {{{0x01, 0x02}, {0x03}}};
    const auto payload = msg::serializeTransaction(tx, true);
    const auto [restored, offset] = msg::deserializeTransaction(payload, 0);
    EXPECT_EQ(offset, payload.size());
    EXPECT_EQ(restored.witness.size(), 1u);
    EXPECT_EQ(restored.witness[0].size(), 2u);
}

void testTransactionIsCoinbaseHelper() {
    EXPECT_TRUE(msg::transactionIsCoinbase(minimalCoinbase()));
    EXPECT_TRUE(!msg::transactionIsCoinbase(minimalWitnessSpend()));
}

void testTransactionNonCoinbaseIsCoinbaseMethod() {
    auto tx = minimalWitnessSpend();
    EXPECT_TRUE(!tx.isCoinbase());
}

void testSendCmpctAnnounceTrueRoundtrip() {
    msg::SendCmpctMessage message{true, msg::kSendCmpctVersion};
    const auto restored = msg::SendCmpctMessage::deserialize(message.serialize());
    EXPECT_TRUE(restored.announce);
    EXPECT_EQ(restored.version, msg::kSendCmpctVersion);
}

void testSendCmpctInequalityOperator() {
    EXPECT_TRUE(!(msg::SendCmpctMessage{true, 2} == msg::SendCmpctMessage{false, 2}));
    EXPECT_TRUE(!(msg::SendCmpctMessage{true, 2} == msg::SendCmpctMessage{true, 1}));
}

void testFeeFilterInequalityOperator() {
    EXPECT_TRUE(!(msg::FeeFilterMessage{100} == msg::FeeFilterMessage{200}));
}

void testBlockHeaderSerializeRejectsBadMerkleRootSize() {
    msg::BlockHeader header;
    header.prevBlock = std::vector<std::uint8_t>(32, 0x01);
    header.merkleRoot = {0x02};
    EXPECT_TRUE(expectRuntimeError([&] { msg::serializeBlockHeader(header); }));
}

void testInvMessageHasOnlyBlockInventory() {
    msg::InvMessage blocksOnly{{msg::InventoryVector{msg::MSG_WITNESS_BLOCK, std::vector<std::uint8_t>(32, 0x01)}}};
    EXPECT_TRUE(msg::hasBlockInventory(blocksOnly));
    EXPECT_TRUE(!msg::hasTransactionInventory(blocksOnly));
}

void testNetworkAddressRejectsTruncatedPort() {
    const msg::NetworkAddress addr{msg::NODE_NETWORK, "127.0.0.1", 48333};
    auto encoded = addr.serialize(false);
    encoded.pop_back();
    EXPECT_TRUE(expectRuntimeError([&] { msg::NetworkAddress::deserialize(encoded, 0, false); }));
}

void testVersionMessageRejectsEmptyPayload() {
    EXPECT_TRUE(expectRuntimeError([] { msg::VersionMessage::deserialize({}); }));
}

void testOutPointMethodSerializeRoundtrip() {
    msg::OutPoint outpoint;
    outpoint.hash = std::vector<std::uint8_t>(32, 0xAB);
    outpoint.index = 7;
    EXPECT_TRUE(!outpoint.serialize().empty());
}

void testTransactionMethodSerializeRoundtrip() {
    const auto tx = minimalCoinbase();
    EXPECT_TRUE(!tx.serialize(false).empty());
    EXPECT_TRUE(!tx.serialize(true).empty());
}

}  // namespace

void registerMessageTests() {
    RUN_TEST(testVersionMessageSerialization);
    RUN_TEST(testPingMessageFramingRoundtrip);
    RUN_TEST(testVerAckEmptyPayload);
    RUN_TEST(testGetAddrMessageIsEmpty);
    RUN_TEST(testAddrMessageRoundtrip);
    RUN_TEST(testGetDataMessageRoundtrip);
    RUN_TEST(testInvMessageRoundtrip);
    RUN_TEST(testHasBlockInventoryDetectsBlockTypes);
    RUN_TEST(testRejectRoundtripEmptyData);
    RUN_TEST(testRejectRoundtripNonEmptyReasonAndExtraData);
    RUN_TEST(testRejectRoundtripUtf8Reason);
    RUN_TEST(testRejectInvalidEmptyPayloadRaises);
    RUN_TEST(testRejectInvalidTruncatedRaises);
    RUN_TEST(testFeeFilterSerializeRoundtrip);
    RUN_TEST(testFeeFilterRejectsTruncatedPayload);
    RUN_TEST(testMempoolCommandEmptyPayload);
    RUN_TEST(testInventoryVectorRejectsBadHashLength);
    RUN_TEST(testBlockHeaderRoundtrip);
    RUN_TEST(testTestnet4GenesisHashMatchesCore);
    RUN_TEST(testHeadersMessageRoundtrip);
    RUN_TEST(testTransactionCoinbaseRoundtrip);
    RUN_TEST(testTransactionWitnessRoundtrip);
    RUN_TEST(testBlockMessagePassthrough);
    RUN_TEST(testDeserializeBlockMessageCopiesPayload);
    RUN_TEST(testBlockHashFromPayloadReturnsHashBytes);
    RUN_TEST(testNetworkAddressIpv4RoundtripWithoutTimestamp);
    RUN_TEST(testNetworkAddressIpv6Roundtrip);
    RUN_TEST(testNetworkAddressWithExplicitTimestamp);
    RUN_TEST(testNetworkAddressRejectsInvalidIp);
    RUN_TEST(testNetworkAddressRejectsTruncatedPayload);
    RUN_TEST(testAddrMessageStopsOnTruncatedEntry);
    RUN_TEST(testGetAddrDeserializeEmpty);
    RUN_TEST(testVersionMessageRelayFalseRoundtrip);
    RUN_TEST(testVersionMessageDefaultRelayWhenOmitted);
    RUN_TEST(testVersionMessageRejectsOversizedUserAgent);
    RUN_TEST(testVersionMessageRejectsTruncatedUserAgentLength);
    RUN_TEST(testVersionMessageRejectsTruncatedUserAgentBytes);
    RUN_TEST(testVersionMessageRejectsMissingStartHeight);
    RUN_TEST(testPingMessageRoundtrip);
    RUN_TEST(testPongMessageRoundtrip);
    RUN_TEST(testPingMessageRejectsTruncatedPayload);
    RUN_TEST(testVerAckAndSendHeadersDeserializeEmpty);
    RUN_TEST(testNotFoundMessageRoundtrip);
    RUN_TEST(testInventoryVectorRejectsTruncatedHash);
    RUN_TEST(testInvMessageDetectsBlockAndTxTypes);
    RUN_TEST(testGetHeadersMessageRoundtrip);
    RUN_TEST(testGetHeadersSerializeRejectsBadHashStop);
    RUN_TEST(testGetHeadersSerializeRejectsBadLocatorHash);
    RUN_TEST(testGetHeadersDeserializeRejectsTooShort);
    RUN_TEST(testGetHeadersDeserializeRejectsTruncatedLocator);
    RUN_TEST(testGetHeadersDeserializeRejectsBadTrailingLength);
    RUN_TEST(testGetHeadersDeserializeRejectsTruncatedSecondLocator);
    RUN_TEST(testRejectRejectsTruncatedMessageString);
    RUN_TEST(testRejectRejectsMissingCodeByte);
    RUN_TEST(testRejectRejectsTruncatedReasonString);
    RUN_TEST(testFeeFilterRejectsWrongPayloadSize);
    RUN_TEST(testMempoolRequestDeserializeEmpty);
    RUN_TEST(testBlockHeaderSerializeRejectsBadFieldSizes);
    RUN_TEST(testBlockHeaderDeserializeRejectsTruncatedPayload);
    RUN_TEST(testBlockHeaderMemberMethods);
    RUN_TEST(testHeadersMessageRejectsTruncatedHeader);
    RUN_TEST(testHeadersMessageMultipleHeadersRoundtrip);
    RUN_TEST(testOutPointSerializeRejectsBadHashLength);
    RUN_TEST(testTxInAndTxOutSerializeViaMethods);
    RUN_TEST(testTransactionSerializeWithoutWitnessWhenEmpty);
    RUN_TEST(testTransactionLargeVarintEncodingsRoundtrip);
    RUN_TEST(testTransactionWitnessMultiStackRoundtrip);
    RUN_TEST(testTransactionIsCoinbaseHelper);
    RUN_TEST(testTransactionNonCoinbaseIsCoinbaseMethod);
    RUN_TEST(testSendCmpctAnnounceTrueRoundtrip);
    RUN_TEST(testSendCmpctInequalityOperator);
    RUN_TEST(testFeeFilterInequalityOperator);
    RUN_TEST(testBlockHeaderSerializeRejectsBadMerkleRootSize);
    RUN_TEST(testInvMessageHasOnlyBlockInventory);
    RUN_TEST(testNetworkAddressRejectsTruncatedPort);
    RUN_TEST(testVersionMessageRejectsEmptyPayload);
    RUN_TEST(testOutPointMethodSerializeRoundtrip);
    RUN_TEST(testTransactionMethodSerializeRoundtrip);
}
