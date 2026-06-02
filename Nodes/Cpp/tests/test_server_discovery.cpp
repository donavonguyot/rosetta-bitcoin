#include "test_support.hpp"

#include "cpbitnode/chain/params.hpp"
#include "cpbitnode/config/settings.hpp"
#include "cpbitnode/db/tracker.hpp"
#include "cpbitnode/p2p/discovery.hpp"
#include "cpbitnode/p2p/server.hpp"
#include "cpbitnode/storage/blocks.hpp"

#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>

#include <filesystem>
#include <set>

void registerServerDiscoveryTests();

namespace {

using cpbitnode::chain::testnet4;
using cpbitnode::config::Settings;
using cpbitnode::db::ProjectTracker;
using cpbitnode::p2p::bootstrapPeerTargets;
using cpbitnode::p2p::mergePeerCandidates;
using cpbitnode::p2p::resolveSeedFallback;
using cpbitnode::p2p::resolveSeedPeers;
using cpbitnode::p2p::startInboundListener;
using cpbitnode::p2p::startInboundServer;
using cpbitnode::p2p::stopInboundServer;

int pickEphemeralPort() {
    const int fd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }
    const int opt = 1;
    ::setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = 0;
    if (::bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
        ::close(fd);
        return -1;
    }
    socklen_t len = sizeof(addr);
    ::getsockname(fd, reinterpret_cast<sockaddr*>(&addr), &len);
    const int port = ntohs(addr.sin_port);
    ::close(fd);
    return port;
}

void testResolveSeedPeersEmptyWhenNoSeeds() {
    auto params = testnet4();
    params.dnsSeeds.clear();
    EXPECT_EQ(resolveSeedPeers(params, 4).size(), 0u);
}

void testResolveSeedFallbackThrowsWhenEmpty() {
    auto params = testnet4();
    params.dnsSeeds.clear();
    bool threw = false;
    try {
        (void)resolveSeedFallback(params);
    } catch (const std::runtime_error& exc) {
        threw = std::string(exc.what()).find("No DNS seed peers resolved") != std::string::npos;
    }
    EXPECT_TRUE(threw);
}

void testMergePeerCandidatesFiltersLoopback() {
    const auto merged = mergePeerCandidates(testnet4(), {{"127.0.0.1", 48333}, {"203.0.113.9", 48333}}, {}, {}, {});
    EXPECT_EQ(merged.size(), 1u);
    EXPECT_EQ(merged[0].first, "203.0.113.9");
}

void testBootstrapPeerTargetsUsesInjectedSeedsWhenEmpty() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_boot_seeds.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    Settings settings;
    settings.maxOutboundPeers = 2;
    const auto targets = bootstrapPeerTargets(
        tracker, testnet4(), settings, {},
        [](const cpbitnode::chain::ChainParams&, int count) {
            return std::vector<std::pair<std::string, int>>{{"203.0.113.20", 48333},
                                                            {"203.0.113.21", 48333},
                                                            {"203.0.113.22", 48333}};
        });
    EXPECT_EQ(targets.size(), 3u);
}

void testStartInboundListenerDisabledWithoutListenFlag() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_inbound_off.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    Settings settings;
    settings.listen = false;
    EXPECT_EQ(startInboundListener(testnet4(), tracker, settings), -1);
}

void testStartInboundListenerBindsWhenEnabled() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_inbound_on.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    Settings settings;
    settings.listen = true;
    settings.p2pPort = pickEphemeralPort();
    const int fd = startInboundListener(testnet4(), tracker, settings);
    EXPECT_TRUE(fd >= 0);
    ::close(fd);
}

void testStartInboundServerStartsAndStops() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_inbound_srv.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    cpbitnode::storage::BlockStore blockStore((path.parent_path() / "blocks_inbound_srv").string(),
                                              testnet4().magic);
    Settings settings;
    settings.listen = true;
    settings.p2pPort = pickEphemeralPort();
    auto handle = startInboundServer(testnet4(), tracker, settings, blockStore, nullptr, {});
    EXPECT_TRUE(handle.listenFd >= 0);
    stopInboundServer(handle);
    EXPECT_EQ(handle.listenFd, -1);
}

void testStartInboundListenerBindFailureWhenPortInUse() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_inbound_busy.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    const int port = pickEphemeralPort();
    EXPECT_TRUE(port > 0);
    const int blocker = ::socket(AF_INET, SOCK_STREAM, 0);
    EXPECT_TRUE(blocker >= 0);
    const int opt = 1;
    ::setsockopt(blocker, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(static_cast<std::uint16_t>(port));
    EXPECT_TRUE(::bind(blocker, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == 0);
    EXPECT_TRUE(::listen(blocker, 1) == 0);

    Settings settings;
    settings.listen = true;
    settings.p2pPort = port;
    EXPECT_EQ(startInboundListener(testnet4(), tracker, settings), -1);
    ::close(blocker);
}

void testStartInboundServerReturnsInvalidFdWhenListenDisabled() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_srv_off.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    cpbitnode::storage::BlockStore blockStore((path.parent_path() / "blocks_srv_off").string(), testnet4().magic);
    Settings settings;
    settings.listen = false;
    auto handle = startInboundServer(testnet4(), tracker, settings, blockStore, nullptr, {});
    EXPECT_EQ(handle.listenFd, -1);
    stopInboundServer(handle);
}

}  // namespace

void registerServerDiscoveryTests() {
    RUN_TEST(testResolveSeedPeersEmptyWhenNoSeeds);
    RUN_TEST(testResolveSeedFallbackThrowsWhenEmpty);
    RUN_TEST(testMergePeerCandidatesFiltersLoopback);
    RUN_TEST(testBootstrapPeerTargetsUsesInjectedSeedsWhenEmpty);
    RUN_TEST(testStartInboundListenerDisabledWithoutListenFlag);
    RUN_TEST(testStartInboundListenerBindsWhenEnabled);
    RUN_TEST(testStartInboundServerStartsAndStops);
    RUN_TEST(testStartInboundListenerBindFailureWhenPortInUse);
    RUN_TEST(testStartInboundServerReturnsInvalidFdWhenListenDisabled);
}
