#pragma once

#include <filesystem>

namespace cpbitnode::sync {

/** Non-blocking POSIX flock on `<datadir>/.cpbitnode-sync.lock`. */
class ExclusiveDataDirSyncLock {
public:
    explicit ExclusiveDataDirSyncLock(std::filesystem::path datadir);
    ~ExclusiveDataDirSyncLock();

    ExclusiveDataDirSyncLock(const ExclusiveDataDirSyncLock&) = delete;
    ExclusiveDataDirSyncLock& operator=(const ExclusiveDataDirSyncLock&) = delete;

private:
    std::filesystem::path datadir_;
    int fd_ = -1;
};

}  // namespace cpbitnode::sync
