#include "test_support.hpp"

#include "cpbitnode/config/settings.hpp"
#include "cpbitnode/endpoint_parse.hpp"

#include <cstdlib>
#include <filesystem>
#include <string>

void registerEndpointSettingsTests();

namespace {

using cpbitnode::config::Settings;
using cpbitnode::hostPortIsWellFormedEndpoint;
using cpbitnode::isValidListenPort;
using cpbitnode::normalizePeerManualSpec;
using cpbitnode::splitManualPeerList;

class EnvGuard {
public:
    explicit EnvGuard(const char* name) : name_(name), had_(std::getenv(name) != nullptr) {
        if (had_) {
            saved_ = std::getenv(name_);
        }
    }
    ~EnvGuard() {
        if (had_) {
            setenv(name_, saved_.c_str(), 1);
        } else {
            unsetenv(name_);
        }
    }

private:
    const char* name_;
    bool had_;
    std::string saved_;
};

void testIsValidListenPortBoundaries() {
    EXPECT_TRUE(!isValidListenPort(0));
    EXPECT_TRUE(isValidListenPort(1));
    EXPECT_TRUE(isValidListenPort(65535));
    EXPECT_TRUE(!isValidListenPort(65536));
}

void testHostPortWellFormedEndpoint() {
    EXPECT_TRUE(hostPortIsWellFormedEndpoint("203.0.113.1", 48333));
    EXPECT_TRUE(hostPortIsWellFormedEndpoint("[2001:db8::1]", 48333));
    EXPECT_TRUE(hostPortIsWellFormedEndpoint("peer.example.com", 8333));
    EXPECT_TRUE(!hostPortIsWellFormedEndpoint("", 48333));
    EXPECT_TRUE(!hostPortIsWellFormedEndpoint("203.0.113.1", 0));
    EXPECT_TRUE(!hostPortIsWellFormedEndpoint("bad host!", 48333));
    EXPECT_TRUE(hostPortIsWellFormedEndpoint("2001:db8::dead:beef", 48333));
    EXPECT_TRUE(!hostPortIsWellFormedEndpoint("2001:db8::g", 48333));
}

void testNormalizePeerManualSpecFormats() {
    const auto plain = normalizePeerManualSpec("203.0.113.10", 48333);
    EXPECT_TRUE(plain.has_value());
    EXPECT_EQ(plain->first, "203.0.113.10");
    EXPECT_EQ(plain->second, 48333);

    const auto withPort = normalizePeerManualSpec("203.0.113.11:48444", 48333);
    EXPECT_TRUE(withPort.has_value());
    EXPECT_EQ(withPort->second, 48444);

    const auto ipv6 = normalizePeerManualSpec("[2001:db8::2]:48333", 48333);
    EXPECT_TRUE(ipv6.has_value());
    EXPECT_EQ(ipv6->first, "2001:db8::2");

    const auto ipv6DefaultPort = normalizePeerManualSpec("[2001:db8::3]", 48333);
    EXPECT_TRUE(ipv6DefaultPort.has_value());
    EXPECT_EQ(ipv6DefaultPort->second, 48333);

    const auto trimmed = normalizePeerManualSpec("  203.0.113.12  ", 48333);
    EXPECT_TRUE(trimmed.has_value());
    EXPECT_EQ(trimmed->first, "203.0.113.12");

    EXPECT_TRUE(!normalizePeerManualSpec("", 48333).has_value());
    EXPECT_TRUE(!normalizePeerManualSpec("[2001:db8::1", 48333).has_value());
    EXPECT_TRUE(!normalizePeerManualSpec("203.0.113.1:99999", 48333).has_value());
    EXPECT_TRUE(!normalizePeerManualSpec("[2001:db8::1]extra", 48333).has_value());
}

void testSplitManualPeerListFiltersInvalid() {
    const auto peers = splitManualPeerList("203.0.113.1:48333, bad!, 203.0.113.2", 48333);
    EXPECT_EQ(peers.size(), 2u);
    EXPECT_EQ(peers[0].first, "203.0.113.1");
    EXPECT_EQ(peers[1].first, "203.0.113.2");
}

void testSettingsFromEnvReadsOverrides() {
    EnvGuard chain("CHAIN");
    EnvGuard dataDir("DATA_DIR");
    EnvGuard listen("LISTEN");
    setenv("CHAIN", "testnet4", 1);
    setenv("DATA_DIR", "/tmp/cpbitnode-test-data", 1);
    setenv("LISTEN", "1", 1);
    const Settings settings = Settings::fromEnv();
    EXPECT_EQ(settings.chain, "testnet4");
    EXPECT_EQ(settings.dataDir, "/tmp/cpbitnode-test-data");
    EXPECT_TRUE(settings.listen);
}

void testSettingsFromArgsParsesFlags() {
    const auto dir = (std::filesystem::temp_directory_path() / "cpbitnode_settings_args").string();
    std::vector<std::string> argsStore = {"cpbitnode", "--datadir", dir, "--chain", "testnet4", "--sync-only"};
    std::vector<char*> argv;
    argv.reserve(argsStore.size());
    for (auto& arg : argsStore) {
        argv.push_back(arg.data());
    }
    const Settings settings = Settings::fromArgs(static_cast<int>(argv.size()), argv.data());
    EXPECT_EQ(settings.dataDir, dir);
    EXPECT_EQ(settings.chain, "testnet4");
    EXPECT_TRUE(settings.syncOnly);
}

void testSettingsFromArgsHelpThrows() {
    std::vector<std::string> argsStore = {"cpbitnode", "--help"};
    std::vector<char*> argv = {argsStore[0].data(), argsStore[1].data()};
    bool threw = false;
    try {
        (void)Settings::fromArgs(2, argv.data());
    } catch (const std::runtime_error& exc) {
        threw = std::string(exc.what()).find("usage:") != std::string::npos;
    }
    EXPECT_TRUE(threw);
}

void testSettingsFromSyncArgsParsesBlocksFlags() {
    std::vector<std::string> argsStore = {"cpbitnode-sync", "--blocks-target", "100", "--blocks-max", "32",
                                          "--connect-only", "--rebuild"};
    std::vector<char*> argv;
    for (auto& arg : argsStore) {
        argv.push_back(arg.data());
    }
    const Settings settings = Settings::fromSyncArgs(static_cast<int>(argv.size()), argv.data());
    EXPECT_EQ(settings.blocksTargetHeight, 100);
    EXPECT_EQ(settings.blocksMaxPerRun, 32);
    EXPECT_TRUE(settings.setConnectOnly);
    EXPECT_TRUE(settings.rebuildValidatedChain);
}

void testSettingsResolvedPaths() {
    Settings settings;
    settings.dataDir = "/tmp/cpbitnode-data/";
    EXPECT_EQ(settings.resolvedDbPath(), "/tmp/cpbitnode-data/cpbitnode.db");
    EXPECT_EQ(settings.blocksDir(), "/tmp/cpbitnode-data/blocks");
    settings.dbPath = "/custom/path.db";
    EXPECT_EQ(settings.resolvedDbPath(), "/custom/path.db");
}

void testNormalizePeerManualSpecIpv6DefaultPort() {
    const auto ipv6 = normalizePeerManualSpec("[2001:db8::1]", 48333);
    EXPECT_TRUE(ipv6.has_value());
    EXPECT_EQ(ipv6->first, "2001:db8::1");
    EXPECT_EQ(ipv6->second, 48333);
}

void testNormalizePeerManualSpecIpv6InvalidRest() {
    EXPECT_TRUE(!normalizePeerManualSpec("[2001:db8::1]extra", 48333).has_value());
    EXPECT_TRUE(!normalizePeerManualSpec("[2001:db8::1]:99999", 48333).has_value());
}

void testHostPortRejectsAmbiguousMappedIpv6() {
    EXPECT_TRUE(!hostPortIsWellFormedEndpoint("::ffff:8849", 48333));
}

void testSettingsFromEnvBoolVariants() {
    EnvGuard listen("LISTEN");
    EnvGuard skip("SKIP_GETADDR");
    setenv("LISTEN", "yes", 1);
    setenv("SKIP_GETADDR", "on", 1);
    const Settings settings = Settings::fromEnv();
    EXPECT_TRUE(settings.listen);
    EXPECT_TRUE(settings.skipGetaddr);
}

void testSettingsFromEnvNumericOverrides() {
    EnvGuard port("P2P_PORT");
    EnvGuard metrics("METRICS_HTTP_PORT");
    setenv("P2P_PORT", "48333", 1);
    setenv("METRICS_HTTP_PORT", "9090", 1);
    const Settings settings = Settings::fromEnv();
    EXPECT_EQ(settings.p2pPort, 48333);
    EXPECT_EQ(settings.metricsHttpPort, 9090);
}

void testSettingsFromArgsDbAndListenFlags() {
    const auto dir = (std::filesystem::temp_directory_path() / "cpbitnode_settings_db_listen").string();
    std::vector<std::string> argsStore = {"cpbitnode", "--db", "/tmp/custom.db", "--listen"};
    std::vector<char*> argv;
    for (auto& arg : argsStore) {
        argv.push_back(arg.data());
    }
    const Settings settings = Settings::fromArgs(static_cast<int>(argv.size()), argv.data());
    EXPECT_EQ(settings.dbPath, "/tmp/custom.db");
    EXPECT_TRUE(settings.listen);
    (void)dir;
}

void testSettingsFromSyncArgsHelpThrows() {
    std::vector<std::string> argsStore = {"cpbitnode-sync", "--help"};
    std::vector<char*> argv = {argsStore[0].data(), argsStore[1].data()};
    bool threw = false;
    try {
        (void)Settings::fromSyncArgs(2, argv.data());
    } catch (const std::runtime_error& exc) {
        threw = std::string(exc.what()).find("cpbitnode-sync") != std::string::npos;
    }
    EXPECT_TRUE(threw);
}

void testSettingsBlocksDirStripsTrailingSlash() {
    Settings settings;
    settings.dataDir = "/tmp/cpbitnode-data///";
    EXPECT_EQ(settings.blocksDir(), "/tmp/cpbitnode-data/blocks");
}
void testSettingsLightweightOutboundHandshake() {
    Settings settings;
    EXPECT_TRUE(!settings.lightweightOutboundHandshake());
    settings.noHeaderRefresh = true;
    EXPECT_TRUE(settings.lightweightOutboundHandshake());
    settings.noHeaderRefresh = false;
    settings.syncSkipHeaders = true;
    EXPECT_TRUE(settings.lightweightOutboundHandshake());
}

}  // namespace

void registerEndpointSettingsTests() {
    RUN_TEST(testIsValidListenPortBoundaries);
    RUN_TEST(testHostPortWellFormedEndpoint);
    RUN_TEST(testNormalizePeerManualSpecFormats);
    RUN_TEST(testSplitManualPeerListFiltersInvalid);
    RUN_TEST(testSettingsFromEnvReadsOverrides);
    RUN_TEST(testSettingsFromArgsParsesFlags);
    RUN_TEST(testSettingsFromArgsHelpThrows);
    RUN_TEST(testSettingsFromSyncArgsParsesBlocksFlags);
    RUN_TEST(testSettingsResolvedPaths);
    RUN_TEST(testNormalizePeerManualSpecIpv6DefaultPort);
    RUN_TEST(testNormalizePeerManualSpecIpv6InvalidRest);
    RUN_TEST(testHostPortRejectsAmbiguousMappedIpv6);
    RUN_TEST(testSettingsFromEnvBoolVariants);
    RUN_TEST(testSettingsFromEnvNumericOverrides);
    RUN_TEST(testSettingsFromArgsDbAndListenFlags);
    RUN_TEST(testSettingsFromSyncArgsHelpThrows);
    RUN_TEST(testSettingsBlocksDirStripsTrailingSlash);
    RUN_TEST(testSettingsLightweightOutboundHandshake);
}
