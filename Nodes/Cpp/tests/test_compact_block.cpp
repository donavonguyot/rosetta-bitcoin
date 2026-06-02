#include "test_support.hpp"

#include "cpbitnode/consensus/block.hpp"
#include "cpbitnode/messages/bip152_short_txid.hpp"
#include "cpbitnode/messages/compact_block.hpp"
#include "cpbitnode/messages/sendcmpct.hpp"
#include "cpbitnode/messages/transaction.hpp"
#include "cpbitnode/wire/serialize.hpp"

#include <array>
#include <functional>
#include <stdexcept>
#include <string>
#include <vector>

void registerCompactBlockTests();

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

msg::BlockHeader dummyHeader() {
    msg::BlockHeader header;
    header.version = 536870912;
    header.prevBlock = std::vector<std::uint8_t>(32, 0x01);
    header.merkleRoot = std::vector<std::uint8_t>(32, 0x02);
    header.timestamp = 1'700'000'000;
    header.bits = 0x1D00FFFF;
    header.nonce = 0;
    return header;
}

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

msg::Transaction minimalSpend() {
    msg::Transaction tx;
    tx.version = 2;
    tx.inputs.push_back(msg::TxIn{
        .previousOutput = {.hash = std::vector<std::uint8_t>(32, 0xAB), .index = 0},
        .scriptSig = {},
        .sequence = 0xFFFFFFFFu,
    });
    tx.outputs.push_back(msg::TxOut{
        .value = 1'000,
        .scriptPubkey = {0x00},
    });
    tx.lockTime = 0;
    return tx;
}

msg::Transaction witnessSpend() {
    msg::Transaction tx;
    tx.version = 2;
    tx.inputs.push_back(msg::TxIn{
        .previousOutput = {.hash = std::vector<std::uint8_t>(32, 0xCD), .index = 3},
        .scriptSig = {0x76},
        .sequence = 1,
    });
    tx.outputs.push_back(msg::TxOut{
        .value = 50'000,
        .scriptPubkey = {0xAC},
    });
    tx.lockTime = 0;
    tx.witness = {{{0xAA, 0x55}}};
    return tx;
}

bool txWireEqual(const msg::Transaction& left, const msg::Transaction& right) {
    return msg::serializeTransaction(left, true) == msg::serializeTransaction(right, true);
}

std::vector<std::uint8_t> hexToBytes(const char* hex) {
    std::vector<std::uint8_t> out;
    for (const char* p = hex; *p != '\0'; p += 2) {
        out.push_back(static_cast<std::uint8_t>(std::stoul(std::string(p, 2), nullptr, 16)));
    }
    return out;
}

void testPresaltedShortIdVector() {
    const auto digest = std::vector<std::uint8_t>{0,  1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11,
                                                  12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23,
                                                  24, 25, 26, 27, 28, 29, 30, 31};
    const auto sid = msg::presaltedShortIdFromUint256Digest(0x0123456789ABCDEFull, 0xFEDCBA9876543210ull, digest);
    EXPECT_BYTES_EQ(sid, hexToBytes("a24d1e0bf937"));
}

void testShortIdNonceKeyVector() {
    const auto header = dummyHeader();
    const auto [k0, k1] = msg::shortIdNonceKey(header, 0xAABBCCDD11223344ull);
    EXPECT_EQ(k0, 0x5DD509070703D844ull);
    EXPECT_EQ(k1, 0xE010444E9EF7CD02ull);
}

void testBitcoinShortTransactionIdVector() {
    const auto header = dummyHeader();
    const auto spend = minimalSpend();
    const auto sid = msg::bitcoinShortTransactionId(header, 55'991, spend);
    EXPECT_BYTES_EQ(sid, hexToBytes("05da6c160501"));
}

void testSendCmpctRoundtrip() {
    msg::SendCmpctMessage message{false, msg::kSendCmpctVersion};
    EXPECT_TRUE(msg::SendCmpctMessage::deserialize(message.serialize()) == message);
}

void testCmpctblockRoundtripHeaderShortidsPrefilled() {
    const auto header = dummyHeader();
    const std::uint64_t shortIdNonce = 0xAABBCCDD11223344ull;
    const std::vector<std::vector<std::uint8_t>> shortids = {std::vector<std::uint8_t>(6, 0x01),
                                                               std::vector<std::uint8_t>(6, 0x02)};
    const auto cb = minimalCoinbase();
    const auto spend = minimalSpend();
    msg::CompactBlockMessage message{
        header,
        shortIdNonce,
        shortids,
        {
            msg::PrefilledTransaction{0, cb},
            msg::PrefilledTransaction{2, spend},
        },
    };
    const auto restored = msg::CompactBlockMessage::deserialize(message.serialize());
    EXPECT_EQ(restored.shortIdNonce, shortIdNonce);
    EXPECT_TRUE(bytesEqual(restored.header.serialize(), header.serialize()));
    EXPECT_EQ(restored.shortids.size(), 2u);
    EXPECT_TRUE(bytesEqual(restored.shortids[0], shortids[0]));
    EXPECT_TRUE(bytesEqual(restored.shortids[1], shortids[1]));
    EXPECT_EQ(restored.prefilled.size(), 2u);
    EXPECT_EQ(restored.prefilled[0].index, 0u);
    EXPECT_EQ(restored.prefilled[1].index, 2u);
    EXPECT_TRUE(txWireEqual(restored.prefilled[0].tx, cb));
    EXPECT_TRUE(txWireEqual(restored.prefilled[1].tx, spend));
}

void testCmpctblockFixtureBytesZeroShortidsOnePrefilled() {
    const auto header = dummyHeader();
    const auto tx = minimalCoinbase();
    msg::CompactBlockMessage message{header, 0, {}, {msg::PrefilledTransaction{0, tx}}};
    const auto raw = message.serialize();
    EXPECT_TRUE(bytesEqual(std::vector<std::uint8_t>(raw.begin(), raw.begin() + static_cast<std::ptrdiff_t>(msg::kHeaderSize)),
                           header.serialize()));
    EXPECT_EQ(raw[msg::kHeaderSize + 8], 0x00);
    EXPECT_EQ(raw[msg::kHeaderSize + 9], 0x01);
    const auto parsed = msg::CompactBlockMessage::deserialize(raw);
    EXPECT_TRUE(txWireEqual(parsed.prefilled[0].tx, tx));
}

void testCmpctblockRejectsTruncatedShortidRegion() {
    auto payload = dummyHeader().serialize();
    const auto nonce = cpbitnode::wire::packUint64Le(1);
    payload.insert(payload.end(), nonce.begin(), nonce.end());
    payload.push_back(0x01);
    payload.insert(payload.end(), {0x01, 0x02, 0x03});
    bool threw = false;
    try {
        msg::CompactBlockMessage::deserialize(payload);
    } catch (const std::runtime_error&) {
        threw = true;
    }
    EXPECT_TRUE(threw);
}

void testCmpctblockRejectsTrailingGarbage() {
    msg::CompactBlockMessage message{dummyHeader(), 0, {}, {msg::PrefilledTransaction{0, minimalCoinbase()}}};
    auto raw = message.serialize();
    raw.push_back(0xFF);
    bool threw = false;
    try {
        msg::CompactBlockMessage::deserialize(raw);
    } catch (const std::runtime_error&) {
        threw = true;
    }
    EXPECT_TRUE(threw);
}

void testCmpctblockSerializeRejectsBadShortidLength() {
    msg::CompactBlockMessage message{dummyHeader(), 0, {std::vector<std::uint8_t>(5, 0x01)},
                                     {msg::PrefilledTransaction{0, minimalCoinbase()}}};
    bool threw = false;
    try {
        message.serialize();
    } catch (const std::runtime_error&) {
        threw = true;
    }
    EXPECT_TRUE(threw);
}

void testGetblocktxnMessageWireRoundtrip() {
    msg::GetBlockTxnMessage message{std::vector<std::uint8_t>(32, 0xCC), {0, 2, 5}};
    EXPECT_TRUE(msg::GetBlockTxnMessage::deserialize(message.serialize()) == message);
}

void testBlocktxnMessageWireRoundtrip() {
    const auto txs = std::vector<msg::Transaction>{minimalCoinbase(), minimalSpend()};
    msg::BlockTxnMessage message{std::vector<std::uint8_t>(32, 0xDD), txs};
    const auto restored = msg::BlockTxnMessage::deserialize(message.serialize());
    EXPECT_EQ(restored.transactions.size(), 2u);
    EXPECT_TRUE(txWireEqual(restored.transactions[0], txs[0]));
    EXPECT_TRUE(txWireEqual(restored.transactions[1], txs[1]));
}

void testTryReconstructCompactBlockFromMempoolWtxids() {
    const auto header = dummyHeader();
    const std::uint64_t nonce = 55'991;
    const auto coinbase = minimalCoinbase();
    const auto spend = minimalSpend();
    const auto sid = msg::bitcoinShortTransactionId(header, nonce, spend);
    msg::CompactBlockMessage compact{header, nonce, {sid}, {msg::PrefilledTransaction{0, coinbase}}};
    const auto merged = msg::tryReconstructCompactBlock(compact, std::span<const msg::Transaction>{&spend, 1});
    EXPECT_TRUE(merged.has_value());
    EXPECT_EQ(merged->size(), 2u);
    EXPECT_TRUE(txWireEqual((*merged)[0], coinbase));
    EXPECT_TRUE(txWireEqual((*merged)[1], spend));
    EXPECT_TRUE(!msg::tryReconstructCompactBlock(compact, {}).has_value());
}

void testMissingIndexesForGetblocktxn() {
    const auto header = dummyHeader();
    const std::uint64_t nonce = 90'909;
    const auto coinbase = minimalCoinbase();
    const auto spend = minimalSpend();
    const auto sid = msg::bitcoinShortTransactionId(header, nonce, spend);
    msg::CompactBlockMessage compact{header, nonce, {sid}, {msg::PrefilledTransaction{0, coinbase}}};
    const auto poolMapOnlySpend = msg::mempoolShortIdTransactionMap(compact, std::span<const msg::Transaction>{&spend, 1});
    EXPECT_TRUE(poolMapOnlySpend.has_value());
    const auto noneMissing = msg::missingIndexesForGetblocktxn(compact, *poolMapOnlySpend);
    EXPECT_TRUE(noneMissing.has_value());
    EXPECT_TRUE(noneMissing->empty());
    const auto allMissing = msg::missingIndexesForGetblocktxn(compact, {});
    EXPECT_TRUE(allMissing.has_value());
    EXPECT_EQ(allMissing->size(), 1u);
    EXPECT_EQ((*allMissing)[0], 1u);
}

void testCompleteCompactWithBlockTransactionsFillsSidGap() {
    const auto header = dummyHeader();
    const std::uint64_t nonce = 71'717;
    const auto coinbase = minimalCoinbase();
    const auto spend = minimalSpend();
    const auto sid = msg::bitcoinShortTransactionId(header, nonce, spend);
    msg::CompactBlockMessage compact{header, nonce, {sid}, {msg::PrefilledTransaction{0, coinbase}}};
    const auto merged = msg::mempoolShortIdTransactionMap(compact, {});
    EXPECT_TRUE(merged.has_value());
    const std::vector<std::uint64_t> indexes{1};
    const std::vector<msg::Transaction> replies{spend};
    const auto txs = msg::completeCompactWithBlockTransactions(compact, *merged, indexes, replies);
    EXPECT_TRUE(txs.has_value());
    EXPECT_EQ(txs->size(), 2u);
    EXPECT_TRUE(txWireEqual((*txs)[0], coinbase));
    EXPECT_TRUE(txWireEqual((*txs)[1], spend));
}

void testCompactBlockReconstructionCoinbaseOnlyRoundtrip() {
    const auto header = dummyHeader();
    const auto coinbase = minimalCoinbase();
    msg::CompactBlockMessage compact{header, 91'235'971, {}, {msg::PrefilledTransaction{0, coinbase}}};
    const auto wire = msg::reconstructCompactBlockWire(compact, {});
    const auto block = cpbitnode::consensus::Block::deserialize(wire);
    EXPECT_TRUE(bytesEqual(block.header.serialize(), header.serialize()));
    EXPECT_EQ(block.transactions.size(), 1u);
    EXPECT_TRUE(txWireEqual(block.transactions[0], coinbase));
}

void testCompactBlockReconstructionMultitxUsingBip152Shortids() {
    const auto header = dummyHeader();
    const std::uint64_t nonce = 4'218'837;
    const auto coinbase = minimalCoinbase();
    const auto spendA = minimalSpend();
    msg::Transaction spendB;
    spendB.version = 2;
    spendB.inputs.push_back(msg::TxIn{
        .previousOutput = {.hash = std::vector<std::uint8_t>(32, 0x12), .index = 2},
        .scriptSig = {0x51},
        .sequence = 2,
    });
    spendB.outputs.push_back(msg::TxOut{.value = 20, .scriptPubkey = {0x76}});
    spendB.lockTime = 1;
    const auto sidA = msg::bitcoinShortTransactionId(header, nonce, spendA);
    const auto sidB = msg::bitcoinShortTransactionId(header, nonce, spendB);
    msg::CompactBlockMessage compact{header, nonce, {sidA, sidB}, {msg::PrefilledTransaction{0, coinbase}}};
    msg::CompactShortIdMap bySid{{sidA, spendA}, {sidB, spendB}};
    const auto txs = msg::reconstructCompactTransactions(compact, bySid);
    EXPECT_EQ(txs.size(), 3u);
    EXPECT_TRUE(txWireEqual(txs[0], coinbase));
    EXPECT_TRUE(txWireEqual(txs[1], spendA));
    EXPECT_TRUE(txWireEqual(txs[2], spendB));
}

void testCompactBlockReconstructionHolePrefillKeepsShortidSequence() {
    const auto header = dummyHeader();
    const auto cb = minimalCoinbase();
    const auto spendMid = minimalSpend();
    msg::Transaction spendLast;
    spendLast.version = 2;
    spendLast.inputs.push_back(msg::TxIn{
        .previousOutput = {.hash = std::vector<std::uint8_t>(32, 0x22), .index = 1},
        .scriptSig = {0xAA},
        .sequence = 0,
    });
    spendLast.outputs.push_back(msg::TxOut{.value = 777, .scriptPubkey = {0xBB}});
    spendLast.lockTime = 0;
    const auto sidMid = msg::bitcoinShortTransactionId(header, 99, spendMid);
    msg::CompactBlockMessage compact{
        header,
        99,
        {sidMid},
        {
            msg::PrefilledTransaction{0, cb},
            msg::PrefilledTransaction{2, spendLast},
        },
    };
    const auto txs = msg::reconstructCompactTransactions(compact, {{sidMid, spendMid}});
    EXPECT_EQ(txs.size(), 3u);
    EXPECT_TRUE(txWireEqual(txs[0], cb));
    EXPECT_TRUE(txWireEqual(txs[1], spendMid));
    EXPECT_TRUE(txWireEqual(txs[2], spendLast));
}

void testCompactBlockReconstructionRaisesOnUnknownShort() {
    const auto header = dummyHeader();
    const auto coinbase = minimalCoinbase();
    const auto sid = msg::bitcoinShortTransactionId(header, 1, minimalSpend());
    msg::CompactBlockMessage compact{header, 1, {sid}, {msg::PrefilledTransaction{0, coinbase}}};
    bool threw = false;
    try {
        msg::reconstructCompactTransactions(compact, {});
    } catch (const std::runtime_error&) {
        threw = true;
    }
    EXPECT_TRUE(threw);
}

void testCompactWitnessTxShortIdAndWireReconstructionRoundtrip() {
    const auto header = dummyHeader();
    const std::uint64_t nonce = 771'099;
    const auto coinbase = minimalCoinbase();
    const auto wtx = witnessSpend();
    const auto sid = msg::bitcoinShortTransactionId(header, nonce, wtx);
    msg::CompactBlockMessage compact{header, nonce, {sid}, {msg::PrefilledTransaction{0, coinbase}}};
    const auto blob = msg::reconstructCompactBlockWire(compact, {{sid, wtx}});
    const auto restored = cpbitnode::consensus::Block::deserialize(blob);
    EXPECT_EQ(restored.transactions.size(), 2u);
    EXPECT_TRUE(txWireEqual(restored.transactions[0], coinbase));
    EXPECT_TRUE(txWireEqual(restored.transactions[1], wtx));
}

void testPresaltedShortIdRejectsBadDigestSize() {
    EXPECT_TRUE(expectRuntimeError([] {
        msg::presaltedShortIdFromUint256Digest(0, 0, std::vector<std::uint8_t>(16, 0x00));
    }));
}

void testSendCmpctRejectsTooShort() {
    const std::vector<std::uint8_t> payload = {0x01};
    EXPECT_TRUE(expectRuntimeError([&] { msg::SendCmpctMessage::deserialize(payload); }));
}

void testSendCmpctRejectsTrailingBytes() {
    auto payload = msg::SendCmpctMessage{false, 2}.serialize();
    payload.push_back(0xFF);
    EXPECT_TRUE(expectRuntimeError([&] { msg::SendCmpctMessage::deserialize(payload); }));
}

void testCmpctblockRejectsTooShortForHeader() {
    EXPECT_TRUE(expectRuntimeError([] { msg::CompactBlockMessage::deserialize(std::vector<std::uint8_t>(80, 0x00)); }));
}

void testCmpctblockRejectsNonIncreasingPrefilledIndexOnSerialize() {
    const auto header = dummyHeader();
    const auto tx = minimalCoinbase();
    msg::CompactBlockMessage message{header, 0, {}, {msg::PrefilledTransaction{1, tx}, msg::PrefilledTransaction{1, tx}}};
    EXPECT_TRUE(expectRuntimeError([&] { message.serialize(); }));
}

void testCmpctblockSerializeRejectsUnorderedPrefilled() {
    const auto header = dummyHeader();
    const auto cb = minimalCoinbase();
    const auto spend = minimalSpend();
    msg::CompactBlockMessage message{
        header,
        0,
        {},
        {
            msg::PrefilledTransaction{2, spend},
            msg::PrefilledTransaction{0, cb},
        },
    };
    EXPECT_TRUE(expectRuntimeError([&] { message.serialize(); }));
}

void testCompactBlockRejectsDuplicatePrefilledIndex() {
    const auto header = dummyHeader();
    const auto cb = minimalCoinbase();
    const auto spend = minimalSpend();
    msg::CompactBlockMessage compact{
        header,
        0,
        {},
        {
            msg::PrefilledTransaction{0, cb},
            msg::PrefilledTransaction{0, spend},
        },
    };
    EXPECT_TRUE(expectRuntimeError([&] { msg::reconstructCompactTransactions(compact, {}); }));
}

void testCompactBlockRejectsPrefilledIndexOutOfRange() {
    const auto header = dummyHeader();
    const auto cb = minimalCoinbase();
    msg::CompactBlockMessage compact{header, 0, {std::vector<std::uint8_t>(6, 0x01)}, {msg::PrefilledTransaction{5, cb}}};
    EXPECT_TRUE(expectRuntimeError([&] { msg::reconstructCompactTransactions(compact, {}); }));
}

void testCompactBlockRejectsShortidCountMismatch() {
    const auto header = dummyHeader();
    const auto cb = minimalCoinbase();
    const auto spend = minimalSpend();
    msg::CompactBlockMessage compact{
        header,
        0,
        {std::vector<std::uint8_t>(6, 0x01)},
        {msg::PrefilledTransaction{0, cb}, msg::PrefilledTransaction{1, spend}},
    };
    EXPECT_TRUE(expectRuntimeError([&] { msg::reconstructCompactTransactions(compact, {}); }));
}

void testMempoolShortIdMapAcceptsDuplicateWtxid() {
    const auto header = dummyHeader();
    const auto spend = minimalSpend();
    const auto sid = msg::bitcoinShortTransactionId(header, 42, spend);
    msg::CompactBlockMessage compact{header, 42, {sid}, {msg::PrefilledTransaction{0, minimalCoinbase()}}};
    const std::array<msg::Transaction, 2> pool{spend, spend};
    const auto map = msg::mempoolShortIdTransactionMap(compact, pool);
    EXPECT_TRUE(map.has_value());
    EXPECT_EQ(map->size(), 1u);
}

void testMissingIndexesReturnsNulloptOnInvalidCompact() {
    const auto header = dummyHeader();
    const auto cb = minimalCoinbase();
    const auto sid = msg::bitcoinShortTransactionId(header, 1, minimalSpend());
    msg::CompactBlockMessage compact{header, 1, {sid}, {msg::PrefilledTransaction{5, cb}}};
    EXPECT_TRUE(!msg::missingIndexesForGetblocktxn(compact, {}).has_value());
}

void testTryReconstructReturnsNulloptWhenMissingShortIds() {
    const auto header = dummyHeader();
    const auto spend = minimalSpend();
    const auto sid = msg::bitcoinShortTransactionId(header, 1, spend);
    msg::CompactBlockMessage compact{header, 1, {sid}, {msg::PrefilledTransaction{0, minimalCoinbase()}}};
    EXPECT_TRUE(!msg::tryReconstructCompactBlock(compact, {}).has_value());
}

void testCompleteCompactRejectsMismatchedReplyCount() {
    const auto header = dummyHeader();
    const auto cb = minimalCoinbase();
    const auto spend = minimalSpend();
    const auto sid = msg::bitcoinShortTransactionId(header, 7, spend);
    msg::CompactBlockMessage compact{header, 7, {sid}, {msg::PrefilledTransaction{0, cb}}};
    const auto pool = msg::mempoolShortIdTransactionMap(compact, {});
    EXPECT_TRUE(pool.has_value());
    const std::vector<std::uint64_t> indexes{1};
    const std::vector<msg::Transaction> replies{spend, spend};
    EXPECT_TRUE(!msg::completeCompactWithBlockTransactions(compact, *pool, indexes, replies).has_value());
}

void testCompleteCompactRejectsUnknownIndex() {
    const auto header = dummyHeader();
    const auto cb = minimalCoinbase();
    const auto spend = minimalSpend();
    const auto sid = msg::bitcoinShortTransactionId(header, 8, spend);
    msg::CompactBlockMessage compact{header, 8, {sid}, {msg::PrefilledTransaction{0, cb}}};
    const auto pool = msg::mempoolShortIdTransactionMap(compact, {});
    EXPECT_TRUE(pool.has_value());
    const std::vector<std::uint64_t> indexes{9};
    const std::vector<msg::Transaction> replies{spend};
    EXPECT_TRUE(!msg::completeCompactWithBlockTransactions(compact, *pool, indexes, replies).has_value());
}

void testCompleteCompactRejectsMismatchedShortId() {
    const auto header = dummyHeader();
    const auto cb = minimalCoinbase();
    const auto spend = minimalSpend();
    const auto sid = msg::bitcoinShortTransactionId(header, 9, spend);
    msg::CompactBlockMessage compact{header, 9, {sid}, {msg::PrefilledTransaction{0, cb}}};
    const auto pool = msg::mempoolShortIdTransactionMap(compact, {});
    EXPECT_TRUE(pool.has_value());
    auto wrongSpend = spend;
    wrongSpend.inputs[0].sequence = 99;
    const std::vector<std::uint64_t> indexes{1};
    const std::vector<msg::Transaction> replies{wrongSpend};
    EXPECT_TRUE(!msg::completeCompactWithBlockTransactions(compact, *pool, indexes, replies).has_value());
}

void testGetblocktxnSerializeRejectsBadHash() {
    msg::GetBlockTxnMessage message{{0x01}, {0}};
    EXPECT_TRUE(expectRuntimeError([&] { message.serialize(); }));
}

void testGetblocktxnDeserializeRejectsTooShort() {
    const std::vector<std::uint8_t> payload = {0x01, 0x02};
    EXPECT_TRUE(expectRuntimeError([&] { msg::GetBlockTxnMessage::deserialize(payload); }));
}

void testGetblocktxnDeserializeRejectsTrailingBytes() {
    auto payload = msg::GetBlockTxnMessage{std::vector<std::uint8_t>(32, 0x01), {0}}.serialize();
    payload.push_back(0xFF);
    EXPECT_TRUE(expectRuntimeError([&] { msg::GetBlockTxnMessage::deserialize(payload); }));
}

void testBlocktxnSerializeRejectsBadHash() {
    msg::BlockTxnMessage message{{0x01}, {minimalCoinbase()}};
    EXPECT_TRUE(expectRuntimeError([&] { message.serialize(); }));
}

void testBlocktxnDeserializeRejectsTooShort() {
    const std::vector<std::uint8_t> payload = {0x01};
    EXPECT_TRUE(expectRuntimeError([&] { msg::BlockTxnMessage::deserialize(payload); }));
}

void testBlocktxnDeserializeRejectsTrailingBytes() {
    auto payload = msg::BlockTxnMessage{std::vector<std::uint8_t>(32, 0x02), {minimalCoinbase()}}.serialize();
    payload.push_back(0xFF);
    EXPECT_TRUE(expectRuntimeError([&] { msg::BlockTxnMessage::deserialize(payload); }));
}

void testBlocktxnWitnessModeRoundtrip() {
    const auto txs = std::vector<msg::Transaction>{minimalCoinbase(), witnessSpend()};
    msg::BlockTxnMessage message{std::vector<std::uint8_t>(32, 0xEE), txs};
    const auto restored = msg::BlockTxnMessage::deserialize(message.serialize());
    EXPECT_EQ(restored.transactions.size(), 2u);
    EXPECT_EQ(restored.transactions[1].witness.size(), 1u);
}

void testSerializeBlockWireUsesWitnessMarker() {
    const auto header = dummyHeader();
    const auto txs = std::vector<msg::Transaction>{minimalCoinbase(), witnessSpend()};
    const auto wire = msg::serializeBlockWire(header, txs);
    EXPECT_EQ(wire[msg::kHeaderSize], 0x02);
    EXPECT_EQ(wire[msg::kHeaderSize + 1], msg::kWitnessMarker0);
    EXPECT_EQ(wire[msg::kHeaderSize + 2], msg::kWitnessMarker1);
}

void testSerializeBlockWireOmitsWitnessMarkerWithoutWitness() {
    const auto header = dummyHeader();
    const std::vector<msg::Transaction> txs{minimalCoinbase(), minimalSpend()};
    const auto wire = msg::serializeBlockWire(header, txs);
    EXPECT_EQ(wire[msg::kHeaderSize], 0x02);
    EXPECT_TRUE(wire.size() <= msg::kHeaderSize + 1 ||
                wire[msg::kHeaderSize + 1] != msg::kWitnessMarker0);
}

void testTryReconstructReturnsNulloptOnInvalidCompactLayout() {
    const auto header = dummyHeader();
    const auto cb = minimalCoinbase();
    const auto spend = minimalSpend();
    msg::CompactBlockMessage compact{
        header,
        1,
        {},
        {msg::PrefilledTransaction{0, cb}, msg::PrefilledTransaction{0, spend}},
    };
    const std::array<msg::Transaction, 1> pool{spend};
    EXPECT_TRUE(!msg::tryReconstructCompactBlock(compact, pool).has_value());
}

void testGetBlockTxnEqualityOperator() {
    msg::GetBlockTxnMessage left{std::vector<std::uint8_t>(32, 0x01), {0, 1}};
    msg::GetBlockTxnMessage right{std::vector<std::uint8_t>(32, 0x02), {0, 1}};
    EXPECT_TRUE(!(left == right));
}

}  // namespace

void registerCompactBlockTests() {
    RUN_TEST(testPresaltedShortIdVector);
    RUN_TEST(testShortIdNonceKeyVector);
    RUN_TEST(testBitcoinShortTransactionIdVector);
    RUN_TEST(testSendCmpctRoundtrip);
    RUN_TEST(testCmpctblockRoundtripHeaderShortidsPrefilled);
    RUN_TEST(testCmpctblockFixtureBytesZeroShortidsOnePrefilled);
    RUN_TEST(testCmpctblockRejectsTruncatedShortidRegion);
    RUN_TEST(testCmpctblockRejectsTrailingGarbage);
    RUN_TEST(testCmpctblockSerializeRejectsBadShortidLength);
    RUN_TEST(testGetblocktxnMessageWireRoundtrip);
    RUN_TEST(testBlocktxnMessageWireRoundtrip);
    RUN_TEST(testTryReconstructCompactBlockFromMempoolWtxids);
    RUN_TEST(testMissingIndexesForGetblocktxn);
    RUN_TEST(testCompleteCompactWithBlockTransactionsFillsSidGap);
    RUN_TEST(testCompactBlockReconstructionCoinbaseOnlyRoundtrip);
    RUN_TEST(testCompactBlockReconstructionMultitxUsingBip152Shortids);
    RUN_TEST(testCompactBlockReconstructionHolePrefillKeepsShortidSequence);
    RUN_TEST(testCompactBlockReconstructionRaisesOnUnknownShort);
    RUN_TEST(testCompactWitnessTxShortIdAndWireReconstructionRoundtrip);
    RUN_TEST(testPresaltedShortIdRejectsBadDigestSize);
    RUN_TEST(testSendCmpctRejectsTooShort);
    RUN_TEST(testSendCmpctRejectsTrailingBytes);
    RUN_TEST(testCmpctblockRejectsTooShortForHeader);
    RUN_TEST(testCmpctblockRejectsNonIncreasingPrefilledIndexOnSerialize);
    RUN_TEST(testCmpctblockSerializeRejectsUnorderedPrefilled);
    RUN_TEST(testCompactBlockRejectsDuplicatePrefilledIndex);
    RUN_TEST(testCompactBlockRejectsPrefilledIndexOutOfRange);
    RUN_TEST(testCompactBlockRejectsShortidCountMismatch);
    RUN_TEST(testMempoolShortIdMapAcceptsDuplicateWtxid);
    RUN_TEST(testMissingIndexesReturnsNulloptOnInvalidCompact);
    RUN_TEST(testTryReconstructReturnsNulloptWhenMissingShortIds);
    RUN_TEST(testCompleteCompactRejectsMismatchedReplyCount);
    RUN_TEST(testCompleteCompactRejectsUnknownIndex);
    RUN_TEST(testCompleteCompactRejectsMismatchedShortId);
    RUN_TEST(testGetblocktxnSerializeRejectsBadHash);
    RUN_TEST(testGetblocktxnDeserializeRejectsTooShort);
    RUN_TEST(testGetblocktxnDeserializeRejectsTrailingBytes);
    RUN_TEST(testBlocktxnSerializeRejectsBadHash);
    RUN_TEST(testBlocktxnDeserializeRejectsTooShort);
    RUN_TEST(testBlocktxnDeserializeRejectsTrailingBytes);
    RUN_TEST(testBlocktxnWitnessModeRoundtrip);
    RUN_TEST(testSerializeBlockWireUsesWitnessMarker);
    RUN_TEST(testSerializeBlockWireOmitsWitnessMarkerWithoutWitness);
    RUN_TEST(testTryReconstructReturnsNulloptOnInvalidCompactLayout);
    RUN_TEST(testGetBlockTxnEqualityOperator);
}
