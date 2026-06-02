#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <span>
#include <string>
#include <vector>

namespace cpbitnode::p2p {

/** Abstract byte stream for P2P wire I/O (mockable in tests). */
class Transport {
public:
    virtual ~Transport() = default;

    virtual void write(std::span<const std::uint8_t> data) = 0;
    virtual std::vector<std::uint8_t> readExact(std::size_t count, double timeoutSeconds) = 0;
    virtual void close() = 0;
    virtual bool isOpen() const = 0;
};

std::unique_ptr<Transport> connectTcp(const std::string& host, int port, double connectTimeoutSeconds = 10.0);

/** Wrap an already-connected TCP socket fd (e.g. from accept()). */
std::unique_ptr<Transport> wrapTcpFd(int fd);

}  // namespace cpbitnode::p2p
