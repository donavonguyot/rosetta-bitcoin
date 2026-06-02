#include "test_support.hpp"

#include "cpbitnode/db/schema.hpp"
#include "cpbitnode/db/node_state.hpp"
#include "cpbitnode/db/tracker.hpp"

#include <filesystem>
#include <sqlite3.h>
#include <string>

void registerDbTests();

namespace {

void testSchemaInitialization() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_schema_test.db";
    std::filesystem::remove(path);
    sqlite3* db = nullptr;
    sqlite3_open(path.string().c_str(), &db);
    cpbitnode::db::initSchema(db);

    sqlite3_stmt* metaCount = nullptr;
    sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM meta", -1, &metaCount, nullptr);
    sqlite3_step(metaCount);
    EXPECT_TRUE(sqlite3_column_int(metaCount, 0) >= 1);
    sqlite3_finalize(metaCount);

    sqlite3_stmt* ver = nullptr;
    sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = 'schema_version'", -1, &ver, nullptr);
    sqlite3_step(ver);
    EXPECT_EQ(std::string(reinterpret_cast<const char*>(sqlite3_column_text(ver, 0))),
              std::to_string(cpbitnode::db::kSchemaVersion));
    sqlite3_finalize(ver);

    sqlite3_stmt* phases = nullptr;
    sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM project_phases", -1, &phases, nullptr);
    sqlite3_step(phases);
    EXPECT_EQ(sqlite3_column_int(phases, 0), 6);
    sqlite3_finalize(phases);

    sqlite3_close(db);
    std::filesystem::remove(path);
}

void testTrackerProjectPhasesAndEvents() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_tracker_test.db";
    std::filesystem::remove(path);
    cpbitnode::db::ProjectTracker tracker(path.string());
    tracker.updatePhase("phase0", "completed", "wire tests pass");
    tracker.logEvent("test", "hello", "info", "{\"x\":1}");
    tracker.upsertSyncState("testnet4", 10, std::nullopt, std::nullopt, "connected");
    tracker.recordPeerConnected("127.0.0.1", 48333, "/cpbitnode:0.1.0/");

    const std::string summary = tracker.summaryJson("testnet4");
    EXPECT_TRUE(summary.find("\"best_height\":10") != std::string::npos ||
              summary.find("\"best_height\": 10") != std::string::npos);
    EXPECT_TRUE(summary.find("\"peer_count\":1") != std::string::npos);
    EXPECT_TRUE(summary.find("phase0") != std::string::npos);
    EXPECT_TRUE(summary.find("completed") != std::string::npos);
    EXPECT_TRUE(summary.find("recent_events") != std::string::npos);
    EXPECT_TRUE(summary.find("\"wire\"") != std::string::npos);
    EXPECT_TRUE(summary.find("required_total") != std::string::npos);
}

void testTrackerHeadersIgnoreDuplicates() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_headers_test.db";
    std::filesystem::remove(path);
    cpbitnode::db::ProjectTracker tracker(path.string());
    tracker.recordHeader(0, "abc", "def", 123);
    tracker.recordHeader(0, "abc", "def", 123);
    EXPECT_EQ(tracker.headerCount(), 1);
}

void testTrackerMetaGetSet() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_meta_test.db";
    std::filesystem::remove(path);
    cpbitnode::db::ProjectTracker tracker(path.string());
    EXPECT_TRUE(!tracker.getMeta("missing").has_value());
    tracker.setMeta("foo", "bar");
    EXPECT_EQ(*tracker.getMeta("foo"), "bar");
    tracker.setMeta("foo", "baz");
    EXPECT_EQ(*tracker.getMeta("foo"), "baz");
}

void testTrackerUpdatePhaseRejectsUnknown() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_phase_bad.db";
    std::filesystem::remove(path);
    cpbitnode::db::ProjectTracker tracker(path.string());
    bool threw = false;
    try {
        tracker.updatePhase("not-a-phase", "running");
    } catch (const std::runtime_error& ex) {
        threw = true;
        EXPECT_TRUE(std::string(ex.what()).find("Unknown phase") != std::string::npos);
    }
    EXPECT_TRUE(threw);
}

void testTrackerUpdatePhaseStatusAndNotes() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_phase_update.db";
    std::filesystem::remove(path);
    cpbitnode::db::ProjectTracker tracker(path.string());
    tracker.updatePhase("phase1", "in_progress", "sync headers");
    const auto phases = tracker.listPhases();
    EXPECT_TRUE(!phases.empty());
    bool found = false;
    for (const auto& row : phases) {
        if (row.at("phase") == "phase1") {
            found = true;
            EXPECT_EQ(row.at("status"), "in_progress");
            EXPECT_EQ(row.at("notes"), "sync headers");
        }
    }
    EXPECT_TRUE(found);
    tracker.updatePhase("phase1", std::nullopt, "done");
}

void testTrackerUpsertSyncStateInsertAndMerge() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_sync_state.db";
    std::filesystem::remove(path);
    cpbitnode::db::ProjectTracker tracker(path.string());
    tracker.upsertSyncState("testnet4", 5, "abc", 10, "starting");
    const auto inserted = tracker.getSyncState("testnet4");
    EXPECT_TRUE(inserted.has_value());
    EXPECT_EQ(inserted->at("best_height"), "5");
    EXPECT_EQ(inserted->at("header_count"), "10");
    tracker.upsertSyncState("testnet4", std::nullopt, std::nullopt, std::nullopt, "connected");
    const auto merged = tracker.getSyncState("testnet4");
    EXPECT_EQ(merged->at("best_height"), "5");
    EXPECT_EQ(merged->at("sync_status"), "connected");
}

void testTrackerPeerLifecycleAndAddresses() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_peer_lifecycle.db";
    std::filesystem::remove(path);
    cpbitnode::db::ProjectTracker tracker(path.string());
    const int peerId = tracker.recordPeerConnected("10.0.0.1", 48333, "/cpbitnode:0.1.0/", "inbound");
    tracker.touchPeer(peerId);
    tracker.recordPeerDisconnected(peerId);
    tracker.recordPeerAddress("10.0.0.2", 48333, 1, "seed");
    tracker.recordPeerAddress("10.0.0.2", 48333, 9, "seed");
    EXPECT_EQ(tracker.getPeerEndpointBanScore("10.0.0.2", 48333), 0);
    EXPECT_EQ(tracker.incrementPeerBanScore("10.0.0.2", 48333, 0), 0);
    EXPECT_EQ(tracker.incrementPeerBanScore("10.0.0.2", 48333, 3, peerId), 3);
    EXPECT_EQ(tracker.incrementPeerBanScore("10.0.0.9", 48333, 2), 2);
    tracker.decayPeerBanScore("10.0.0.2", 48333, 0, peerId);
    tracker.decayPeerBanScore("10.0.0.2", 48333, 1, peerId);
    EXPECT_EQ(tracker.getPeerEndpointBanScore("10.0.0.2", 48333), 2);
    const auto endpoints = tracker.listPeerAddressEndpoints(1);
    EXPECT_EQ(endpoints.size(), 1u);
}

void testTrackerHeaderAndBlockQueries() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_header_queries.db";
    std::filesystem::remove(path);
    cpbitnode::db::ProjectTracker tracker(path.string());
    tracker.recordHeader(7, std::string(64, 'c'), std::string(64, 'b'), 999, std::string(160, 'd'));
    EXPECT_EQ(*tracker.lookupHeaderHeight(std::string(64, 'c')), 7);
    EXPECT_EQ(*tracker.getHeaderHash(7), std::string(64, 'c'));
    EXPECT_TRUE(tracker.getHeaderSerializedHex(7).has_value());
    tracker.recordBlock(7, std::string(64, 'c'), "blk00000.dat", 128, 512);
    const auto byHeight = tracker.getBlock(7);
    EXPECT_TRUE(byHeight.has_value());
    EXPECT_EQ(byHeight->size, 512);
    const auto byHash = tracker.getStoredBlockForHashHex(std::string(64, 'c'));
    EXPECT_TRUE(byHash.has_value());
    EXPECT_EQ(tracker.maxHeaderHeight(), 7);
    EXPECT_EQ(tracker.maxStoredBlockHeight(), 7);
    tracker.recordHeader(8, std::string(64, 'e'), std::string(64, 'c'), 1000);
    const auto missing = tracker.listMissingBlockHeights(4);
    EXPECT_EQ(missing.size(), 1u);
    EXPECT_EQ(missing[0], 8);
}

void testTrackerUtxoRoundtripAndUndoJournal() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_utxo_undo.db";
    std::filesystem::remove(path);
    cpbitnode::db::ProjectTracker tracker(path.string());
    const std::vector<std::uint8_t> txid(32, 0x21);
    tracker.addUtxo(txid, 0, 5, 5000, {0x51, 0x52}, true);
    const auto utxo = tracker.getUtxo(txid, 0);
    EXPECT_TRUE(utxo.has_value());
    EXPECT_TRUE(utxo->coinbase);
    cpbitnode::db::StoredUtxo undoEntry;
    undoEntry.txid = "abcd";
    undoEntry.vout = 1;
    undoEntry.height = 4;
    undoEntry.value = 100;
    undoEntry.scriptPubkey = {0x01, 0x02};
    undoEntry.coinbase = false;
    tracker.replaceUtxoUndo("testnet4", 5, {undoEntry});
    const auto restored = tracker.takeUtxoUndo("testnet4", 5);
    EXPECT_EQ(restored.size(), 1u);
    EXPECT_EQ(restored[0].txid, "abcd");
    bool threw = false;
    try {
        (void)tracker.takeUtxoUndo("testnet4", 5);
    } catch (const std::runtime_error&) {
        threw = true;
    }
    EXPECT_TRUE(threw);
    tracker.spendUtxo(txid, 0);
    EXPECT_TRUE(!tracker.getUtxo(txid, 0).has_value());
    bool missingSpend = false;
    try {
        tracker.spendUtxo(txid, 0);
    } catch (const std::runtime_error& ex) {
        missingSpend = true;
        EXPECT_TRUE(std::string(ex.what()).find("UTXO not found") != std::string::npos);
    }
    EXPECT_TRUE(missingSpend);
    bool badTxid = false;
    try {
        tracker.addUtxo(std::vector<std::uint8_t>{0x01}, 0, 1, 1, {0x51}, false);
    } catch (const std::invalid_argument&) {
        badTxid = true;
    }
    EXPECT_TRUE(badTxid);
    tracker.deleteUtxosCreatedAtHeight(99);
    tracker.resetValidatedChain("testnet4", std::string(64, '0'));
    EXPECT_EQ(tracker.getValidatedHeight("testnet4"), 0);
}

void testTrackerWireProgressAndSummary() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_wire_progress.db";
    std::filesystem::remove(path);
    cpbitnode::db::ProjectTracker tracker(path.string());
    tracker.markWireCapability("frame.build", true, "unit", "ok");
    const auto caps = tracker.listWireCapabilities();
    EXPECT_TRUE(!caps.empty());
    const auto progressJson = tracker.wireProgressJson();
    EXPECT_TRUE(progressJson.find("\"capabilities\"") != std::string::npos);
    EXPECT_TRUE(progressJson.find("\"summary\"") != std::string::npos);
    const auto summary = tracker.summaryJson("testnet4");
    EXPECT_TRUE(summary.find("\"wire\"") != std::string::npos);
    EXPECT_TRUE(summary.find("\"checkpoints\"") != std::string::npos);
    bool unknownCap = false;
    try {
        tracker.markWireCapability("not.real.cap", true);
    } catch (const std::runtime_error&) {
        unknownCap = true;
    }
    EXPECT_TRUE(unknownCap);
    tracker.logEvent("test", "wire progress", "info", "{}");
    const auto events = tracker.recentEvents(2);
    EXPECT_TRUE(events.size() >= 1);
}

#ifdef CPBITNODE_USE_ROCKSDB
void testRocksDbNodeStateOwnsOperationalFamilies() {
    const auto dir = std::filesystem::temp_directory_path() / "cpbitnode_rocksdb_node_state_test";
    std::filesystem::remove_all(dir);
    auto state = cpbitnode::db::openRocksDbNodeStateStore(dir.string());
    state->setMeta("foo", "bar");
    state->recordHeader(0, std::string(64, 'a'), std::string(64, '0'), 1, std::string(160, 'b'));
    state->recordHeader(1, std::string(64, 'c'), std::string(64, 'a'), 2, std::string(160, 'd'));
    state->recordBlock(1, std::string(64, 'c'), "blk00000.dat", 8, 80);
    state->upsertSyncState("testnet4", 1, std::string(64, 'c'), state->headerCount(), "headers_current");
    state->setValidatedTip(1, std::string(64, 'c'), "testnet4");
    const std::vector<std::uint8_t> txid(32, 0x33);
    state->addUtxo(txid, 0, 1, 5000, {0x51}, true);
    cpbitnode::db::StoredUtxo undo;
    undo.txid = std::string(64, 'e');
    undo.vout = 1;
    undo.height = 1;
    undo.value = 1000;
    undo.scriptPubkey = {0x51};
    state->replaceUtxoUndo("testnet4", 2, {undo});
    state->recordPeerAddress("8.8.8.8", 48333, 1, "unit");
    state->markWireCapability("headers.persist", true, "unit", "rocksdb");
    state->logEvent("unit", "hello", "info", "{}");
    state.reset();

    state = cpbitnode::db::openRocksDbNodeStateStore(dir.string());
    EXPECT_EQ(*state->getMeta("foo"), "bar");
    EXPECT_EQ(state->maxHeaderHeight(), 1);
    EXPECT_EQ(state->maxStoredBlockHeight(), 1);
    EXPECT_EQ(state->getValidatedHeight("testnet4"), 1);
    EXPECT_EQ(state->utxoCount(), 1);
    EXPECT_TRUE(state->getSyncState("testnet4").has_value());
    EXPECT_TRUE(!state->recentEvents(1).empty());
    EXPECT_TRUE(state->wireCapabilityMap().at("headers.persist") == 1);
    EXPECT_EQ(state->listPeerAddressEndpoints(4).size(), 1u);
    const auto undoRows = state->takeUtxoUndo("testnet4", 2);
    EXPECT_EQ(undoRows.size(), 1u);
    EXPECT_TRUE(!std::filesystem::exists(dir / "cpbitnode.db"));
    std::filesystem::remove_all(dir);
}
#endif

}  // namespace

void registerDbTests() {
    RUN_TEST(testSchemaInitialization);
    RUN_TEST(testTrackerProjectPhasesAndEvents);
    RUN_TEST(testTrackerHeadersIgnoreDuplicates);
    RUN_TEST(testTrackerMetaGetSet);
    RUN_TEST(testTrackerUpdatePhaseRejectsUnknown);
    RUN_TEST(testTrackerUpdatePhaseStatusAndNotes);
    RUN_TEST(testTrackerUpsertSyncStateInsertAndMerge);
    RUN_TEST(testTrackerPeerLifecycleAndAddresses);
    RUN_TEST(testTrackerHeaderAndBlockQueries);
    RUN_TEST(testTrackerUtxoRoundtripAndUndoJournal);
    RUN_TEST(testTrackerWireProgressAndSummary);
#ifdef CPBITNODE_USE_ROCKSDB
    RUN_TEST(testRocksDbNodeStateOwnsOperationalFamilies);
#endif
}
