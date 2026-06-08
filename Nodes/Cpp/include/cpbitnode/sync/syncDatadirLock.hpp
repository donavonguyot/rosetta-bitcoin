#pragma once

#include <filesystem>

namespace cpbitnode::sync {

/**
 * Single-writer datadir lock for sync/connect/rebuild.
 *
 * This protects runtime truth, not just operator ergonomics: overlapping writers can create lost
 * UTXO or undo mutations that later look like consensus validation blockers.
 */
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
