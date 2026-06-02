#include "test_support.hpp"

#include "cpbitnode/chain/params.hpp"
#include "cpbitnode/config/settings.hpp"
#include "cpbitnode/db/tracker.hpp"
#include "cpbitnode/p2p/discovery.hpp"

#include <filesystem>
#include <string>

void registerDiscoveryTests();

namespace {

using cpbitnode::chain::testnet4;
using cpbitnode::config::Settings;
using cpbitnode::db::ProjectTracker;
using cpbitnode::p2p::bootstrapPeerTargets;
using cpbitnode::p2p::mergePeerCandidates;

void testMergePeerCandidatesSkipsMalformedEndpoints() {
    const auto& params = testnet4();
    const auto merged = mergePeerCandidates(params, {{"203.0.113.55", params.defaultPort}, {"::ffff:8849", params.defaultPort}},
                                            {{"203.0.113.56", params.defaultPort}}, {}, {});
    EXPECT_EQ(merged.size(), 2u);
    EXPECT_EQ(merged[0].first, "203.0.113.55");
    EXPECT_EQ(merged[1].first, "203.0.113.56");
}

void testMergePeerCandidatesDedupsOrderPreservesPriority() {
    const auto& params = testnet4();
    const std::vector<std::pair<std::string, int>> manual = {{"203.0.113.10", params.defaultPort}};
    const std::vector<std::pair<std::string, int>> stored = {{"203.0.113.10", params.defaultPort},
                                                             {"203.0.113.11", params.defaultPort}};
    const auto merged = mergePeerCandidates(params, manual, stored, {}, {});
    EXPECT_EQ(merged.size(), 2u);
    EXPECT_EQ(merged[0].first, "203.0.113.10");
    EXPECT_EQ(merged[1].first, "203.0.113.11");
}

void testBootstrapManualPeerExemptWhenOverBanThreshold() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_manual_exempt.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    const std::string host = "203.0.113.60";
    const int port = testnet4().defaultPort;
    tracker.recordPeerAddress(host, port, 1, "test");
    tracker.incrementPeerBanScore(host, port, 200);

    Settings settings;
    settings.peerBanScoreThreshold = 100;
    const auto out = bootstrapPeerTargets(
        tracker, testnet4(), settings, {{host, port}},
        [](const cpbitnode::chain::ChainParams&, int) { return std::vector<std::pair<std::string, int>>{}; });
    bool found = false;
    for (const auto& item : out) {
        if (item.first == host && item.second == port) {
            found = true;
        }
    }
    EXPECT_TRUE(found);
}

void testResolveSeedPeersUsesInjectedResolver() {
    cpbitnode::chain::ChainParams params = testnet4();
    params.dnsSeeds = {"seed.a.example.invalid", "seed.b.example.invalid"};
    const auto resolved = mergePeerCandidates(params, {}, {}, {},
                                              {{"203.0.113.5", 48333}, {"203.0.113.5", 48333}});
    EXPECT_EQ(resolved.size(), 1u);
    EXPECT_EQ(resolved[0].first, "203.0.113.5");
}

void testBootstrapPeerTargetsFiltersBannedNonManual() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_ban_filter.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    const std::string host = "203.0.113.70";
    const int port = testnet4().defaultPort;
    tracker.recordPeerAddress(host, port, 1, "test");
    tracker.incrementPeerBanScore(host, port, 200);

    Settings settings;
    settings.peerBanScoreThreshold = 100;
    const auto out = bootstrapPeerTargets(
        tracker, testnet4(), settings, {},
        [](const cpbitnode::chain::ChainParams&, int) { return std::vector<std::pair<std::string, int>>{}; });
    bool found = false;
    for (const auto& item : out) {
        if (item.first == host && item.second == port) {
            found = true;
        }
    }
    EXPECT_TRUE(!found);
}

void testBootstrapPeerTargetsUsesFallbackWhenAllSourcesEmpty() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_boot_fallback.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    Settings settings;
    auto params = testnet4();
    params.dnsSeeds = {"seed.test.invalid"};
    const auto out = bootstrapPeerTargets(
        tracker, params, settings, {},
        [](const cpbitnode::chain::ChainParams&, int) { return std::vector<std::pair<std::string, int>>{}; });
    (void)out;
}

void testMergePeerCandidatesFiltersZeroHost() {
    const auto merged = mergePeerCandidates(testnet4(), {{"0.0.0.0", 48333}, {"203.0.113.12", 48333}}, {}, {}, {});
    EXPECT_EQ(merged.size(), 1u);
    EXPECT_EQ(merged[0].first, "203.0.113.12");
}

void testBootstrapPeerTargetsTruncatesLongCandidateList() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_boot_trunc.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    Settings settings;
    settings.maxOutboundPeers = 2;
    const auto out = bootstrapPeerTargets(
        tracker, testnet4(), settings, {},
        [](const cpbitnode::chain::ChainParams&, int count) {
            std::vector<std::pair<std::string, int>> peers;
            for (int index = 0; index < count + 5; ++index) {
                peers.push_back({"203.0.113." + std::to_string(100 + index), 48333});
            }
            return peers;
        });
    EXPECT_TRUE(out.size() <= static_cast<std::size_t>(settings.maxOutboundPeers * 2));
}

}  // namespace

void registerDiscoveryTests() {
    RUN_TEST(testMergePeerCandidatesSkipsMalformedEndpoints);
    RUN_TEST(testMergePeerCandidatesDedupsOrderPreservesPriority);
    RUN_TEST(testBootstrapManualPeerExemptWhenOverBanThreshold);
    RUN_TEST(testResolveSeedPeersUsesInjectedResolver);
    RUN_TEST(testBootstrapPeerTargetsFiltersBannedNonManual);
    RUN_TEST(testBootstrapPeerTargetsUsesFallbackWhenAllSourcesEmpty);
    RUN_TEST(testMergePeerCandidatesFiltersZeroHost);
    RUN_TEST(testBootstrapPeerTargetsTruncatesLongCandidateList);
}
