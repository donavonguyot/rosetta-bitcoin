#pragma once

#include <map>
#include <string>

namespace cpbitnode::db {
class NodeStateStore;
}

namespace cpbitnode::metrics {

inline constexpr const char* kMetaBlocksValidatedTotal = "metric_blocks_validated_total";
inline constexpr const char* kMetaTxsRelayedTotal = "metric_txs_relayed_total";
inline constexpr const char* kMetaLastError = "last_error";

int readMetaInt(const db::NodeStateStore& tracker, const std::string& key);
int incrMetaCounter(db::NodeStateStore& tracker, const std::string& key, int delta = 1);
std::map<std::string, int> snapshotCounters(const db::NodeStateStore& tracker);
std::string prometheusExpositionFormat(const db::NodeStateStore& tracker, const std::string& chain);
void recordLastError(db::NodeStateStore& tracker, const std::string& message);
void clearLastError(db::NodeStateStore& tracker);

}  // namespace cpbitnode::metrics
