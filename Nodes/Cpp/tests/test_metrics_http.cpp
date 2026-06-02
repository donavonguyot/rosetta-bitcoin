#include "test_support.hpp"

#include "cpbitnode/config/settings.hpp"
#include "cpbitnode/db/tracker.hpp"
#include "cpbitnode/metrics.hpp"
#include "cpbitnode/metrics_http.hpp"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cstring>
#include <chrono>
#include <filesystem>
#include <thread>

void registerMetricsHttpTests();

namespace {

using cpbitnode::config::Settings;
using cpbitnode::db::ProjectTracker;
using cpbitnode::metrics_http::startMetricsServer;
using cpbitnode::metrics_http::stopMetricsServer;

int pickEphemeralPort() {
    const int fd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }
    const int opt = 1;
    ::setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    if (::bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
        ::close(fd);
        return -1;
    }
    socklen_t len = sizeof(addr);
    if (::getsockname(fd, reinterpret_cast<sockaddr*>(&addr), &len) != 0) {
        ::close(fd);
        return -1;
    }
    const int port = ntohs(addr.sin_port);
    ::close(fd);
    return port;
}

std::string httpGet(const std::string& path, int port) {
    const int fd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return {};
    }
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(static_cast<std::uint16_t>(port));
    if (::connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
        ::close(fd);
        return {};
    }
    const std::string request = "GET " + path + " HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
    (void)::send(fd, request.data(), request.size(), 0);
    std::string response;
    char buffer[512];
    while (true) {
        const ssize_t n = ::recv(fd, buffer, sizeof(buffer), 0);
        if (n <= 0) {
            break;
        }
        response.append(buffer, static_cast<std::size_t>(n));
    }
    ::close(fd);
    return response;
}

void testMetricsServerReturnsPrometheusText() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_metrics_http.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    cpbitnode::metrics::incrMetaCounter(tracker, cpbitnode::metrics::kMetaBlocksValidatedTotal, 3);

    const int port = pickEphemeralPort();
    EXPECT_TRUE(port > 0);
    Settings settings;
    settings.metricsHttpPort = port;
    settings.chain = "testnet4";
    auto handle = startMetricsServer(settings, tracker);
    EXPECT_TRUE(handle.listenFd >= 0);

    for (int attempt = 0; attempt < 50; ++attempt) {
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
        const std::string response = httpGet("/metrics", port);
        if (response.find("HTTP/1.1 200") != std::string::npos) {
            EXPECT_TRUE(response.find("text/plain; charset=utf-8; version=0.0.4") != std::string::npos);
            EXPECT_TRUE(response.find("blocks_validated_total{chain=\"testnet4\"} 3") != std::string::npos);
            EXPECT_TRUE(response.find("txs_relayed_total{chain=\"testnet4\"} 0") != std::string::npos);
            stopMetricsServer(handle);
            return;
        }
    }
    EXPECT_TRUE(false);

    stopMetricsServer(handle);
}

void testMetricsServer404UnknownPath() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_metrics_http_404.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());

    const int port = pickEphemeralPort();
    Settings settings;
    settings.metricsHttpPort = port;
    auto handle = startMetricsServer(settings, tracker);
    EXPECT_TRUE(handle.listenFd >= 0);

    for (int attempt = 0; attempt < 50; ++attempt) {
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
        const std::string response = httpGet("/health", port);
        if (response.find("HTTP/1.1 404") != std::string::npos) {
            EXPECT_TRUE(response.find("Not Found") != std::string::npos);
            stopMetricsServer(handle);
            return;
        }
    }
    EXPECT_TRUE(false);
    stopMetricsServer(handle);
}

void testMetricsServer405NonGetMethod() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_metrics_http_405.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    const int port = pickEphemeralPort();
    Settings settings;
    settings.metricsHttpPort = port;
    auto handle = startMetricsServer(settings, tracker);
    EXPECT_TRUE(handle.listenFd >= 0);
    for (int attempt = 0; attempt < 50; ++attempt) {
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
        const int fd = ::socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) {
            continue;
        }
        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        addr.sin_port = htons(static_cast<std::uint16_t>(port));
        if (::connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
            ::close(fd);
            continue;
        }
        const std::string request = "POST /metrics HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
        (void)::send(fd, request.data(), request.size(), 0);
        std::string response;
        char buffer[256];
        while (true) {
            const ssize_t n = ::recv(fd, buffer, sizeof(buffer), 0);
            if (n <= 0) {
                break;
            }
            response.append(buffer, static_cast<std::size_t>(n));
        }
        ::close(fd);
        if (response.find("HTTP/1.1 405") != std::string::npos) {
            stopMetricsServer(handle);
            return;
        }
    }
    EXPECT_TRUE(false);
    stopMetricsServer(handle);
}

void testMetricsServerEmptyRequestClosesCleanly() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_metrics_http_empty.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    const int port = pickEphemeralPort();
    Settings settings;
    settings.metricsHttpPort = port;
    auto handle = startMetricsServer(settings, tracker);
    EXPECT_TRUE(handle.listenFd >= 0);
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    const int fd = ::socket(AF_INET, SOCK_STREAM, 0);
    EXPECT_TRUE(fd >= 0);
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(static_cast<std::uint16_t>(port));
    EXPECT_TRUE(::connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == 0);
    ::close(fd);
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    stopMetricsServer(handle);
}

void testMetricsServerBindFailureWhenPortInUse() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_metrics_http_bind.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    const int port = pickEphemeralPort();
    Settings settings;
    settings.metricsHttpPort = port;
    auto first = startMetricsServer(settings, tracker);
    EXPECT_TRUE(first.listenFd >= 0);
    auto second = startMetricsServer(settings, tracker);
    EXPECT_EQ(second.listenFd, -1);
    stopMetricsServer(first);
}

void testMetricsServerDisabledWhenPortZero() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_metrics_http_off.db";
    std::filesystem::remove(path);
    ProjectTracker tracker(path.string());
    Settings settings;
    settings.metricsHttpPort = 0;
    auto handle = startMetricsServer(settings, tracker);
    EXPECT_EQ(handle.listenFd, -1);
}

}  // namespace

void registerMetricsHttpTests() {
    RUN_TEST(testMetricsServerReturnsPrometheusText);
    RUN_TEST(testMetricsServer404UnknownPath);
    RUN_TEST(testMetricsServer405NonGetMethod);
    RUN_TEST(testMetricsServerEmptyRequestClosesCleanly);
    RUN_TEST(testMetricsServerBindFailureWhenPortInUse);
    RUN_TEST(testMetricsServerDisabledWhenPortZero);
}
