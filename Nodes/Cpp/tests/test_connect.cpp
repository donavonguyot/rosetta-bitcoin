#include "test_support.hpp"

#include "blocks_fixture.hpp"

#include "cpbitnode/chain/genesis.hpp"
#include "cpbitnode/chain/params.hpp"
#include "cpbitnode/consensus/block.hpp"
#include "cpbitnode/consensus/connect.hpp"
#include "cpbitnode/consensus/connect_test_access.hpp"
#include "cpbitnode/consensus/merkle.hpp"
#include "cpbitnode/messages/transaction.hpp"
#include "cpbitnode/db/tracker.hpp"
#include "cpbitnode/metrics.hpp"
#include "cpbitnode/storage/blocks.hpp"
#include "cpbitnode/sync/blocks.hpp"
#include "cpbitnode/sync/headers.hpp"
#include "cpbitnode/sync/validate.hpp"

#include <algorithm>
#include <filesystem>
#include <functional>
#include <optional>
#include <set>
#include <sqlite3.h>
#include <string>
#include <tuple>
#include <vector>

void registerConnectTests();

namespace {

using namespace cpbitnode;

#define EXPECT_NO_THROW(expr) \
    do { \
        try { \
            expr; \
        } catch (const std::exception& ex) { \
            std::cerr << "FAIL: " << __FILE__ << ":" << __LINE__ << " threw " << ex.what() << " for " #expr "\n"; \
            ++g_failures; \
        } \
    } while (0)

#define EXPECT_THROW(expr) \
    do { \
        bool threw = false; \
        try { \
            expr; \
        } catch (const std::exception&) { \
            threw = true; \
        } \
        if (!threw) { \
            std::cerr << "FAIL: " << __FILE__ << ":" << __LINE__ << " expected throw for " #expr "\n"; \
            ++g_failures; \
        } \
    } while (0)

#define EXPECT_THROW_MSG(expr, needle) \
    do { \
        bool threw = false; \
        try { \
            expr; \
        } catch (const std::exception& ex) { \
            threw = true; \
            const std::string msg = ex.what(); \
            if (msg.find(needle) == std::string::npos) { \
                std::cerr << "FAIL: " << __FILE__ << ":" << __LINE__ << " expected message containing \"" << needle \
                          << "\", got \"" << msg << "\"\n"; \
                ++g_failures; \
            } \
        } \
        if (!threw) { \
            std::cerr << "FAIL: " << __FILE__ << ":" << __LINE__ << " expected throw for " #expr "\n"; \
            ++g_failures; \
        } \
    } while (0)

std::vector<std::uint8_t> fromHex(const std::string& hex) {
    std::vector<std::uint8_t> out;
    out.reserve(hex.size() / 2);
    for (std::size_t index = 0; index + 1 < hex.size(); index += 2) {
        out.push_back(static_cast<std::uint8_t>(std::stoi(hex.substr(index, 2), nullptr, 16)));
    }
    return out;
}

std::vector<std::uint8_t> hashHexToInternal(const std::string& hex) {
    auto out = fromHex(hex);
    std::reverse(out.begin(), out.end());
    return out;
}

consensus::ConnectBlockOptions connectOptions(int height, const std::string& expectedPrevHex,
                                              const std::optional<std::string>& expectedHashHex = std::nullopt) {
    consensus::ConnectBlockOptions options;
    options.height = height;
    options.expectedPrev = hashHexToInternal(expectedPrevHex);
    options.chainName = chain::testnet4().name;
    if (expectedHashHex.has_value()) {
        options.expectedHash = hashHexToInternal(*expectedHashHex);
        options.hasExpectedHash = true;
    }
    return options;
}

void seedHeader(db::ProjectTracker& tracker, int height, const std::string& hashHex, const std::string& prevHex,
                int timestamp) {
    tracker.recordHeader(height, hashHex, prevHex, timestamp);
}

std::set<std::tuple<std::string, int, int, std::int64_t>> utxoSnapshot(db::ProjectTracker& tracker) {
    sqlite3_stmt* stmt = nullptr;
    sqlite3_prepare_v2(tracker.handle(), "SELECT txid, vout, height, value FROM utxos", -1, &stmt, nullptr);
    std::set<std::tuple<std::string, int, int, std::int64_t>> rows;
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        const char* txid = reinterpret_cast<const char*>(sqlite3_column_text(stmt, 0));
        rows.emplace(txid ? txid : "", sqlite3_column_int(stmt, 1), sqlite3_column_int(stmt, 2),
                     sqlite3_column_int64(stmt, 3));
    }
    sqlite3_finalize(stmt);
    return rows;
}

std::optional<std::string> undoEntriesJson(db::ProjectTracker& tracker, const std::string& chain, int height) {
    sqlite3_stmt* stmt = nullptr;
    sqlite3_prepare_v2(tracker.handle(), "SELECT entries_json FROM utxo_undo WHERE chain = ? AND height = ? LIMIT 1", -1,
                       &stmt, nullptr);
    sqlite3_bind_text(stmt, 1, chain.c_str(), -1, SQLITE_STATIC);
    sqlite3_bind_int(stmt, 2, height);
    std::optional<std::string> out;
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        const char* text = reinterpret_cast<const char*>(sqlite3_column_text(stmt, 0));
        if (text) {
            out = text;
        }
    }
    sqlite3_finalize(stmt);
    return out;
}

void testValidateBlock1() {
    const auto payload = testfixtures::readFixtureBlock(0);
    const auto genesisHash = chain::testnet4Genesis().blockHash();
    const auto expectedHash = hashHexToInternal(testfixtures::kTestnet4BlockHashes[0]);
    const auto block = sync::validateBlock(payload, genesisHash, &expectedHash);
    EXPECT_EQ(messages::blockHashHex(block.header), testfixtures::kTestnet4BlockHashes[0]);
    EXPECT_EQ(block.transactions[0].outputs[0].value, 50LL * 100'000'000);
}

void testValidateBlockRejectsBadMerkle() {
    auto payload = testfixtures::readFixtureBlock(0);
    payload[40] ^= 0xff;
    const auto genesisHash = chain::testnet4Genesis().blockHash();
    EXPECT_THROW(sync::validateBlock(payload, genesisHash));
}

void testConnectBlock1AddsUtxo() {
    const auto dbPath = (std::filesystem::temp_directory_path() / "cpbitnode_connect_block1.db").string();
    std::filesystem::remove(dbPath);
    db::ProjectTracker tracker(dbPath);
    sync::ensureGenesis(tracker, chain::testnet4());
    seedHeader(tracker, 1, testfixtures::kTestnet4BlockHashes[0], chain::testnet4().genesisHash, 1714777861);

    const auto payload = testfixtures::readFixtureBlock(0);
    const auto block = consensus::connectBlock(tracker, payload,
                                               connectOptions(1, chain::testnet4().genesisHash,
                                                              testfixtures::kTestnet4BlockHashes[0]));

    EXPECT_EQ(tracker.getValidatedHeight("testnet4"), 1);
    EXPECT_EQ(tracker.utxoCount(), 1);
    const auto coinbaseTxid = consensus::transactionTxid(block.transactions[0]);
    const auto utxo = tracker.getUtxo(coinbaseTxid, 0);
    EXPECT_TRUE(utxo.has_value());
    EXPECT_EQ(utxo->value, 50LL * 100'000'000);
    EXPECT_TRUE(utxo->coinbase);
    std::filesystem::remove(dbPath);
}

void testConnectBlockRequiresSequentialHeight() {
    const auto dbPath = (std::filesystem::temp_directory_path() / "cpbitnode_connect_order.db").string();
    std::filesystem::remove(dbPath);
    db::ProjectTracker tracker(dbPath);
    sync::ensureGenesis(tracker, chain::testnet4());
    seedHeader(tracker, 1, testfixtures::kTestnet4BlockHashes[0], chain::testnet4().genesisHash, 1714777861);

    const auto payload = testfixtures::readFixtureBlock(0);
    EXPECT_THROW_MSG(consensus::connectBlock(tracker, payload, connectOptions(2, std::string(64, '0'))),
                     "cannot connect height 2");
    std::filesystem::remove(dbPath);
}

void testConnectBlockIncrementsMetrics() {
    const auto dbPath = (std::filesystem::temp_directory_path() / "cpbitnode_connect_metrics.db").string();
    std::filesystem::remove(dbPath);
    db::ProjectTracker tracker(dbPath);
    sync::ensureGenesis(tracker, chain::testnet4());
    seedHeader(tracker, 1, testfixtures::kTestnet4BlockHashes[0], chain::testnet4().genesisHash, 1714777861);

    const auto payload = testfixtures::readFixtureBlock(0);
    consensus::connectBlock(tracker, payload,
                            connectOptions(1, chain::testnet4().genesisHash, testfixtures::kTestnet4BlockHashes[0]));
    EXPECT_EQ(metrics::readMetaInt(tracker, metrics::kMetaBlocksValidatedTotal), 1);
    std::filesystem::remove(dbPath);
}

void testDisconnectAndReconnectBlock2() {
    const auto dbPath = (std::filesystem::temp_directory_path() / "cpbitnode_disconnect_reconnect.db").string();
    std::filesystem::remove(dbPath);
    db::ProjectTracker tracker(dbPath);
    sync::ensureGenesis(tracker, chain::testnet4());

    const auto block1Payload = testfixtures::readFixtureBlock(0);
    const auto block2Payload = testfixtures::readFixtureBlock(266);

    seedHeader(tracker, 1, testfixtures::kTestnet4BlockHashes[0], chain::testnet4().genesisHash, 1714777862);
    seedHeader(tracker, 2, testfixtures::kTestnet4BlockHashes[1], testfixtures::kTestnet4BlockHashes[0], 1714777863);

    const auto blockOne = consensus::connectBlock(
        tracker, block1Payload,
        connectOptions(1, chain::testnet4().genesisHash, testfixtures::kTestnet4BlockHashes[0]));
    const auto cb1Txid = consensus::transactionTxid(blockOne.transactions[0]);
    const auto utxosAfter1 = utxoSnapshot(tracker);

    consensus::connectBlock(tracker, block2Payload,
                            connectOptions(2, testfixtures::kTestnet4BlockHashes[0], testfixtures::kTestnet4BlockHashes[1]));
    const auto snapshotAfterTwo = utxoSnapshot(tracker);

    for (const int height : {1, 2}) {
        const auto undoJson = undoEntriesJson(tracker, "testnet4", height);
        EXPECT_TRUE(undoJson.has_value());
        EXPECT_EQ(*undoJson, "[]");
    }

    EXPECT_EQ(tracker.getValidatedHeight("testnet4"), 2);
    consensus::disconnectBlock(tracker, 2, chain::testnet4());

    EXPECT_EQ(tracker.getValidatedHeight("testnet4"), 1);
    EXPECT_EQ(tracker.getValidatedHash("testnet4"), testfixtures::kTestnet4BlockHashes[0]);
    EXPECT_TRUE(!undoEntriesJson(tracker, "testnet4", 2).has_value());
    EXPECT_TRUE(undoEntriesJson(tracker, "testnet4", 1).has_value());
    EXPECT_TRUE(utxoSnapshot(tracker) == utxosAfter1);

    const auto reconnect = consensus::connectBlock(
        tracker, block2Payload,
        connectOptions(2, testfixtures::kTestnet4BlockHashes[0], testfixtures::kTestnet4BlockHashes[1]));
    EXPECT_EQ(tracker.getValidatedHeight("testnet4"), 2);
    EXPECT_TRUE(utxoSnapshot(tracker) == snapshotAfterTwo);
    EXPECT_TRUE(tracker.getUtxo(cb1Txid, 0).has_value());
    EXPECT_TRUE(!reconnect.transactions.empty());
    std::filesystem::remove(dbPath);
}

void testDisconnectBlockRequiresTip() {
    const auto dbPath = (std::filesystem::temp_directory_path() / "cpbitnode_disconnect_tip.db").string();
    std::filesystem::remove(dbPath);
    db::ProjectTracker tracker(dbPath);
    sync::ensureGenesis(tracker, chain::testnet4());
    EXPECT_THROW_MSG(consensus::disconnectBlock(tracker, 1, chain::testnet4()), "validated tip");
    std::filesystem::remove(dbPath);
}

void setupStoredBlocks1Through5(db::ProjectTracker& tracker, storage::BlockStore& localStore) {
    sync::ensureGenesis(tracker, chain::testnet4());
    std::string prevHash = chain::testnet4().genesisHash;
    for (std::size_t index = 0; index < testfixtures::kTestnet4BlockOffsets.size(); ++index) {
        const int height = static_cast<int>(index) + 1;
        const auto payload = testfixtures::readFixtureBlock(testfixtures::kTestnet4BlockOffsets[index]);
        const auto written = localStore.write(payload);
        const auto& hashHex = testfixtures::kTestnet4BlockHashes[index];
        tracker.recordHeader(height, hashHex, prevHash, 1714777860 + height);
        tracker.recordBlock(height, hashHex, written.fileName, static_cast<int>(written.offset),
                            static_cast<int>(written.size));
        prevHash = hashHex;
    }
}

void testConnectStoredBlocks1Through5() {
    const auto blocksDir = std::filesystem::temp_directory_path() / "cpbitnode_connect_stored_blocks";
    const auto dbPath = (std::filesystem::temp_directory_path() / "cpbitnode_connect_stored.db").string();
    std::filesystem::remove_all(blocksDir);
    std::filesystem::remove(dbPath);

    db::ProjectTracker tracker(dbPath);
    storage::BlockStore localStore(blocksDir, chain::testnet4().magic);
    setupStoredBlocks1Through5(tracker, localStore);

    const auto [connected, hashes] = sync::connectStoredBlocks(tracker, localStore, chain::testnet4());
    EXPECT_EQ(connected, 5);
    EXPECT_EQ(hashes.size(), 5U);
    EXPECT_EQ(tracker.getValidatedHeight("testnet4"), 5);
    EXPECT_EQ(tracker.utxoCount(), 5);

    std::filesystem::remove_all(blocksDir);
    std::filesystem::remove(dbPath);
}

void testRebuildValidatedChainRestoresUtxoSet() {
    const auto blocksDir = std::filesystem::temp_directory_path() / "cpbitnode_rebuild_chain";
    const auto dbPath = (std::filesystem::temp_directory_path() / "cpbitnode_rebuild_chain.db").string();
    std::filesystem::remove_all(blocksDir);
    std::filesystem::remove(dbPath);

    db::ProjectTracker tracker(dbPath);
    storage::BlockStore localStore(blocksDir, chain::testnet4().magic);
    setupStoredBlocks1Through5(tracker, localStore);

    sync::rebuildValidatedChain(tracker, localStore, chain::testnet4());
    EXPECT_EQ(tracker.getValidatedHeight("testnet4"), 5);
    EXPECT_EQ(tracker.utxoCount(), 5);

    sqlite3_stmt* del = nullptr;
    sqlite3_prepare_v2(tracker.handle(), "DELETE FROM utxos WHERE id = (SELECT id FROM utxos LIMIT 1)", -1, &del,
                       nullptr);
    sqlite3_step(del);
    sqlite3_finalize(del);
    EXPECT_EQ(tracker.utxoCount(), 4);

    const int rebuilt = sync::rebuildValidatedChain(tracker, localStore, chain::testnet4());
    EXPECT_EQ(rebuilt, 5);
    EXPECT_EQ(tracker.utxoCount(), 5);

    std::filesystem::remove_all(blocksDir);
    std::filesystem::remove(dbPath);
}

void testConnectBlockRejectsWrongPrevBlock() {
    const auto dbPath = (std::filesystem::temp_directory_path() / "cpbitnode_connect_wrong_prev.db").string();
    std::filesystem::remove(dbPath);
    db::ProjectTracker tracker(dbPath);
    sync::ensureGenesis(tracker, chain::testnet4());
    seedHeader(tracker, 1, testfixtures::kTestnet4BlockHashes[0], chain::testnet4().genesisHash, 1714777861);

    const auto payload = testfixtures::readFixtureBlock(0);
    auto options = connectOptions(1, std::string(64, '0'), testfixtures::kTestnet4BlockHashes[0]);
    EXPECT_THROW_MSG(consensus::connectBlock(tracker, payload, options), "prev_block mismatch");
    std::filesystem::remove(dbPath);
}

void testConnectBlockRejectsWitnessCommitmentMismatch() {
    const auto dbPath = (std::filesystem::temp_directory_path() / "cpbitnode_connect_witness.db").string();
    std::filesystem::remove(dbPath);
    db::ProjectTracker tracker(dbPath);
    sync::ensureGenesis(tracker, chain::testnet4());
    seedHeader(tracker, 1, testfixtures::kTestnet4BlockHashes[0], chain::testnet4().genesisHash, 1714777861);

    auto payload = testfixtures::readFixtureBlock(0);
    if (payload.size() > 228) {
        payload[228] ^= 0xFF;
    }
    EXPECT_THROW_MSG(consensus::connectBlock(tracker, payload,
                                             connectOptions(1, chain::testnet4().genesisHash,
                                                            testfixtures::kTestnet4BlockHashes[0])),
                     "witness commitment mismatch");
    std::filesystem::remove(dbPath);
}

std::vector<std::uint8_t> copyMutatedFixtureBlock(std::size_t offset,
                                                  const std::function<void(std::vector<std::uint8_t>&)>& mutate) {
    auto payload = testfixtures::readFixtureBlock(offset);
    mutate(payload);
    return payload;
}

void testValidateBlockRejectsPayloadTooSmall() {
    const std::vector<std::uint8_t> tiny(79, 0x00);
    const auto genesisHash = chain::testnet4Genesis().blockHash();
    EXPECT_THROW(sync::validateBlock(tiny, genesisHash));
}

void testValidateBlockRejectsPayloadTooLarge() {
    std::vector<std::uint8_t> huge(sync::kMaxBlockPayloadBytes + 1, 0x00);
    const auto genesisHash = chain::testnet4Genesis().blockHash();
    EXPECT_THROW(sync::validateBlock(huge, genesisHash));
}

void testValidateBlockRejectsHashMismatch() {
    const auto payload = testfixtures::readFixtureBlock(0);
    const auto genesisHash = chain::testnet4Genesis().blockHash();
    const auto wrongHash = hashHexToInternal(std::string(64, 'a'));
    EXPECT_THROW(sync::validateBlock(payload, genesisHash, &wrongHash));
}

void testValidateBlockRejectsEmptyTransactions() {
    const auto payload = testfixtures::readFixtureBlock(0);
    std::vector<std::uint8_t> headerOnly(payload.begin(), payload.begin() + 80);
    headerOnly.push_back(0x00);
    const auto genesisHash = chain::testnet4Genesis().blockHash();
    EXPECT_THROW_MSG(sync::validateBlock(headerOnly, genesisHash), "no transactions");
}

void testValidateHeaderRejectsWrongPrevSize() {
    const auto payload = testfixtures::readFixtureBlock(0);
    const auto block = consensus::Block::deserialize(payload);
    const std::vector<std::uint8_t> shortPrev(16, 0x00);
    EXPECT_THROW(sync::validateHeader(block.header, shortPrev));
}

void testValidateHeaderRejectsProofOfWorkFailure() {
    const auto payload = testfixtures::readFixtureBlock(0);
    auto block = consensus::Block::deserialize(payload);
    block.header.bits = 0x01010000;
    EXPECT_THROW_MSG(sync::validateHeader(block.header, block.header.prevBlock), "proof of work failed");
}

void testCompactToTargetLERejectsZeroMantissa() {
    bool threw = false;
    try {
        sync::compactToTargetLE(0x00000000);
    } catch (const sync::HeaderValidationError&) {
        threw = true;
    }
    EXPECT_TRUE(threw);
}

void testConnectBlockRejectsHashMismatch() {
    const auto dbPath = (std::filesystem::temp_directory_path() / "cpbitnode_connect_hash.db").string();
    std::filesystem::remove(dbPath);
    db::ProjectTracker tracker(dbPath);
    sync::ensureGenesis(tracker, chain::testnet4());
    seedHeader(tracker, 1, testfixtures::kTestnet4BlockHashes[0], chain::testnet4().genesisHash, 1714777861);

    const auto payload = testfixtures::readFixtureBlock(0);
    auto options = connectOptions(1, chain::testnet4().genesisHash);
    options.expectedHash = hashHexToInternal(std::string(64, 'a'));
    options.hasExpectedHash = true;
    EXPECT_THROW_MSG(consensus::connectBlock(tracker, payload, options), "block hash mismatch");
    std::filesystem::remove(dbPath);
}

void testConnectBlockRejectsBip34Mismatch() {
    const auto dbPath = (std::filesystem::temp_directory_path() / "cpbitnode_connect_bip34.db").string();
    std::filesystem::remove(dbPath);
    db::ProjectTracker tracker(dbPath);
    sync::ensureGenesis(tracker, chain::testnet4());
    seedHeader(tracker, 1, testfixtures::kTestnet4BlockHashes[0], chain::testnet4().genesisHash, 1714777861);

    const auto payload = testfixtures::readFixtureBlock(0);
    const auto block = consensus::connectBlock(tracker, payload,
                                               connectOptions(1, chain::testnet4().genesisHash,
                                                              testfixtures::kTestnet4BlockHashes[0]));
    (void)block;
    EXPECT_THROW_MSG(consensus::connect_test_access::validateCoinbaseAtHeight(
                         consensus::Block::deserialize(payload).transactions[0], 2, 0),
                     "BIP34 height mismatch");
    std::filesystem::remove(dbPath);
}

void testConnectBlockRejectsImmatureCoinbaseSpend() {
    const auto dbPath = (std::filesystem::temp_directory_path() / "cpbitnode_connect_immature.db").string();
    std::filesystem::remove(dbPath);
    db::ProjectTracker tracker(dbPath);
    sync::ensureGenesis(tracker, chain::testnet4());
    seedHeader(tracker, 1, testfixtures::kTestnet4BlockHashes[0], chain::testnet4().genesisHash, 1714777861);

    const auto payload = testfixtures::readFixtureBlock(0);
    const auto block = consensus::connectBlock(tracker, payload,
                                               connectOptions(1, chain::testnet4().genesisHash,
                                                              testfixtures::kTestnet4BlockHashes[0]));
    const auto coinbaseTxid = consensus::transactionTxid(block.transactions[0]);

    messages::Transaction spend;
    spend.version = 1;
    spend.inputs.push_back(messages::TxIn{messages::OutPoint{coinbaseTxid, 0}, {0x00}, 0xFFFFFFFF});
    spend.outputs.push_back(messages::TxOut{1, {0x51}});

    EXPECT_THROW_MSG(consensus::connect_test_access::validateNonCoinbaseInputs(tracker, 2, spend),
                     "coinbase output not mature");
    EXPECT_EQ(tracker.utxoCount(), 1);
    std::filesystem::remove(dbPath);
}

void testConnectBlockRejectsMissingUtxo() {
    const auto dbPath = (std::filesystem::temp_directory_path() / "cpbitnode_connect_missing.db").string();
    std::filesystem::remove(dbPath);
    db::ProjectTracker tracker(dbPath);
    sync::ensureGenesis(tracker, chain::testnet4());
    seedHeader(tracker, 1, testfixtures::kTestnet4BlockHashes[0], chain::testnet4().genesisHash, 1714777861);

    const auto payload = testfixtures::readFixtureBlock(0);
    consensus::connectBlock(tracker, payload,
                            connectOptions(1, chain::testnet4().genesisHash, testfixtures::kTestnet4BlockHashes[0]));

    messages::Transaction spend;
    spend.version = 1;
    spend.inputs.push_back(messages::TxIn{messages::OutPoint{fromHex(std::string(64, '1')), 0}, {0x00}, 0xFFFFFFFF});
    spend.outputs.push_back(messages::TxOut{1, {0x51}});

    const auto before = tracker.utxoCount();
    EXPECT_THROW_MSG(consensus::connect_test_access::validateNonCoinbaseInputs(tracker, 2, spend), "missing UTXO");
    EXPECT_EQ(tracker.utxoCount(), before);
    std::filesystem::remove(dbPath);
}

void testConnectBlockRejectsCoinbaseValueExceedsSubsidy() {
    messages::Transaction coinbase;
    coinbase.inputs.push_back(messages::TxIn{{}, {0x51}, 0xFFFFFFFF});
    coinbase.outputs.push_back(messages::TxOut{50LL * 100'000'000 + 1, {0x51}});
    EXPECT_THROW_MSG(consensus::connect_test_access::validateCoinbaseAtHeight(coinbase, 1, 0),
                     "coinbase value");
}

void testDisconnectBlockRejectsGenesisHeight() {
    const auto dbPath = (std::filesystem::temp_directory_path() / "cpbitnode_disconnect_genesis.db").string();
    std::filesystem::remove(dbPath);
    db::ProjectTracker tracker(dbPath);
    sync::ensureGenesis(tracker, chain::testnet4());
    EXPECT_THROW_MSG(consensus::disconnectBlock(tracker, 0, chain::testnet4()), "cannot disconnect genesis");
    std::filesystem::remove(dbPath);
}

void testDisconnectBlockRejectsMissingUndo() {
    const auto dbPath = (std::filesystem::temp_directory_path() / "cpbitnode_disconnect_undo.db").string();
    std::filesystem::remove(dbPath);
    db::ProjectTracker tracker(dbPath);
    sync::ensureGenesis(tracker, chain::testnet4());
    seedHeader(tracker, 1, testfixtures::kTestnet4BlockHashes[0], chain::testnet4().genesisHash, 1714777861);

    const auto payload = testfixtures::readFixtureBlock(0);
    consensus::connectBlock(tracker, payload,
                            connectOptions(1, chain::testnet4().genesisHash, testfixtures::kTestnet4BlockHashes[0]));

    sqlite3_stmt* del = nullptr;
    sqlite3_prepare_v2(tracker.handle(), "DELETE FROM utxo_undo WHERE chain = 'testnet4' AND height = 1", -1, &del,
                       nullptr);
    sqlite3_step(del);
    sqlite3_finalize(del);

    EXPECT_THROW_MSG(consensus::disconnectBlock(tracker, 1, chain::testnet4()), "missing UTXO undo data");
    std::filesystem::remove(dbPath);
}

void testValidateBlockRejectsWrongPrevBlock() {
    const auto payload = testfixtures::readFixtureBlock(0);
    const auto wrongPrev = hashHexToInternal(std::string(64, '0'));
    EXPECT_THROW(sync::validateBlock(payload, wrongPrev));
}

}  // namespace

void registerConnectTests() {
    RUN_TEST(testValidateBlock1);
    RUN_TEST(testValidateBlockRejectsBadMerkle);
    RUN_TEST(testConnectBlock1AddsUtxo);
    RUN_TEST(testConnectBlockRequiresSequentialHeight);
    RUN_TEST(testConnectBlockIncrementsMetrics);
    RUN_TEST(testDisconnectAndReconnectBlock2);
    RUN_TEST(testDisconnectBlockRequiresTip);
    RUN_TEST(testConnectBlockRejectsWrongPrevBlock);
    RUN_TEST(testConnectBlockRejectsWitnessCommitmentMismatch);
    RUN_TEST(testValidateBlockRejectsWrongPrevBlock);
    RUN_TEST(testValidateBlockRejectsPayloadTooSmall);
    RUN_TEST(testValidateBlockRejectsPayloadTooLarge);
    RUN_TEST(testValidateBlockRejectsHashMismatch);
    RUN_TEST(testValidateBlockRejectsEmptyTransactions);
    RUN_TEST(testValidateHeaderRejectsWrongPrevSize);
    RUN_TEST(testValidateHeaderRejectsProofOfWorkFailure);
    RUN_TEST(testCompactToTargetLERejectsZeroMantissa);
    RUN_TEST(testConnectBlockRejectsHashMismatch);
    RUN_TEST(testConnectBlockRejectsBip34Mismatch);
    RUN_TEST(testConnectBlockRejectsImmatureCoinbaseSpend);
    RUN_TEST(testConnectBlockRejectsMissingUtxo);
    RUN_TEST(testConnectBlockRejectsCoinbaseValueExceedsSubsidy);
    RUN_TEST(testDisconnectBlockRejectsGenesisHeight);
    RUN_TEST(testDisconnectBlockRejectsMissingUndo);
    RUN_TEST(testConnectStoredBlocks1Through5);
    RUN_TEST(testRebuildValidatedChainRestoresUtxoSet);
}
