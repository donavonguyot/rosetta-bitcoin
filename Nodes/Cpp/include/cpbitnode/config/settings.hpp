#pragma once

#include <cstdint>
#include <string>

namespace cpbitnode::config {

struct Settings {
    std::string chain = "testnet4";
    std::string dataDir = "./data-cpp";
    std::string dbPath;
    std::string chainstateBackend = "sqlite";
    bool listen = false;
    int p2pPort = 0;
    std::string peers;
    std::string logLevel = "info";
    int protocolVersion = 70016;
    std::string userAgent = "/cpbitnode:0.1.0/";

    int maxOutboundPeers = 3;
    double pingIntervalSeconds = 1200.0;
    double peerStaleSeconds = 5400.0;
    int peerBanScoreThreshold = 100;
    double peerBanDecayUptimeSeconds = 300.0;
    int peerBanDecayAmount = 15;
    bool skipGetaddr = false;
    bool syncSkipHeaders = false;
    bool noHeaderRefresh = false;
    int minRelayFeerateSatVb = 0;
    int blocksTargetHeight = 0;
    int blocksMaxPerRun = 0;
    int blocksBatchSize = 32;
    int parallelBlockDownloads = 0;
    bool rebuildValidatedChain = false;
    bool enableOrphanPool = false;
    int mempoolMaxCount = 10000;
    int mempoolMaxAgeSeconds = 86400;
    int metricsHttpPort = 0;
    bool syncOnly = false;

    static Settings fromEnv();
    static Settings fromArgs(int argc, char** argv);
    static Settings fromSyncArgs(int argc, char** argv);

    std::string resolvedDbPath() const;
    std::string blocksDir() const;
    bool lightweightOutboundHandshake() const;

    bool setConnectOnly = false;
};

}  // namespace cpbitnode::config
