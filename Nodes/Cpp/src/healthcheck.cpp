#include "cpbitnode/healthcheck.hpp"

#include "cpbitnode/config/settings.hpp"
#include "cpbitnode/db/tracker.hpp"
#include "cpbitnode/metrics.hpp"
#include "cpbitnode/util/json.hpp"

#include <cmath>
#include <sqlite3.h>
#include <sstream>
#include <stdexcept>

namespace cpbitnode::healthcheck {
namespace {

std::optional<double> syncProgressPct(int validatedHeight, int peerTipHeight) {
    if (peerTipHeight <= 0) {
        return std::nullopt;
    }
    if (validatedHeight <= 0) {
        return 0.0;
    }
    const double pct = std::min(100.0, 100.0 * static_cast<double>(validatedHeight) / static_cast<double>(peerTipHeight));
    return std::round(pct * 100.0) / 100.0;
}

std::optional<std::string> lastErrorValue(const db::ProjectTracker& tracker) {
    const auto raw = tracker.getMeta(metrics::kMetaLastError);
    if (!raw || raw->empty()) {
        return std::nullopt;
    }
    std::string trimmed = *raw;
    while (!trimmed.empty() && (trimmed.front() == ' ' || trimmed.front() == '\t')) {
        trimmed.erase(trimmed.begin());
    }
    while (!trimmed.empty() && (trimmed.back() == ' ' || trimmed.back() == '\t')) {
        trimmed.pop_back();
    }
    if (trimmed.empty()) {
        return std::nullopt;
    }
    return trimmed;
}

int parseIntField(const std::string& raw, int fallback = 0) {
    if (raw.empty()) {
        return fallback;
    }
    try {
        return std::stoi(raw);
    } catch (const std::exception&) {
        return fallback;
    }
}

}  // namespace

void validateHealthcheckPayload(const HealthcheckDocument& doc) {
    if (doc.ok != doc.healthy) {
        throw std::invalid_argument("healthy must match ok");
    }
    if (doc.syncStatus.empty()) {
        throw std::invalid_argument("sync_status must be str");
    }
    if (doc.chain.empty()) {
        throw std::invalid_argument("chain must be str");
    }

    const int intFields[] = {
        doc.validatedHeight, doc.headerHeight, doc.blockCount, doc.utxoCount,
        doc.peerCount, doc.peerRecordsTotal, doc.mempoolTxCount, doc.mempoolSize, doc.mempoolSizeBytes,
    };
    for (const int value : intFields) {
        if (value < 0) {
            throw std::invalid_argument("healthcheck int fields must be non-negative");
        }
    }

    if (doc.syncProgressPct.has_value()) {
        const double pct = *doc.syncProgressPct;
        if (pct < 0.0 || pct > 100.0) {
            throw std::invalid_argument("sync_progress_pct must be between 0 and 100");
        }
    }

    if (doc.lastError.has_value() && doc.lastError->empty()) {
        throw std::invalid_argument("last_error must be str or null");
    }

    for (const auto& [name, value] : doc.metrics) {
        if (name.empty()) {
            throw std::invalid_argument("metrics keys must be str");
        }
        if (value < 0) {
            throw std::invalid_argument("metrics." + name + " must be a non-negative int");
        }
    }

    if (doc.summaryJson.empty() || doc.summaryJson.front() != '{') {
        throw std::invalid_argument("summary must be a dict");
    }
}

HealthcheckDocument buildHealthcheckDocument(const config::Settings& settings, db::ProjectTracker& tracker) {
    const std::string summary = tracker.summaryJson(settings.chain);
    const auto sync = tracker.getSyncState(settings.chain);
    const std::string syncStatus = sync ? sync->at("sync_status") : "unknown";

    const auto mempoolCountRaw = tracker.getMeta("mempool_tx_count");
    const auto mempoolBytesRaw = tracker.getMeta("mempool_size_bytes");
    const int mempoolTxCount = parseIntField(mempoolCountRaw.value_or("0"));

    int peerTipHeight = 0;
    if (sync) {
        peerTipHeight = parseIntField(sync->at("best_height"));
    }

    const int validatedHeight = tracker.getValidatedHeight(settings.chain);
    const int headerHeight = tracker.maxHeaderHeight();
    const int blockCount = tracker.blockCount();
    const int utxoCount = tracker.utxoCount();

    sqlite3_stmt* peerCountStmt = nullptr;
    sqlite3_prepare_v2(tracker.handle(), "SELECT COUNT(*) FROM peers WHERE status = 'connected'", -1, &peerCountStmt,
                       nullptr);
    int connectedPeers = 0;
    if (sqlite3_step(peerCountStmt) == SQLITE_ROW) {
        connectedPeers = sqlite3_column_int(peerCountStmt, 0);
    }
    sqlite3_finalize(peerCountStmt);

    sqlite3_stmt* peerRecordsStmt = nullptr;
    sqlite3_prepare_v2(tracker.handle(), "SELECT COUNT(*) FROM peers", -1, &peerRecordsStmt, nullptr);
    int peerRecordsTotal = 0;
    if (sqlite3_step(peerRecordsStmt) == SQLITE_ROW) {
        peerRecordsTotal = sqlite3_column_int(peerRecordsStmt, 0);
    }
    sqlite3_finalize(peerRecordsStmt);

    const bool ok = syncStatus != "error";
    HealthcheckDocument doc;
    doc.ok = ok;
    doc.healthy = ok;
    doc.syncStatus = syncStatus;
    doc.chain = settings.chain;
    doc.validatedHeight = validatedHeight;
    doc.headerHeight = headerHeight;
    doc.blockCount = blockCount;
    doc.utxoCount = utxoCount;
    doc.peerCount = connectedPeers;
    doc.peerRecordsTotal = peerRecordsTotal;
    doc.mempoolTxCount = mempoolTxCount;
    doc.mempoolSize = mempoolTxCount;
    doc.mempoolSizeBytes = parseIntField(mempoolBytesRaw.value_or("0"));
    doc.syncProgressPct = syncProgressPct(validatedHeight, peerTipHeight);
    doc.lastError = lastErrorValue(tracker);
    doc.metrics = metrics::snapshotCounters(tracker);
    doc.summaryJson = summary;
    return doc;
}

std::string serializeHealthcheckDocument(const HealthcheckDocument& doc) {
    std::ostringstream metrics;
    metrics << "{";
    bool firstMetric = true;
    for (const auto& [name, value] : doc.metrics) {
        if (!firstMetric) {
            metrics << ",";
        }
        firstMetric = false;
        metrics << util::jsonString(name) << ":" << value;
    }
    metrics << "}";

    std::ostringstream out;
    out << "{";
    out << util::jsonString("ok") << ":" << (doc.ok ? "true" : "false") << ",";
    out << util::jsonString("healthy") << ":" << (doc.healthy ? "true" : "false") << ",";
    out << util::jsonString("sync_status") << ":" << util::jsonString(doc.syncStatus) << ",";
    out << util::jsonString("chain") << ":" << util::jsonString(doc.chain) << ",";
    out << util::jsonString("validated_height") << ":" << doc.validatedHeight << ",";
    out << util::jsonString("header_height") << ":" << doc.headerHeight << ",";
    out << util::jsonString("block_count") << ":" << doc.blockCount << ",";
    out << util::jsonString("utxo_count") << ":" << doc.utxoCount << ",";
    out << util::jsonString("peer_count") << ":" << doc.peerCount << ",";
    out << util::jsonString("peer_records_total") << ":" << doc.peerRecordsTotal << ",";
    out << util::jsonString("mempool_tx_count") << ":" << doc.mempoolTxCount << ",";
    out << util::jsonString("mempool_size") << ":" << doc.mempoolSize << ",";
    out << util::jsonString("mempool_size_bytes") << ":" << doc.mempoolSizeBytes << ",";
    out << util::jsonString("sync_progress_pct") << ":";
    if (doc.syncProgressPct.has_value()) {
        out << *doc.syncProgressPct;
    } else {
        out << "null";
    }
    out << ",";
    out << util::jsonString("last_error") << ":";
    if (doc.lastError.has_value()) {
        out << util::jsonString(*doc.lastError);
    } else {
        out << "null";
    }
    out << ",";
    out << util::jsonString("metrics") << ":" << metrics.str() << ",";
    out << util::jsonString("summary") << ":" << doc.summaryJson;
    out << "}";
    return out.str();
}

}  // namespace cpbitnode::healthcheck
