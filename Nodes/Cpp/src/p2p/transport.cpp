#include "cpbitnode/p2p/transport.hpp"

#include <arpa/inet.h>
#include <fcntl.h>
#include <netdb.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cerrno>
#include <cstring>
#include <stdexcept>

namespace cpbitnode::p2p {
namespace {

class TcpTransport final : public Transport {
public:
    explicit TcpTransport(int fd) : fd_(fd) {}

    ~TcpTransport() override { close(); }

    void write(std::span<const std::uint8_t> data) override {
        if (fd_ < 0) {
            throw std::runtime_error("transport closed");
        }
        std::size_t sent = 0;
        while (sent < data.size()) {
            const auto n = ::send(fd_, data.data() + sent, data.size() - sent, 0);
            if (n <= 0) {
                throw std::runtime_error("send failed");
            }
            sent += static_cast<std::size_t>(n);
        }
    }

    std::vector<std::uint8_t> readExact(std::size_t count, double timeoutSeconds) override {
        if (fd_ < 0) {
            throw std::runtime_error("transport closed");
        }
        std::vector<std::uint8_t> out;
        out.reserve(count);
        while (out.size() < count) {
            pollfd pfd{};
            pfd.fd = fd_;
            pfd.events = POLLIN;
            const int pollMs = timeoutSeconds <= 0 ? 0 : static_cast<int>(timeoutSeconds * 1000.0);
            const int ready = ::poll(&pfd, 1, pollMs);
            if (ready == 0) {
                throw std::runtime_error("read timeout");
            }
            if (ready < 0) {
                throw std::runtime_error("poll failed");
            }
            std::uint8_t buf[4096];
            const auto need = count - out.size();
            const auto toRead = std::min(need, sizeof(buf));
            const auto n = ::recv(fd_, buf, toRead, 0);
            if (n <= 0) {
                throw std::runtime_error("Peer closed connection");
            }
            out.insert(out.end(), buf, buf + n);
        }
        return out;
    }

    void close() override {
        if (fd_ >= 0) {
            ::close(fd_);
            fd_ = -1;
        }
    }

    bool isOpen() const override { return fd_ >= 0; }

private:
    int fd_ = -1;
};

int connectWithTimeout(const addrinfo& hints, const std::string& host, int port, double timeoutSeconds) {
    addrinfo* result = nullptr;
    const std::string portStr = std::to_string(port);
    if (::getaddrinfo(host.c_str(), portStr.c_str(), &hints, &result) != 0) {
        throw std::runtime_error("getaddrinfo failed for " + host);
    }

    int fd = -1;
    for (addrinfo* rp = result; rp != nullptr; rp = rp->ai_next) {
        fd = ::socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
        if (fd < 0) {
            continue;
        }
        const int flags = ::fcntl(fd, F_GETFL, 0);
        if (flags >= 0) {
            ::fcntl(fd, F_SETFL, flags | O_NONBLOCK);
        }
        const int rc = ::connect(fd, rp->ai_addr, rp->ai_addrlen);
        if (rc == 0) {
            if (flags >= 0) {
                ::fcntl(fd, F_SETFL, flags);
            }
            break;
        }
        if (errno != EINPROGRESS) {
            ::close(fd);
            fd = -1;
            continue;
        }
        pollfd pfd{};
        pfd.fd = fd;
        pfd.events = POLLOUT;
        const int pollMs = static_cast<int>(timeoutSeconds * 1000.0);
        const int ready = ::poll(&pfd, 1, pollMs);
        if (ready <= 0) {
            ::close(fd);
            fd = -1;
            continue;
        }
        int err = 0;
        socklen_t len = sizeof(err);
        if (::getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) != 0 || err != 0) {
            ::close(fd);
            fd = -1;
            continue;
        }
        if (flags >= 0) {
            ::fcntl(fd, F_SETFL, flags);
        }
        break;
    }
    ::freeaddrinfo(result);
    if (fd < 0) {
        throw std::runtime_error("Could not connect to " + host + ":" + std::to_string(port));
    }
    return fd;
}

}  // namespace

std::unique_ptr<Transport> connectTcp(const std::string& host, int port, double connectTimeoutSeconds) {
    addrinfo hints{};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    return std::make_unique<TcpTransport>(connectWithTimeout(hints, host, port, connectTimeoutSeconds));
}

std::unique_ptr<Transport> wrapTcpFd(int fd) {
    if (fd < 0) {
        throw std::invalid_argument("wrapTcpFd requires valid fd");
    }
    return std::make_unique<TcpTransport>(fd);
}

}  // namespace cpbitnode::p2p
