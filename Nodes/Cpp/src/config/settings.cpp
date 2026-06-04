#include "cpbitnode/config/settings.hpp"

#include <cstdlib>
#include <cstring>
#include <stdexcept>

namespace cpbitnode::config {
namespace {

bool envBool(const char* name, bool defaultValue) {
    const char* raw = std::getenv(name);
    if (!raw || !*raw) {
        return defaultValue;
    }
    std::string v(raw);
    return v == "1" || v == "true" || v == "yes" || v == "on";
}

int envInt(const char* name, int defaultValue) {
    const char* raw = std::getenv(name);
    if (!raw || !*raw) {
        return defaultValue;
    }
    return std::stoi(raw);
}

std::string envStr(const char* name, const char* defaultValue) {
    const char* raw = std::getenv(name);
    return raw && *raw ? std::string(raw) : std::string(defaultValue);
}

}  // namespace

Settings Settings::fromEnv() {
    Settings s;
    s.chain = envStr("CHAIN", "testnet4");
    s.dataDir = envStr("DATA_DIR", "./data-cpp");
    s.dbPath = envStr("DB_PATH", "");
    s.chainstateBackend = envStr("CHAINSTATE_BACKEND", "rocksdb");
    s.listen = envBool("LISTEN", false);
    s.p2pPort = envInt("P2P_PORT", 0);
    s.peers = envStr("PEERS", "");
    s.logLevel = envStr("LOG_LEVEL", "info");
    s.protocolVersion = envInt("PROTOCOL_VERSION", 70016);
    s.userAgent = envStr("USER_AGENT", "/cpbitnode:0.1.0/");
    s.maxOutboundPeers = envInt("MAX_OUTBOUND_PEERS", 3);
    s.pingIntervalSeconds = static_cast<double>(envInt("PING_INTERVAL_SECONDS", 1200));
    s.peerStaleSeconds = static_cast<double>(envInt("PEER_STALE_SECONDS", 5400));
    s.peerBanScoreThreshold = envInt("PEER_BAN_SCORE_THRESHOLD", 100);
    s.peerBanDecayUptimeSeconds = static_cast<double>(envInt("PEER_BAN_DECAY_UPTIME_SECONDS", 300));
    s.peerBanDecayAmount = envInt("PEER_BAN_DECAY_AMOUNT", 15);
    s.skipGetaddr = envBool("SKIP_GETADDR", false);
    s.syncSkipHeaders = envBool("SYNC_SKIP_HEADERS", false);
    s.noHeaderRefresh = envBool("NO_HEADER_REFRESH", false);
    s.minRelayFeerateSatVb = envInt("MIN_RELAY_FEERATE_SAT_VB", 0);
    s.blocksTargetHeight = envInt("BLOCKS_TARGET", 0);
    s.blocksMaxPerRun = envInt("BLOCKS_MAX", 0);
    s.blocksBatchSize = envInt("BLOCKS_BATCH_SIZE", 32);
    s.parallelBlockDownloads = envInt("PARALLEL_BLOCK_DOWNLOADS", 0);
    s.rebuildValidatedChain = envBool("REBUILD_VALIDATED_CHAIN", false);
    s.enableOrphanPool = envBool("ENABLE_ORPHAN_POOL", false);
    s.mempoolMaxCount = envInt("MEMPOOL_MAX_COUNT", 10000);
    s.mempoolMaxAgeSeconds = envInt("MEMPOOL_MAX_AGE_SECONDS", 86400);
    s.metricsHttpPort = envInt("METRICS_HTTP_PORT", 0);
    return s;
}

Settings Settings::fromArgs(int argc, char** argv) {
    Settings s = fromEnv();
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        if (arg == "--datadir" && i + 1 < argc) {
            s.dataDir = argv[++i];
        } else if (arg == "--chain" && i + 1 < argc) {
            s.chain = argv[++i];
        } else if (arg == "--db" && i + 1 < argc) {
            ++i;
            throw std::runtime_error("--db is not supported in Cpp Core-native mode");
        } else if (arg == "--chainstate-backend" && i + 1 < argc) {
            s.chainstateBackend = argv[++i];
        } else if (arg == "--listen") {
            s.listen = true;
        } else if (arg == "--sync-only") {
            s.syncOnly = true;
        } else if (arg == "--help" || arg == "-h") {
            throw std::runtime_error(
                "usage: cpbitnode [--datadir PATH] [--chain NAME] [--listen] [--sync-only]");
        }
    }
    return s;
}

Settings Settings::fromSyncArgs(int argc, char** argv) {
    Settings s = fromEnv();
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        if (arg == "--datadir" && i + 1 < argc) {
            s.dataDir = argv[++i];
        } else if (arg == "--chain" && i + 1 < argc) {
            s.chain = argv[++i];
        } else if (arg == "--db" && i + 1 < argc) {
            ++i;
            throw std::runtime_error("--db is not supported in Cpp Core-native mode");
        } else if (arg == "--chainstate-backend" && i + 1 < argc) {
            s.chainstateBackend = argv[++i];
        } else if (arg == "--peers" && i + 1 < argc) {
            s.peers = argv[++i];
        } else if (arg == "--blocks-target" && i + 1 < argc) {
            s.blocksTargetHeight = std::stoi(argv[++i]);
        } else if (arg == "--blocks-max" && i + 1 < argc) {
            s.blocksMaxPerRun = std::stoi(argv[++i]);
        } else if (arg == "--log-level" && i + 1 < argc) {
            s.logLevel = argv[++i];
        } else if (arg == "--connect-only") {
            s.setConnectOnly = true;
        } else if (arg == "--no-header-refresh") {
            s.noHeaderRefresh = true;
        } else if (arg == "--rebuild") {
            s.rebuildValidatedChain = true;
        } else if (arg == "--help" || arg == "-h") {
            throw std::runtime_error(
                "usage: cpbitnode-sync [--datadir PATH] [--chain NAME] [--peers HOST:PORT,...] "
                "[--blocks-target N] [--blocks-max N] [--connect-only] [--no-header-refresh] [--rebuild]");
        }
    }
    return s;
}

std::string Settings::resolvedDbPath() const {
    if (!dbPath.empty()) {
        return dbPath;
    }
    std::string dir = dataDir;
    while (!dir.empty() && dir.back() == '/') {
        dir.pop_back();
    }
    return dir + "/cpbitnode.db";
}

std::string Settings::blocksDir() const {
    std::string dir = dataDir;
    while (!dir.empty() && dir.back() == '/') {
        dir.pop_back();
    }
    return dir + "/blocks";
}

bool Settings::lightweightOutboundHandshake() const {
    return noHeaderRefresh || syncSkipHeaders;
}

}  // namespace cpbitnode::config
