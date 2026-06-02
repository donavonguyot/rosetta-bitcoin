#include "test_support.hpp"

#include "cpbitnode/config/settings.hpp"
#include "cpbitnode/db/tracker.hpp"
#include "cpbitnode/healthcheck.hpp"
#include "cpbitnode/metrics.hpp"

#include <filesystem>
#include <functional>
#include <string>
#include <vector>

void registerHealthcheckTests();

namespace {

cpbitnode::healthcheck::HealthcheckDocument baseDocument() {
    cpbitnode::healthcheck::HealthcheckDocument doc;
    doc.ok = true;
    doc.healthy = true;
    doc.syncStatus = "running";
    doc.chain = "testnet4";
    doc.metrics = {{"blocks_validated_total", 0}, {"txs_relayed_total", 0}};
    doc.summaryJson = "{}";
    return doc;
}

bool expectInvalidArgument(const std::function<void()>& fn) {
    try {
        fn();
        return false;
    } catch (const std::invalid_argument&) {
        return true;
    }
}

void testDockerHealthDocumentExposesTrackerMetrics() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_hc_metrics.db";
    std::filesystem::remove(path);
    cpbitnode::config::Settings settings;
    settings.chain = "testnet4";
    settings.dbPath = path.string();
    cpbitnode::db::ProjectTracker tracker(settings.resolvedDbPath());

    tracker.setValidatedTip(11, std::string(64, 'a'), settings.chain);
    tracker.recordBlock(1, std::string(64, 'b'), "blk.dat", 0, 100);
    tracker.addUtxo(std::vector<std::uint8_t>(32, 0x01), 0, 1, 1000, {0x51}, false);
    tracker.recordPeerConnected("198.51.100.2", 48333);
    tracker.setMeta("mempool_tx_count", "3");
    tracker.setMeta("mempool_size_bytes", "2048");
    tracker.recordHeader(42, std::string(64, 'c'), std::string(64, 'd'), 1);
    tracker.upsertSyncState(settings.chain, 100, std::nullopt, std::nullopt, "connected");

    const auto doc = cpbitnode::healthcheck::buildHealthcheckDocument(settings, tracker);
    EXPECT_EQ(doc.validatedHeight, 11);
    EXPECT_EQ(doc.headerHeight, 42);
    EXPECT_TRUE(doc.blockCount >= 1);
    EXPECT_TRUE(doc.utxoCount >= 1);
    EXPECT_EQ(doc.mempoolTxCount, 3);
    EXPECT_EQ(doc.mempoolSize, 3);
    EXPECT_EQ(doc.mempoolSizeBytes, 2048);
    EXPECT_TRUE(doc.peerCount >= 1);
    EXPECT_TRUE(doc.syncProgressPct.has_value());
    EXPECT_EQ(*doc.syncProgressPct, 11.0);
    EXPECT_EQ(doc.metrics.at("blocks_validated_total"), 0);
    EXPECT_EQ(doc.metrics.at("txs_relayed_total"), 0);
    EXPECT_TRUE(!doc.lastError.has_value());
    cpbitnode::healthcheck::validateHealthcheckPayload(doc);
}

void testValidateHealthcheckPayloadRejectsBadMetricsValue() {
    auto doc = baseDocument();
    doc.metrics["blocks_validated_total"] = -1;
    bool threw = false;
    try {
        cpbitnode::healthcheck::validateHealthcheckPayload(doc);
    } catch (const std::invalid_argument& ex) {
        threw = true;
        EXPECT_TRUE(std::string(ex.what()).find("non-negative") != std::string::npos);
    }
    EXPECT_TRUE(threw);
}

void testValidateHealthcheckPayloadAcceptsFutureMetricCounter() {
    auto doc = baseDocument();
    doc.metrics["future_total"] = 1;
    cpbitnode::healthcheck::validateHealthcheckPayload(doc);
}

void testHealthcheckLastErrorWhenMetaSet() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_hc_last_error.db";
    std::filesystem::remove(path);
    cpbitnode::config::Settings settings;
    settings.chain = "testnet4";
    settings.dbPath = path.string();
    cpbitnode::db::ProjectTracker tracker(settings.resolvedDbPath());
    tracker.upsertSyncState(settings.chain, 1, std::nullopt, std::nullopt, "running");
    cpbitnode::metrics::recordLastError(tracker, "connection reset");

    const auto doc = cpbitnode::healthcheck::buildHealthcheckDocument(settings, tracker);
    EXPECT_TRUE(doc.lastError.has_value());
    EXPECT_EQ(*doc.lastError, "connection reset");
    cpbitnode::healthcheck::validateHealthcheckPayload(doc);
}

void testSyncProgressPctNoneWhenNoPeerTip() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_hc_no_peer_tip.db";
    std::filesystem::remove(path);
    cpbitnode::config::Settings settings;
    settings.chain = "testnet4";
    settings.dbPath = path.string();
    cpbitnode::db::ProjectTracker tracker(settings.resolvedDbPath());
    tracker.setValidatedTip(5, std::string(64, 'a'), settings.chain);
    tracker.upsertSyncState(settings.chain, 0, std::nullopt, std::nullopt, "headers_current");

    const auto doc = cpbitnode::healthcheck::buildHealthcheckDocument(settings, tracker);
    EXPECT_TRUE(!doc.syncProgressPct.has_value());
    cpbitnode::healthcheck::validateHealthcheckPayload(doc);
}

void testSerializeHealthcheckDocumentIncludesMetrics() {
    auto doc = baseDocument();
    doc.syncStatus = "headers_current";
    const auto json = cpbitnode::healthcheck::serializeHealthcheckDocument(doc);
    EXPECT_TRUE(json.find("\"metrics\":{\"blocks_validated_total\":0,\"txs_relayed_total\":0}") !=
                std::string::npos);
    EXPECT_TRUE(json.find("\"sync_status\":\"headers_current\"") != std::string::npos);
}

void testValidateHealthcheckPayloadRejectsMismatchedOkHealthy() {
    auto doc = baseDocument();
    doc.healthy = false;
    bool threw = false;
    try {
        cpbitnode::healthcheck::validateHealthcheckPayload(doc);
    } catch (const std::invalid_argument& ex) {
        threw = true;
        EXPECT_TRUE(std::string(ex.what()).find("healthy must match ok") != std::string::npos);
    }
    EXPECT_TRUE(threw);
}

void testValidateHealthcheckPayloadRejectsEmptySyncStatus() {
    auto doc = baseDocument();
    doc.syncStatus.clear();
    EXPECT_TRUE(expectInvalidArgument([&] { cpbitnode::healthcheck::validateHealthcheckPayload(doc); }));
}

void testValidateHealthcheckPayloadRejectsEmptyChain() {
    auto doc = baseDocument();
    doc.chain.clear();
    EXPECT_TRUE(expectInvalidArgument([&] { cpbitnode::healthcheck::validateHealthcheckPayload(doc); }));
}

void testValidateHealthcheckPayloadRejectsNegativeHeight() {
    auto doc = baseDocument();
    doc.validatedHeight = -1;
    EXPECT_TRUE(expectInvalidArgument([&] { cpbitnode::healthcheck::validateHealthcheckPayload(doc); }));
}

void testValidateHealthcheckPayloadRejectsSyncProgressOutOfRange() {
    auto doc = baseDocument();
    doc.syncProgressPct = 100.1;
    EXPECT_TRUE(expectInvalidArgument([&] { cpbitnode::healthcheck::validateHealthcheckPayload(doc); }));
}

void testValidateHealthcheckPayloadRejectsEmptyLastErrorString() {
    auto doc = baseDocument();
    doc.lastError = "";
    EXPECT_TRUE(expectInvalidArgument([&] { cpbitnode::healthcheck::validateHealthcheckPayload(doc); }));
}

void testValidateHealthcheckPayloadRejectsEmptyMetricKey() {
    auto doc = baseDocument();
    doc.metrics[""] = 1;
    EXPECT_TRUE(expectInvalidArgument([&] { cpbitnode::healthcheck::validateHealthcheckPayload(doc); }));
}

void testValidateHealthcheckPayloadRejectsNonObjectSummary() {
    auto doc = baseDocument();
    doc.summaryJson = "[]";
    EXPECT_TRUE(expectInvalidArgument([&] { cpbitnode::healthcheck::validateHealthcheckPayload(doc); }));
}

void testBuildHealthcheckDocumentMarksErrorSyncUnhealthy() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_hc_error.db";
    std::filesystem::remove(path);
    cpbitnode::config::Settings settings;
    settings.chain = "testnet4";
    settings.dbPath = path.string();
    cpbitnode::db::ProjectTracker tracker(settings.resolvedDbPath());
    tracker.upsertSyncState(settings.chain, 10, std::nullopt, std::nullopt, "error");
    const auto doc = cpbitnode::healthcheck::buildHealthcheckDocument(settings, tracker);
    EXPECT_TRUE(!doc.ok);
    EXPECT_TRUE(!doc.healthy);
    EXPECT_EQ(doc.syncStatus, "error");
}

void testBuildHealthcheckDocumentTrimsWhitespaceLastError() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_hc_trim_err.db";
    std::filesystem::remove(path);
    cpbitnode::config::Settings settings;
    settings.chain = "testnet4";
    settings.dbPath = path.string();
    cpbitnode::db::ProjectTracker tracker(settings.resolvedDbPath());
    tracker.setMeta("last_error", "   \t  ");
    tracker.upsertSyncState(settings.chain, 1, std::nullopt, std::nullopt, "running");
    const auto doc = cpbitnode::healthcheck::buildHealthcheckDocument(settings, tracker);
    EXPECT_TRUE(!doc.lastError.has_value());
}

void testBuildHealthcheckDocumentParsesInvalidMetaAsZero() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_hc_bad_meta.db";
    std::filesystem::remove(path);
    cpbitnode::config::Settings settings;
    settings.chain = "testnet4";
    settings.dbPath = path.string();
    cpbitnode::db::ProjectTracker tracker(settings.resolvedDbPath());
    tracker.setMeta("mempool_tx_count", "not-a-number");
    tracker.setMeta("mempool_size_bytes", "");
    tracker.upsertSyncState(settings.chain, 5, std::nullopt, std::nullopt, "running");
    const auto doc = cpbitnode::healthcheck::buildHealthcheckDocument(settings, tracker);
    EXPECT_EQ(doc.mempoolTxCount, 0);
    EXPECT_EQ(doc.mempoolSizeBytes, 0);
    EXPECT_TRUE(doc.syncProgressPct.has_value());
    EXPECT_EQ(*doc.syncProgressPct, 0.0);
}

void testSerializeHealthcheckDocumentNullOptionals() {
    auto doc = baseDocument();
    doc.syncProgressPct = std::nullopt;
    doc.lastError = std::nullopt;
    const auto json = cpbitnode::healthcheck::serializeHealthcheckDocument(doc);
    EXPECT_TRUE(json.find("\"sync_progress_pct\":null") != std::string::npos);
    EXPECT_TRUE(json.find("\"last_error\":null") != std::string::npos);
}

}  // namespace

void registerHealthcheckTests() {
    RUN_TEST(testDockerHealthDocumentExposesTrackerMetrics);
    RUN_TEST(testValidateHealthcheckPayloadRejectsBadMetricsValue);
    RUN_TEST(testValidateHealthcheckPayloadAcceptsFutureMetricCounter);
    RUN_TEST(testHealthcheckLastErrorWhenMetaSet);
    RUN_TEST(testSyncProgressPctNoneWhenNoPeerTip);
    RUN_TEST(testSerializeHealthcheckDocumentIncludesMetrics);
    RUN_TEST(testValidateHealthcheckPayloadRejectsMismatchedOkHealthy);
    RUN_TEST(testValidateHealthcheckPayloadRejectsEmptySyncStatus);
    RUN_TEST(testValidateHealthcheckPayloadRejectsEmptyChain);
    RUN_TEST(testValidateHealthcheckPayloadRejectsNegativeHeight);
    RUN_TEST(testValidateHealthcheckPayloadRejectsSyncProgressOutOfRange);
    RUN_TEST(testValidateHealthcheckPayloadRejectsEmptyLastErrorString);
    RUN_TEST(testValidateHealthcheckPayloadRejectsEmptyMetricKey);
    RUN_TEST(testValidateHealthcheckPayloadRejectsNonObjectSummary);
    RUN_TEST(testBuildHealthcheckDocumentMarksErrorSyncUnhealthy);
    RUN_TEST(testBuildHealthcheckDocumentTrimsWhitespaceLastError);
    RUN_TEST(testBuildHealthcheckDocumentParsesInvalidMetaAsZero);
    RUN_TEST(testSerializeHealthcheckDocumentNullOptionals);
}
