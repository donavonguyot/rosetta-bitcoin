#include "cpbitnode/sync/syncDatadirLock.hpp"

#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <stdexcept>
#include <sys/file.h>
#include <unistd.h>

namespace cpbitnode::sync {

ExclusiveDataDirSyncLock::ExclusiveDataDirSyncLock(std::filesystem::path datadir) : datadir_(std::move(datadir)) {
    std::filesystem::create_directories(datadir_);
    const auto lockPath = datadir_ / ".cpbitnode-sync.lock";
    fd_ = ::open(lockPath.c_str(), O_RDWR | O_CREAT, 0644);
    if (fd_ < 0) {
        throw std::runtime_error("Failed to open sync lock: " + std::string(std::strerror(errno)));
    }
    if (::flock(fd_, LOCK_EX | LOCK_NB) != 0) {
        const int err = errno;
        ::close(fd_);
        fd_ = -1;
        if (err == EACCES || err == EAGAIN) {
            throw std::runtime_error(
                "Another cpbitnode-sync holds this datadir; exit the other instance first.");
        }
        throw std::runtime_error("Failed to acquire sync lock: " + std::string(std::strerror(err)));
    }
    if (::ftruncate(fd_, 0) != 0) {
        ::flock(fd_, LOCK_UN);
        ::close(fd_);
        fd_ = -1;
        throw std::runtime_error("Failed to truncate sync lock: " + std::string(std::strerror(errno)));
    }
    const std::string pidLine = std::to_string(::getpid()) + "\n";
    (void)::write(fd_, pidLine.data(), pidLine.size());
}

ExclusiveDataDirSyncLock::~ExclusiveDataDirSyncLock() {
    if (fd_ >= 0) {
        ::flock(fd_, LOCK_UN);
        ::close(fd_);
        fd_ = -1;
    }
}

}  // namespace cpbitnode::sync
