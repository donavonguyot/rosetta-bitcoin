#include "test_support.hpp"

#include <iostream>
#include <string>

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

namespace {

void registerCoreRegressionTests() {
    registerConsensusTests();
    registerStorageTests();
    registerNativeStoreTests();
    registerConnectTimingTests();
    registerScriptTests();
    registerNativeCryptoTests();
    registerNodecoreScriptCorpusTests();
}

void registerWireCodecTests() {
    registerWireTests();
    registerMessageTests();
    registerChainTests();
    registerCodecV2Tests();
    registerCompactBlockTests();
    registerJsonTests();
}

void registerRuntimeSmokeTests() {
    registerSyncHotPathTests();
    registerTransportTests();
    registerEndpointSettingsTests();
    registerCliSmokeTests();
}

void registerAllTests() {
    registerCoreRegressionTests();
    registerWireCodecTests();
    registerRuntimeSmokeTests();
}

void printUsage(const char* argv0) {
    std::cerr << "usage: " << argv0 << " [--suite all|core|wire|runtime]\n";
}

}  // namespace

int main(int argc, char** argv) {
    std::string suite = "all";
    if (argc == 3 && std::string(argv[1]) == "--suite") {
        suite = argv[2];
    } else if (argc != 1) {
        printUsage(argv[0]);
        return 2;
    }

    if (suite == "all") {
        registerAllTests();
    } else if (suite == "core") {
        registerCoreRegressionTests();
    } else if (suite == "wire") {
        registerWireCodecTests();
    } else if (suite == "runtime") {
        registerRuntimeSmokeTests();
    } else {
        printUsage(argv[0]);
        return 2;
    }

    if (g_failures != 0) {
        std::cerr << g_failures << " test failures\n";
        return 1;
    }
    std::cerr << "All tests passed\n";
    return 0;
}
