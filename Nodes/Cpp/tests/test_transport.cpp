#include "test_support.hpp"

#include "cpbitnode/p2p/transport.hpp"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <chrono>
#include <cstring>
#include <thread>
#include <vector>

void registerTransportTests();

namespace {

using cpbitnode::p2p::connectTcp;
using cpbitnode::p2p::wrapTcpFd;

int bindLoopbackEphemeral() {
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
    return fd;
}

int listenPort(int listenFd) {
    sockaddr_in addr{};
    socklen_t len = sizeof(addr);
    if (::getsockname(listenFd, reinterpret_cast<sockaddr*>(&addr), &len) != 0) {
        return -1;
    }
    if (::listen(listenFd, 1) != 0) {
        return -1;
    }
    return ntohs(addr.sin_port);
}

void testWrapTcpFdWriteReadRoundtrip() {
    const int listenFd = bindLoopbackEphemeral();
    EXPECT_TRUE(listenFd >= 0);
    const int port = listenPort(listenFd);
    EXPECT_TRUE(port > 0);

    std::thread server([&]() {
        const int clientFd = ::accept(listenFd, nullptr, nullptr);
        EXPECT_TRUE(clientFd >= 0);
        std::uint8_t buf[8] = {};
        const auto n = ::recv(clientFd, buf, sizeof(buf), 0);
        EXPECT_EQ(static_cast<std::size_t>(n), 4u);
        EXPECT_EQ(buf[0], 'p');
        EXPECT_EQ(buf[3], 'g');
        const char reply[] = "pong";
        (void)::send(clientFd, reply, 4, 0);
        ::close(clientFd);
        ::close(listenFd);
    });

    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(static_cast<std::uint16_t>(port));
    const int clientFd = ::socket(AF_INET, SOCK_STREAM, 0);
    EXPECT_TRUE(clientFd >= 0);
    EXPECT_TRUE(::connect(clientFd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == 0);

    auto transport = wrapTcpFd(clientFd);
    const std::vector<std::uint8_t> ping{'p', 'i', 'n', 'g'};
    transport->write(ping);
    const auto response = transport->readExact(4, 5.0);
    EXPECT_EQ(response.size(), 4u);
    EXPECT_EQ(response[0], 'p');
    EXPECT_EQ(response[3], 'g');
    transport->close();
    EXPECT_TRUE(!transport->isOpen());
    server.join();
}

void testConnectTcpLoopback() {
    const int listenFd = bindLoopbackEphemeral();
    EXPECT_TRUE(listenFd >= 0);
    const int port = listenPort(listenFd);
    EXPECT_TRUE(port > 0);

    std::thread server([&]() {
        const int clientFd = ::accept(listenFd, nullptr, nullptr);
        std::uint8_t buf[16] = {};
        (void)::recv(clientFd, buf, sizeof(buf), 0);
        const char reply[] = "ok";
        (void)::send(clientFd, reply, 2, 0);
        ::close(clientFd);
        ::close(listenFd);
    });

    auto transport = connectTcp("127.0.0.1", port, 5.0);
    transport->write(std::vector<std::uint8_t>{0x01, 0x02});
    const auto response = transport->readExact(2, 5.0);
    EXPECT_EQ(response.size(), 2u);
    EXPECT_EQ(response[0], 'o');
    transport->close();
    server.join();
}

void testReadExactTimesOutWhenIdle() {
    const int listenFd = bindLoopbackEphemeral();
    EXPECT_TRUE(listenFd >= 0);
    const int port = listenPort(listenFd);
    EXPECT_TRUE(port > 0);

    std::thread server([&]() {
        const int clientFd = ::accept(listenFd, nullptr, nullptr);
        ::close(listenFd);
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
        ::close(clientFd);
    });

    auto transport = connectTcp("127.0.0.1", port, 5.0);
    bool timedOut = false;
    try {
        (void)transport->readExact(4, 0.05);
    } catch (const std::runtime_error& exc) {
        timedOut = std::string(exc.what()) == "read timeout";
    }
    EXPECT_TRUE(timedOut);
    transport->close();
    server.join();
}

void testWrapTcpFdRejectsInvalidFd() {
    bool threw = false;
    try {
        (void)wrapTcpFd(-1);
    } catch (const std::invalid_argument&) {
        threw = true;
    }
    EXPECT_TRUE(threw);
}

void testWriteAfterCloseThrows() {
    const int listenFd = bindLoopbackEphemeral();
    const int port = listenPort(listenFd);
    std::thread server([&]() {
        const int clientFd = ::accept(listenFd, nullptr, nullptr);
        ::close(clientFd);
        ::close(listenFd);
    });
    auto transport = connectTcp("127.0.0.1", port, 5.0);
    transport->close();
    bool threw = false;
    try {
        transport->write(std::vector<std::uint8_t>{1});
    } catch (const std::runtime_error& exc) {
        threw = std::string(exc.what()) == "transport closed";
    }
    EXPECT_TRUE(threw);
    server.join();
}

void testConnectTcpConnectionRefused() {
    const int listenFd = bindLoopbackEphemeral();
    const int port = listenPort(listenFd);
    ::close(listenFd);
    bool threw = false;
    try {
        (void)connectTcp("127.0.0.1", port, 0.5);
    } catch (const std::runtime_error& exc) {
        threw = std::string(exc.what()).find("Could not connect") != std::string::npos;
    }
    EXPECT_TRUE(threw);
}

void testReadExactPeerClosedBeforeFullRead() {
    const int listenFd = bindLoopbackEphemeral();
    const int port = listenPort(listenFd);
    std::thread server([&]() {
        const int clientFd = ::accept(listenFd, nullptr, nullptr);
        const char partial[] = "ab";
        (void)::send(clientFd, partial, 2, 0);
        ::close(clientFd);
        ::close(listenFd);
    });
    auto transport = connectTcp("127.0.0.1", port, 5.0);
    bool closed = false;
    try {
        (void)transport->readExact(8, 2.0);
    } catch (const std::runtime_error& exc) {
        closed = std::string(exc.what()) == "Peer closed connection";
    }
    EXPECT_TRUE(closed);
    transport->close();
    server.join();
}

void testReadAfterCloseThrows() {
    const int listenFd = bindLoopbackEphemeral();
    const int port = listenPort(listenFd);
    std::thread server([&]() {
        const int clientFd = ::accept(listenFd, nullptr, nullptr);
        ::close(clientFd);
        ::close(listenFd);
    });
    auto transport = connectTcp("127.0.0.1", port, 5.0);
    transport->close();
    bool threw = false;
    try {
        (void)transport->readExact(1, 1.0);
    } catch (const std::runtime_error& exc) {
        threw = std::string(exc.what()) == "transport closed";
    }
    EXPECT_TRUE(threw);
    server.join();
}

}  // namespace

void registerTransportTests() {
    RUN_TEST(testWrapTcpFdWriteReadRoundtrip);
    RUN_TEST(testConnectTcpLoopback);
    RUN_TEST(testReadExactTimesOutWhenIdle);
    RUN_TEST(testWrapTcpFdRejectsInvalidFd);
    RUN_TEST(testWriteAfterCloseThrows);
    RUN_TEST(testConnectTcpConnectionRefused);
    RUN_TEST(testReadExactPeerClosedBeforeFullRead);
    RUN_TEST(testReadAfterCloseThrows);
}
