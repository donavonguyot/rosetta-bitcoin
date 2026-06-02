#pragma once

#include "cpbitnode/config/settings.hpp"
#include "cpbitnode/db/tracker.hpp"

#include <atomic>
#include <memory>
#include <thread>

namespace cpbitnode::metrics_http {

struct MetricsServerHandle {
    int listenFd = -1;
    std::shared_ptr<std::atomic<bool>> stop = std::make_shared<std::atomic<bool>>(false);
    std::thread acceptThread;

    MetricsServerHandle() = default;
    MetricsServerHandle(MetricsServerHandle&& other) noexcept
        : listenFd(other.listenFd),
          stop(std::move(other.stop)),
          acceptThread(std::move(other.acceptThread)) {
        other.listenFd = -1;
    }
    MetricsServerHandle& operator=(MetricsServerHandle&& other) noexcept {
        if (this != &other) {
            listenFd = other.listenFd;
            stop = std::move(other.stop);
            acceptThread = std::move(other.acceptThread);
            other.listenFd = -1;
        }
        return *this;
    }
    MetricsServerHandle(const MetricsServerHandle&) = delete;
    MetricsServerHandle& operator=(const MetricsServerHandle&) = delete;
};

MetricsServerHandle startMetricsServer(const config::Settings& settings, db::ProjectTracker& tracker);
void stopMetricsServer(MetricsServerHandle& handle);

}  // namespace cpbitnode::metrics_http
