#include "cpbitnode/db/codec_v2.hpp"

#include <algorithm>
#include <limits>
#include <stdexcept>

namespace cpbitnode::db::codec_v2 {
namespace {

void requireBytes(const std::vector<std::uint8_t>& bytes, std::size_t size, const std::string& name) {
    if (bytes.size() != size) {
        throw std::invalid_argument(name + " must be " + std::to_string(size) + " bytes");
    }
}

void requireU32(int value, const std::string& name) {
    if (value < 0) {
        throw std::invalid_argument(name + " must be non-negative");
    }
}

void appendU32(std::string& out, std::uint32_t value) {
    out.push_back(static_cast<char>((value >> 24) & 0xff));
    out.push_back(static_cast<char>((value >> 16) & 0xff));
    out.push_back(static_cast<char>((value >> 8) & 0xff));
    out.push_back(static_cast<char>(value & 0xff));
}

void appendU64(std::string& out, std::uint64_t value) {
    for (int shift = 56; shift >= 0; shift -= 8) {
        out.push_back(static_cast<char>((value >> shift) & 0xff));
    }
}

std::uint32_t readU32(const std::string& data, std::size_t& offset) {
    if (offset + 4 > data.size()) {
        throw std::runtime_error("codec v2 u32 read past end");
    }
    const auto* raw = reinterpret_cast<const unsigned char*>(data.data() + offset);
    offset += 4;
    return (static_cast<std::uint32_t>(raw[0]) << 24) | (static_cast<std::uint32_t>(raw[1]) << 16) |
           (static_cast<std::uint32_t>(raw[2]) << 8) | static_cast<std::uint32_t>(raw[3]);
}

std::uint64_t readU64(const std::string& data, std::size_t& offset) {
    if (offset + 8 > data.size()) {
        throw std::runtime_error("codec v2 u64 read past end");
    }
    std::uint64_t value = 0;
    for (int i = 0; i < 8; ++i) {
        value = (value << 8) | static_cast<unsigned char>(data[offset + static_cast<std::size_t>(i)]);
    }
    offset += 8;
    return value;
}

void appendBytes(std::string& out, const std::vector<std::uint8_t>& bytes) {
    out.append(reinterpret_cast<const char*>(bytes.data()), bytes.size());
}

std::vector<std::uint8_t> readBytes(const std::string& data, std::size_t& offset, std::size_t size) {
    if (offset + size > data.size()) {
        throw std::runtime_error("codec v2 byte read past end");
    }
    std::vector<std::uint8_t> out(data.begin() + static_cast<std::ptrdiff_t>(offset),
                                  data.begin() + static_cast<std::ptrdiff_t>(offset + size));
    offset += size;
    return out;
}

std::string chainPrefix(char prefix, const std::string& chain) {
    if (chain.size() > 255) {
        throw std::invalid_argument("chain name too long");
    }
    std::string out;
    out.push_back(prefix);
    out.push_back(static_cast<char>(chain.size()));
    out.append(chain);
    return out;
}

std::string metadataPrefix(const std::string& name) {
    if (name.size() > 255) {
        throw std::invalid_argument("metadata name too long");
    }
    std::string out;
    out.push_back('m');
    out.push_back(static_cast<char>(name.size()));
    out.append(name);
    return out;
}

}  // namespace

std::string bytesToHex(const std::vector<std::uint8_t>& bytes) {
    static const char* kHex = "0123456789abcdef";
    std::string out;
    out.reserve(bytes.size() * 2);
    for (const auto byte : bytes) {
        out.push_back(kHex[(byte >> 4) & 0xf]);
        out.push_back(kHex[byte & 0xf]);
    }
    return out;
}

std::vector<std::uint8_t> hexToBytes(const std::string& hex) {
    if (hex.size() % 2 != 0) {
        throw std::invalid_argument("hex string has odd length");
    }
    std::vector<std::uint8_t> out;
    out.reserve(hex.size() / 2);
    for (std::size_t index = 0; index < hex.size(); index += 2) {
        out.push_back(static_cast<std::uint8_t>(std::stoi(hex.substr(index, 2), nullptr, 16)));
    }
    return out;
}

std::string internalToDisplayHex(const std::vector<std::uint8_t>& bytes) {
    auto copy = bytes;
    std::reverse(copy.begin(), copy.end());
    return bytesToHex(copy);
}

std::vector<std::uint8_t> displayHexToInternal(const std::string& hex) {
    auto bytes = hexToBytes(hex);
    std::reverse(bytes.begin(), bytes.end());
    return bytes;
}

std::string keyUtxo(const std::string& chain, const std::vector<std::uint8_t>& txid, int vout) {
    requireBytes(txid, 32, "txid");
    requireU32(vout, "vout");
    auto out = chainPrefix('u', chain);
    appendBytes(out, txid);
    appendU32(out, static_cast<std::uint32_t>(vout));
    return out;
}

std::string keyUndo(const std::string& chain, int height) {
    requireU32(height, "height");
    auto out = chainPrefix('d', chain);
    appendU32(out, static_cast<std::uint32_t>(height));
    return out;
}

std::string keyTip(const std::string& chain) {
    return chainPrefix('t', chain);
}

std::string keyMetadata(const std::string& name) {
    return metadataPrefix(name);
}

std::string keyBlockIndex(const std::string& chain, int height) {
    requireU32(height, "height");
    auto out = chainPrefix('b', chain);
    appendU32(out, static_cast<std::uint32_t>(height));
    return out;
}

std::string keyHeader(const std::string& chain, int height) {
    requireU32(height, "height");
    auto out = chainPrefix('h', chain);
    appendU32(out, static_cast<std::uint32_t>(height));
    return out;
}

std::string prefixUtxo(const std::string& chain) {
    return chainPrefix('u', chain);
}

std::string prefixUndo(const std::string& chain) {
    return chainPrefix('d', chain);
}

std::string prefixBlockIndex(const std::string& chain) {
    return chainPrefix('b', chain);
}

std::string prefixHeader(const std::string& chain) {
    return chainPrefix('h', chain);
}

std::string encodeUtxoValue(const StoredUtxo& utxo) {
    requireU32(utxo.height, "height");
    if (utxo.value < 0) {
        throw std::invalid_argument("utxo value must be non-negative");
    }
    std::string out;
    appendU32(out, static_cast<std::uint32_t>(utxo.height));
    appendU64(out, static_cast<std::uint64_t>(utxo.value));
    out.push_back(static_cast<char>(utxo.coinbase ? 1 : 0));
    appendU32(out, static_cast<std::uint32_t>(utxo.scriptPubkey.size()));
    appendBytes(out, utxo.scriptPubkey);
    return out;
}

StoredUtxo decodeUtxoValue(const std::vector<std::uint8_t>& txid, int vout, const std::string& encoded) {
    requireBytes(txid, 32, "txid");
    std::size_t offset = 0;
    StoredUtxo utxo;
    utxo.txid = txid;
    utxo.vout = vout;
    utxo.height = static_cast<int>(readU32(encoded, offset));
    utxo.value = static_cast<std::int64_t>(readU64(encoded, offset));
    if (offset >= encoded.size()) {
        throw std::runtime_error("codec v2 utxo flags read past end");
    }
    utxo.coinbase = (static_cast<unsigned char>(encoded[offset++]) & 1) != 0;
    const auto scriptSize = readU32(encoded, offset);
    utxo.scriptPubkey = readBytes(encoded, offset, scriptSize);
    if (offset != encoded.size()) {
        throw std::runtime_error("codec v2 utxo trailing bytes");
    }
    return utxo;
}

std::string encodeUndoValue(const std::vector<StoredUtxo>& entries) {
    std::string out;
    appendU32(out, static_cast<std::uint32_t>(entries.size()));
    for (const auto& entry : entries) {
        requireBytes(entry.txid, 32, "txid");
        requireU32(entry.vout, "vout");
        appendBytes(out, entry.txid);
        appendU32(out, static_cast<std::uint32_t>(entry.vout));
        out.append(encodeUtxoValue(entry));
    }
    return out;
}

std::vector<StoredUtxo> decodeUndoValue(const std::string& encoded) {
    std::size_t offset = 0;
    const auto count = readU32(encoded, offset);
    std::vector<StoredUtxo> entries;
    entries.reserve(count);
    for (std::uint32_t i = 0; i < count; ++i) {
        const auto txid = readBytes(encoded, offset, 32);
        const auto vout = static_cast<int>(readU32(encoded, offset));
        const auto valueStart = offset;
        const auto height = readU32(encoded, offset);
        (void)height;
        (void)readU64(encoded, offset);
        if (offset >= encoded.size()) {
            throw std::runtime_error("codec v2 undo flags read past end");
        }
        ++offset;
        const auto scriptSize = readU32(encoded, offset);
        offset += scriptSize;
        if (offset > encoded.size()) {
            throw std::runtime_error("codec v2 undo script read past end");
        }
        entries.push_back(decodeUtxoValue(txid, vout, encoded.substr(valueStart, offset - valueStart)));
    }
    if (offset != encoded.size()) {
        throw std::runtime_error("codec v2 undo trailing bytes");
    }
    return entries;
}

std::string encodeTipValue(int height, const std::vector<std::uint8_t>& blockHashInternal) {
    requireU32(height, "height");
    requireBytes(blockHashInternal, 32, "block hash");
    std::string out;
    appendU32(out, static_cast<std::uint32_t>(height));
    appendBytes(out, blockHashInternal);
    return out;
}

std::pair<int, std::vector<std::uint8_t>> decodeTipValue(const std::string& encoded) {
    std::size_t offset = 0;
    auto height = static_cast<int>(readU32(encoded, offset));
    auto hash = readBytes(encoded, offset, 32);
    if (offset != encoded.size()) {
        throw std::runtime_error("codec v2 tip trailing bytes");
    }
    return {height, hash};
}

std::string encodeBlockIndexValue(const std::vector<std::uint8_t>& blockHashInternal, int fileNumber, int fileOffset,
                                  int blockSize) {
    requireBytes(blockHashInternal, 32, "block hash");
    requireU32(fileNumber, "file number");
    requireU32(fileOffset, "file offset");
    requireU32(blockSize, "block size");
    std::string out;
    appendBytes(out, blockHashInternal);
    appendU32(out, static_cast<std::uint32_t>(fileNumber));
    appendU32(out, static_cast<std::uint32_t>(fileOffset));
    appendU32(out, static_cast<std::uint32_t>(blockSize));
    return out;
}

StoredBlockRow decodeBlockIndexValue(int height, const std::string& encoded) {
    std::size_t offset = 0;
    const auto hash = readBytes(encoded, offset, 32);
    const auto fileNumber = readU32(encoded, offset);
    const auto fileOffset = readU32(encoded, offset);
    const auto blockSize = readU32(encoded, offset);
    if (offset != encoded.size()) {
        throw std::runtime_error("codec v2 block index trailing bytes");
    }
    const auto number = std::to_string(fileNumber);
    const auto padding = number.size() < 5 ? std::string(5 - number.size(), '0') : std::string{};
    return StoredBlockRow{height, internalToDisplayHex(hash), "blk" + padding + number + ".dat",
                          static_cast<int>(fileOffset), static_cast<int>(blockSize)};
}

std::string encodeHeaderValue(const std::vector<std::uint8_t>& serializedHeader) {
    std::string out;
    appendU32(out, static_cast<std::uint32_t>(serializedHeader.size()));
    appendBytes(out, serializedHeader);
    return out;
}

std::vector<std::uint8_t> decodeHeaderValue(const std::string& encoded) {
    std::size_t offset = 0;
    const auto size = readU32(encoded, offset);
    auto bytes = readBytes(encoded, offset, size);
    if (offset != encoded.size()) {
        throw std::runtime_error("codec v2 header trailing bytes");
    }
    return bytes;
}

std::string encodeMetadataValue(const std::string& value) {
    return value;
}

std::string decodeMetadataValue(const std::string& encoded) {
    return encoded;
}

int heightFromKey(const std::string& key) {
    if (key.size() < 4) {
        throw std::runtime_error("codec v2 key too short for height");
    }
    std::size_t offset = key.size() - 4;
    return static_cast<int>(readU32(key, offset));
}

int voutFromUtxoKey(const std::string& key) {
    return heightFromKey(key);
}

std::vector<std::uint8_t> txidFromUtxoKey(const std::string& chain, const std::string& key) {
    const auto prefix = prefixUtxo(chain);
    if (key.size() != prefix.size() + 32 + 4 || key.rfind(prefix, 0) != 0) {
        throw std::runtime_error("codec v2 invalid utxo key");
    }
    return std::vector<std::uint8_t>(key.begin() + static_cast<std::ptrdiff_t>(prefix.size()),
                                     key.begin() + static_cast<std::ptrdiff_t>(prefix.size() + 32));
}

bool selfTestGoldenVector() {
    const auto stringHex = [](const std::string& bytes) {
        return bytesToHex(std::vector<std::uint8_t>(bytes.begin(), bytes.end()));
    };
    const std::string chain = "testnet4";
    const auto txid = hexToBytes("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f");
    const auto blockHash = hexToBytes("1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f");
    const auto script = hexToBytes("76a914000102030405060708090a0b0c0d0e0f1011121388ac");
    const StoredUtxo utxo{txid, 1, 1, 5000000000LL, script, true};
    const auto header = hexToBytes(
        "0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000");
    return stringHex(keyUtxo(chain, txid, 1)) ==
               "7508746573746e657434000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f00000001" &&
           stringHex(encodeUtxoValue(utxo)) ==
               "00000001000000012a05f200010000001976a914000102030405060708090a0b0c0d0e0f1011121388ac" &&
           stringHex(keyUndo(chain, 2)) ==
               "6408746573746e65743400000002" &&
           stringHex(encodeUndoValue({utxo})) ==
               "00000001000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f0000000100000001000000012a05f200010000001976a914000102030405060708090a0b0c0d0e0f1011121388ac" &&
           stringHex(keyTip(chain)) ==
               "7408746573746e657434" &&
           stringHex(encodeTipValue(2, blockHash)) ==
               "000000021f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f" &&
           stringHex(keyBlockIndex(chain, 2)) ==
               "6208746573746e65743400000002" &&
           stringHex(encodeBlockIndexValue(blockHash, 0, 8, 258)) ==
               "1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f000000000000000800000102" &&
           stringHex(keyHeader(chain, 2)) ==
               "6808746573746e65743400000002" &&
           stringHex(encodeHeaderValue(header)) ==
               "000000500000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" &&
           stringHex(keyMetadata("codec_version")) ==
               "6d0d636f6465635f76657273696f6e" &&
           stringHex(encodeMetadataValue("2")) ==
               "32";
}

}  // namespace cpbitnode::db::codec_v2
