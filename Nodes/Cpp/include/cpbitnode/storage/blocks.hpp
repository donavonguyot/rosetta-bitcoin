#pragma once

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <span>
#include <string>
#include <vector>

namespace cpbitnode::storage {

struct BlockWriteResult {
    std::string fileName;
    int fileNumber = 0;
    std::size_t offset = 0;
    std::size_t size = 0;
};

/** Append-only block flat files (Bitcoin Core blk*.dat style). */
class BlockStore {
public:
    static constexpr std::size_t kMaxFileBytes = 128 * 1024 * 1024;

    BlockStore(std::filesystem::path blocksDir, std::span<const std::uint8_t> magic);

    BlockWriteResult write(std::span<const std::uint8_t> blockData);
    std::vector<std::uint8_t> read(const std::string& fileName, std::size_t offset, std::size_t size) const;

    bool hasDataFile(int fileNumber = 0) const;
    bool verifyMagic() const;

private:
    std::filesystem::path blocksDir_;
    std::array<std::uint8_t, 4> magic_{};
    int fileIndex_ = 0;
    std::filesystem::path filePath_;
    std::size_t offset_ = 0;

    std::filesystem::path openFile(int index);
    static std::string fileNameForIndex(int index);
};

}  // namespace cpbitnode::storage
