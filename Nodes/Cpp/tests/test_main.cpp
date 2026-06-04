#include "test_support.hpp"

void registerWireTests();
void registerMessageTests();
void registerConsensusTests();
void registerChainTests();
void registerStorageTests();
void registerCodecV2Tests();
void registerNativeStoreTests();
void registerConnectTimingTests();
void registerSyncHotPathTests();
void registerScriptTests();
void registerCompactBlockTests();
void registerTransportTests();
void registerEndpointSettingsTests();
void registerJsonTests();
void registerCliSmokeTests();
void registerNativeCryptoTests();
void registerNodecoreScriptCorpusTests();

int main() {
    registerWireTests();
    registerMessageTests();
    registerConsensusTests();
    registerChainTests();
    registerStorageTests();
    registerCodecV2Tests();
    registerNativeStoreTests();
    registerConnectTimingTests();
    registerSyncHotPathTests();
    registerScriptTests();
    registerCompactBlockTests();
    registerTransportTests();
    registerEndpointSettingsTests();
    registerJsonTests();
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
