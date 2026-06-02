#include "cpbitnode/storage/blocks.hpp"

#include <array>
#include <cstdint>
#include <fstream>
#include <iomanip>
#include <sstream>
#include <stdexcept>

namespace cpbitnode::storage {
namespace {

void writeUInt32LE(std::array<std::uint8_t, 4>& out, std::uint32_t value) {
    out[0] = static_cast<std::uint8_t>(value);
    out[1] = static_cast<std::uint8_t>(value >> 8);
    out[2] = static_cast<std::uint8_t>(value >> 16);
    out[3] = static_cast<std::uint8_t>(value >> 24);
}

std::uint32_t readUInt32LE(const std::uint8_t* data) {
    return static_cast<std::uint32_t>(data[0]) | (static_cast<std::uint32_t>(data[1]) << 8) |
           (static_cast<std::uint32_t>(data[2]) << 16) | (static_cast<std::uint32_t>(data[3]) << 24);
}

}  // namespace

BlockStore::BlockStore(std::filesystem::path blocksDir, std::span<const std::uint8_t> magic)
    : blocksDir_(std::move(blocksDir)) {
    if (magic.size() != 4) {
        throw std::invalid_argument("network magic must be 4 bytes");
    }
    std::copy(magic.begin(), magic.end(), magic_.begin());
    std::filesystem::create_directories(blocksDir_);
    filePath_ = openFile(fileIndex_);
    if (std::filesystem::exists(filePath_)) {
        offset_ = static_cast<std::size_t>(std::filesystem::file_size(filePath_));
    }
}

BlockWriteResult BlockStore::write(std::span<const std::uint8_t> blockData) {
    std::array<std::uint8_t, 4> sizeHeader{};
    writeUInt32LE(sizeHeader, static_cast<std::uint32_t>(blockData.size()));

    const std::size_t recordSize = 4 + 4 + blockData.size();
    if (offset_ + recordSize > kMaxFileBytes && offset_ > 0) {
        fileIndex_ += 1;
        filePath_ = openFile(fileIndex_);
        offset_ = 0;
    }

    const std::size_t offset = offset_;
    {
        std::ofstream out(filePath_, std::ios::binary | std::ios::app);
        if (!out) {
            throw std::runtime_error("failed to open block file for append: " + filePath_.string());
        }
        out.write(reinterpret_cast<const char*>(magic_.data()), static_cast<std::streamsize>(magic_.size()));
        out.write(reinterpret_cast<const char*>(sizeHeader.data()), static_cast<std::streamsize>(sizeHeader.size()));
        out.write(reinterpret_cast<const char*>(blockData.data()), static_cast<std::streamsize>(blockData.size()));
        if (!out) {
            throw std::runtime_error("failed to write block record: " + filePath_.string());
        }
    }

    offset_ += recordSize;
    return BlockWriteResult{
        .fileName = fileNameForIndex(fileIndex_),
        .fileNumber = fileIndex_,
        .offset = offset,
        .size = blockData.size(),
    };
}

std::vector<std::uint8_t> BlockStore::read(const std::string& fileName, std::size_t offset,
                                           std::size_t size) const {
    const auto path = blocksDir_ / fileName;
    std::ifstream in(path, std::ios::binary);
    if (!in) {
        throw std::runtime_error("failed to open block file for read: " + path.string());
    }

    in.seekg(static_cast<std::streamoff>(offset));
    std::array<std::uint8_t, 4> magic{};
    in.read(reinterpret_cast<char*>(magic.data()), static_cast<std::streamsize>(magic.size()));
    if (!in) {
        throw std::runtime_error("Unexpected EOF reading block magic");
    }

    std::array<std::uint8_t, 4> sizeBuf{};
    in.read(reinterpret_cast<char*>(sizeBuf.data()), static_cast<std::streamsize>(sizeBuf.size()));
    if (!in) {
        throw std::runtime_error("Unexpected EOF reading block size");
    }

    const std::uint32_t payloadSize = readUInt32LE(sizeBuf.data());
    if (payloadSize != size) {
        throw std::invalid_argument("Block size mismatch: expected " + std::to_string(size) + ", file has " +
                                    std::to_string(payloadSize));
    }
    if (magic != magic_) {
        throw std::invalid_argument("Block file magic mismatch");
    }

    std::vector<std::uint8_t> data(size);
    in.read(reinterpret_cast<char*>(data.data()), static_cast<std::streamsize>(data.size()));
    if (!in || static_cast<std::size_t>(in.gcount()) != size) {
        throw std::runtime_error("Unexpected EOF reading block");
    }
    return data;
}

bool BlockStore::hasDataFile(int fileNumber) const {
    return std::filesystem::exists(blocksDir_ / fileNameForIndex(fileNumber));
}

bool BlockStore::verifyMagic() const {
    const auto path = blocksDir_ / fileNameForIndex(0);
    if (!std::filesystem::exists(path)) {
        return true;
    }
    std::ifstream in(path, std::ios::binary);
    if (!in) {
        return false;
    }
    std::array<std::uint8_t, 4> buf{};
    in.read(reinterpret_cast<char*>(buf.data()), static_cast<std::streamsize>(buf.size()));
    return in && buf == magic_;
}

std::filesystem::path BlockStore::openFile(int index) {
    const auto path = blocksDir_ / fileNameForIndex(index);
    if (!std::filesystem::exists(path)) {
        std::ofstream out(path, std::ios::binary);
        if (!out) {
            throw std::runtime_error("failed to create block file: " + path.string());
        }
    }
    return path;
}

std::string BlockStore::fileNameForIndex(int index) {
    std::ostringstream oss;
    oss << "blk" << std::setw(5) << std::setfill('0') << index << ".dat";
    return oss.str();
}

}  // namespace cpbitnode::storage
