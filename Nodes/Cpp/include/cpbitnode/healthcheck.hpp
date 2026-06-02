#pragma once

#include <map>
#include <optional>
#include <string>

namespace cpbitnode::config {
struct Settings;
}

namespace cpbitnode::db {
class ProjectTracker;
}

namespace cpbitnode::healthcheck {

struct HealthcheckDocument {
    bool ok = false;
    bool healthy = false;
    std::string syncStatus;
    std::string chain;
    int validatedHeight = 0;
    int headerHeight = 0;
    int blockCount = 0;
    int utxoCount = 0;
    int peerCount = 0;
    int peerRecordsTotal = 0;
    int mempoolTxCount = 0;
    int mempoolSize = 0;
    int mempoolSizeBytes = 0;
    std::optional<double> syncProgressPct;
    std::optional<std::string> lastError;
    std::map<std::string, int> metrics;
    std::string summaryJson;
};

void validateHealthcheckPayload(const HealthcheckDocument& doc);
HealthcheckDocument buildHealthcheckDocument(const config::Settings& settings, db::ProjectTracker& tracker);
std::string serializeHealthcheckDocument(const HealthcheckDocument& doc);

}  // namespace cpbitnode::healthcheck
