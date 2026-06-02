#include "cpbitnode/metrics_http.hpp"

#include "cpbitnode/metrics.hpp"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cstring>
#include <sstream>
#include <string>
#include <thread>

namespace cpbitnode::metrics_http {
namespace {

constexpr const char* kContentTypeProm = "text/plain; charset=utf-8; version=0.0.4";

std::string httpResponse(int statusCode, const char* statusText, const std::string& body,
                         const char* contentType = "text/plain; charset=utf-8") {
    std::ostringstream out;
    out << "HTTP/1.1 " << statusCode << ' ' << statusText << "\r\n";
    out << "Content-Type: " << contentType << "\r\n";
    out << "Content-Length: " << body.size() << "\r\n";
    out << "Connection: close\r\n\r\n";
    out << body;
    return out.str();
}

void serveClient(int clientFd, db::ProjectTracker& tracker, const std::string& chain) {
    char buffer[4096];
    const auto n = ::recv(clientFd, buffer, sizeof(buffer) - 1, 0);
    if (n <= 0) {
        ::close(clientFd);
        return;
    }
    buffer[n] = '\0';
    const std::string request(buffer, static_cast<std::size_t>(n));
    const auto lineEnd = request.find("\r\n");
    const std::string requestLine = lineEnd == std::string::npos ? request : request.substr(0, lineEnd);
    std::string method;
    std::string path;
    {
        std::istringstream iss(requestLine);
        iss >> method >> path;
    }
    std::string responseBody;
    int statusCode = 200;
    const char* statusText = "OK";
    const char* contentType = "text/plain; charset=utf-8";
    if (method != "GET") {
        statusCode = 405;
        statusText = "Method Not Allowed";
        responseBody = "Method Not Allowed";
    } else if (path != "/metrics") {
        statusCode = 404;
        statusText = "Not Found";
        responseBody = "Not Found";
    } else {
        responseBody = metrics::prometheusExpositionFormat(tracker, chain);
        contentType = kContentTypeProm;
    }
    const auto response = httpResponse(statusCode, statusText, responseBody, contentType);
    (void)::send(clientFd, response.data(), response.size(), 0);
    ::close(clientFd);
}

}  // namespace

MetricsServerHandle startMetricsServer(const config::Settings& settings, db::ProjectTracker& tracker) {
    MetricsServerHandle handle;
    if (settings.metricsHttpPort <= 0) {
        return handle;
    }
    const int fd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return handle;
    }
    const int opt = 1;
    ::setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(static_cast<std::uint16_t>(settings.metricsHttpPort));
    if (::bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
        ::close(fd);
        return handle;
    }
    if (::listen(fd, 4) != 0) {
        ::close(fd);
        return handle;
    }
    tracker.logEvent("node",
                     "Metrics HTTP listening on 127.0.0.1:" + std::to_string(settings.metricsHttpPort), "info", "{}");
    handle.listenFd = fd;
    handle.stop = std::make_shared<std::atomic<bool>>(false);
    handle.acceptThread = std::thread([fd, stop = handle.stop, &tracker, chain = settings.chain]() {
        while (!stop->load()) {
            pollfd pfd{};
            pfd.fd = fd;
            pfd.events = POLLIN;
            if (::poll(&pfd, 1, 250) <= 0) {
                continue;
            }
            const int clientFd = ::accept(fd, nullptr, nullptr);
            if (clientFd < 0) {
                continue;
            }
            serveClient(clientFd, tracker, chain);
        }
    });
    return handle;
}

void stopMetricsServer(MetricsServerHandle& handle) {
    if (handle.stop) {
        handle.stop->store(true);
    }
    if (handle.listenFd >= 0) {
        ::shutdown(handle.listenFd, SHUT_RDWR);
        ::close(handle.listenFd);
        handle.listenFd = -1;
    }
    if (handle.acceptThread.joinable()) {
        handle.acceptThread.join();
    }
}

}  // namespace cpbitnode::metrics_http
