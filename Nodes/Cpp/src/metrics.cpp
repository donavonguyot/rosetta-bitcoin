#include "cpbitnode/metrics.hpp"

#include "cpbitnode/db/node_state.hpp"
#include "cpbitnode/util/json.hpp"

#include <algorithm>
#include <sstream>
#include <stdexcept>

namespace cpbitnode::metrics {
namespace {

int parseMetaInt(const std::optional<std::string>& raw) {
    if (!raw || raw->empty()) {
        return 0;
    }
    try {
        return std::stoi(*raw);
    } catch (const std::exception&) {
        return 0;
    }
}

std::string escapePrometheusLabelValue(const std::string& raw) {
    std::string out;
    out.reserve(raw.size());
    for (const char ch : raw) {
        switch (ch) {
            case '\\':
                out += "\\\\";
                break;
            case '\n':
                out += "\\n";
                break;
            case '"':
                out += "\\\"";
                break;
            default:
                out.push_back(ch);
        }
    }
    return out;
}

}  // namespace

int readMetaInt(const db::NodeStateStore& tracker, const std::string& key) {
    return parseMetaInt(tracker.getMeta(key));
}

int incrMetaCounter(db::NodeStateStore& tracker, const std::string& key, int delta) {
    if (delta == 0) {
        return readMetaInt(tracker, key);
    }
    const int total = readMetaInt(tracker, key) + delta;
    tracker.setMeta(key, std::to_string(total));
    return total;
}

std::map<std::string, int> snapshotCounters(const db::NodeStateStore& tracker) {
    return {
        {"blocks_validated_total", readMetaInt(tracker, kMetaBlocksValidatedTotal)},
        {"txs_relayed_total", readMetaInt(tracker, kMetaTxsRelayedTotal)},
    };
}

std::string prometheusExpositionFormat(const db::NodeStateStore& tracker, const std::string& chain) {
    const auto counters = snapshotCounters(tracker);
    const std::string chainEsc = escapePrometheusLabelValue(chain);
    std::ostringstream out;
    out << "# HELP blocks_validated_total Blocks validated and connected.\n";
    out << "# TYPE blocks_validated_total counter\n";
    out << "blocks_validated_total{chain=\"" << chainEsc << "\"} " << counters.at("blocks_validated_total") << "\n\n";
    out << "# HELP txs_relayed_total Transactions relayed toward peers.\n";
    out << "# TYPE txs_relayed_total counter\n";
    out << "txs_relayed_total{chain=\"" << chainEsc << "\"} " << counters.at("txs_relayed_total") << "\n\n";
    return out.str();
}

void recordLastError(db::NodeStateStore& tracker, const std::string& message) {
    constexpr std::size_t kMaxLen = 4000;
    tracker.setMeta(kMetaLastError, message.substr(0, kMaxLen));
}

void clearLastError(db::NodeStateStore& tracker) {
    tracker.setMeta(kMetaLastError, "");
}

}  // namespace cpbitnode::metrics
