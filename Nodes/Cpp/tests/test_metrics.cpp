#include "test_support.hpp"

#include "cpbitnode/db/tracker.hpp"
#include "cpbitnode/metrics.hpp"

#include <filesystem>
#include <string>

void registerMetricsTests();

namespace {

using cpbitnode::db::ProjectTracker;
using cpbitnode::metrics::clearLastError;
using cpbitnode::metrics::incrMetaCounter;
using cpbitnode::metrics::kMetaBlocksValidatedTotal;
using cpbitnode::metrics::kMetaLastError;
using cpbitnode::metrics::kMetaTxsRelayedTotal;
using cpbitnode::metrics::prometheusExpositionFormat;
using cpbitnode::metrics::readMetaInt;
using cpbitnode::metrics::recordLastError;
using cpbitnode::metrics::snapshotCounters;

void testIncrMetaCounterAndSnapshot() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_metrics_counters.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    EXPECT_EQ(readMetaInt(tracker, kMetaBlocksValidatedTotal), 0);
    EXPECT_EQ(incrMetaCounter(tracker, kMetaBlocksValidatedTotal, 2), 2);
    EXPECT_EQ(incrMetaCounter(tracker, kMetaBlocksValidatedTotal, 0), 2);
    EXPECT_EQ(incrMetaCounter(tracker, kMetaTxsRelayedTotal, 1), 1);
    const auto counters = snapshotCounters(tracker);
    EXPECT_EQ(counters.at("blocks_validated_total"), 2);
    EXPECT_EQ(counters.at("txs_relayed_total"), 1);
}

void testPrometheusExpositionEscapesChainLabel() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_metrics_prom.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    incrMetaCounter(tracker, kMetaBlocksValidatedTotal, 1);
    const std::string prom = prometheusExpositionFormat(tracker, "test\"net\\4");
    EXPECT_TRUE(prom.find("chain=\"test\\\"net\\\\4\"") != std::string::npos);
    EXPECT_TRUE(prom.find("# TYPE blocks_validated_total counter") != std::string::npos);
}

void testRecordAndClearLastError() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_metrics_err.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    recordLastError(tracker, "peer reset");
    EXPECT_EQ(tracker.getMeta(kMetaLastError).value_or(""), "peer reset");
    clearLastError(tracker);
    EXPECT_EQ(tracker.getMeta(kMetaLastError).value_or(""), "");
}

void testPrometheusExpositionEscapesNewlineInChain() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_metrics_prom_nl.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    const std::string prom = prometheusExpositionFormat(tracker, "a\nb");
    EXPECT_TRUE(prom.find("chain=\"a\\nb\"") != std::string::npos);
}

void testReadMetaIntEmptyMeta() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_metrics_empty.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    EXPECT_EQ(readMetaInt(tracker, kMetaBlocksValidatedTotal), 0);
}

void testRecordLastErrorTruncatesLongMessage() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_metrics_longerr.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    recordLastError(tracker, std::string(5000, 'x'));
    EXPECT_EQ(tracker.getMeta(kMetaLastError).value_or("").size(), 4000u);
}
void testReadMetaIntInvalidStoredValue() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_metrics_badmeta.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    tracker.setMeta(kMetaBlocksValidatedTotal, "not-a-number");
    EXPECT_EQ(readMetaInt(tracker, kMetaBlocksValidatedTotal), 0);
}

}  // namespace

void registerMetricsTests() {
    RUN_TEST(testIncrMetaCounterAndSnapshot);
    RUN_TEST(testPrometheusExpositionEscapesChainLabel);
    RUN_TEST(testPrometheusExpositionEscapesNewlineInChain);
    RUN_TEST(testRecordAndClearLastError);
    RUN_TEST(testReadMetaIntEmptyMeta);
    RUN_TEST(testReadMetaIntInvalidStoredValue);
    RUN_TEST(testRecordLastErrorTruncatesLongMessage);
}
