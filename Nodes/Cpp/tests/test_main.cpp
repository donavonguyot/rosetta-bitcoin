#include "test_support.hpp"

void registerWireTests();
void registerWireCapabilityTests();
void registerMessageTests();
void registerConsensusTests();
void registerDbTests();
void registerChainTests();
void registerStorageTests();
void registerHealthcheckTests();
void registerScriptTests();
void registerCompactBlockTests();
void registerConnectTests();
void registerP2pTests();
void registerDiscoveryTests();
void registerPeerManagerTests();
void registerHeaderServingTests();
void registerMempoolTests();
void registerSyncTests();
void registerInboundServeTests();
void registerPeerTxRelayTests();
void registerSyncIntegrationSmokeTests();

void registerTransportTests();
void registerMetricsHttpTests();
void registerEndpointSettingsTests();
void registerMetricsTests();
void registerJsonTests();
void registerHeaderRefreshTests();
void registerServerDiscoveryTests();
void registerNodeTests();
void registerCliSmokeTests();
void registerNativeCryptoTests();
void registerNodecoreScriptCorpusTests();

int main() {
    registerWireTests();
    registerWireCapabilityTests();
    registerMessageTests();
    registerConsensusTests();
    registerDbTests();
    registerChainTests();
    registerStorageTests();
    registerHealthcheckTests();
    registerScriptTests();
    registerCompactBlockTests();
    registerConnectTests();
    registerP2pTests();
    registerDiscoveryTests();
    registerPeerManagerTests();
    registerHeaderServingTests();
    registerSyncTests();
    registerMempoolTests();
    registerInboundServeTests();
    registerPeerTxRelayTests();
    registerSyncIntegrationSmokeTests();
    registerTransportTests();
    registerMetricsHttpTests();
    registerEndpointSettingsTests();
    registerMetricsTests();
    registerJsonTests();
    registerHeaderRefreshTests();
    registerServerDiscoveryTests();
    registerNodeTests();
    registerCliSmokeTests();
    registerNativeCryptoTests();
    registerNodecoreScriptCorpusTests();
    if (g_failures != 0) {
        std::cerr << g_failures << " test failures\n";
        return 1;
    }
    std::cerr << "All tests passed\n";
    return 0;
}
