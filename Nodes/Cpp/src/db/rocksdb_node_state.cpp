#include "cpbitnode/db/node_state.hpp"

#include "cpbitnode/db/codec_v2.hpp"
#include "cpbitnode/messages/block_header.hpp"
#include "cpbitnode/util/json.hpp"
#include "cpbitnode/wire/capabilities.hpp"

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <iomanip>
#include <sstream>
#include <stdexcept>
#include <string_view>
#include <thread>
#include <unordered_map>

#include <rocksdb/cache.h>
#include <rocksdb/db.h>
#include <rocksdb/filter_policy.h>
#include <rocksdb/iterator.h>
#include <rocksdb/options.h>
#include <rocksdb/table.h>
#include <rocksdb/version.h>
#include <rocksdb/write_batch.h>

namespace cpbitnode::db {
namespace {

constexpr std::string_view kDefaultChain = "testnet4";
constexpr std::size_t kRocksDbBlockCacheBytes = 512ULL * 1024ULL * 1024ULL;
constexpr std::size_t kRocksDbWriteBufferBytes = 64ULL * 1024ULL * 1024ULL;
constexpr int kRocksDbMaxWriteBuffers = 4;
constexpr int kRocksDbMaxBackgroundJobs = 4;

std::string utcNow() {
    const auto now = std::chrono::system_clock::now();
    const auto t = std::chrono::system_clock::to_time_t(now);
    std::tm tm{};
    gmtime_r(&t, &tm);
    std::ostringstream oss;
    oss << std::put_time(&tm, "%Y-%m-%dT%H:%M:%S") << "+00:00";
    return oss.str();
}

std::string padInt(int value) {
    std::ostringstream out;
    out << std::setw(10) << std::setfill('0') << value;
    return out.str();
}

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
    std::vector<std::uint8_t> out;
    out.reserve(hex.size() / 2);
    for (std::size_t index = 0; index + 1 < hex.size(); index += 2) {
        out.push_back(static_cast<std::uint8_t>(std::stoi(hex.substr(index, 2), nullptr, 16)));
    }
    return out;
}

std::string txidDisplayHex(const std::vector<std::uint8_t>& txid) {
    std::string out;
    out.reserve(txid.size() * 2);
    for (auto it = txid.rbegin(); it != txid.rend(); ++it) {
        static const char* kHex = "0123456789abcdef";
        out.push_back(kHex[(*it >> 4) & 0xf]);
        out.push_back(kHex[*it & 0xf]);
    }
    return out;
}

std::vector<std::uint8_t> displayHexToInternal(const std::string& txid) {
    auto bytes = hexToBytes(txid);
    std::reverse(bytes.begin(), bytes.end());
    return bytes;
}

std::vector<std::string> splitLines(const std::string& encoded) {
    std::vector<std::string> lines;
    std::istringstream in(encoded);
    std::string line;
    while (std::getline(in, line)) {
        lines.push_back(line);
    }
    return lines;
}

std::string encodeMap(const std::map<std::string, std::string>& fields) {
    std::ostringstream out;
    for (const auto& [key, value] : fields) {
        out << key << '\t' << value.size() << '\t' << value << '\n';
    }
    return out.str();
}

std::map<std::string, std::string> decodeMap(const std::string& encoded) {
    std::map<std::string, std::string> fields;
    std::size_t pos = 0;
    while (pos < encoded.size()) {
        const auto tab1 = encoded.find('\t', pos);
        if (tab1 == std::string::npos) {
            break;
        }
        const auto tab2 = encoded.find('\t', tab1 + 1);
        if (tab2 == std::string::npos) {
            break;
        }
        const auto key = encoded.substr(pos, tab1 - pos);
        const auto len = static_cast<std::size_t>(std::stoull(encoded.substr(tab1 + 1, tab2 - tab1 - 1)));
        const auto valueStart = tab2 + 1;
        fields[key] = encoded.substr(valueStart, len);
        pos = valueStart + len;
        if (pos < encoded.size() && encoded[pos] == '\n') {
            ++pos;
        }
    }
    return fields;
}

std::string jsonStringMap(const std::map<std::string, std::string>& raw) {
    std::map<std::string, std::string> fields;
    for (const auto& [key, value] : raw) {
        fields[key] = util::jsonString(value);
    }
    return util::jsonObject(fields);
}

std::string jsonMapOfStringMaps(const std::map<std::string, std::map<std::string, std::string>>& raw) {
    std::map<std::string, std::string> fields;
    for (const auto& [key, value] : raw) {
        fields[key] = jsonStringMap(value);
    }
    return util::jsonObject(fields);
}

std::string encodeUtxo(const StoredUtxo& utxo) {
    return encodeMap({
        {"txid", txidDisplayHex(utxo.txid)},
        {"vout", std::to_string(utxo.vout)},
        {"height", std::to_string(utxo.height)},
        {"value", std::to_string(utxo.value)},
        {"script_pubkey", bytesToHex(utxo.scriptPubkey)},
        {"coinbase", utxo.coinbase ? "1" : "0"},
    });
}

StoredUtxo decodeUtxo(const std::string& encoded) {
    const auto fields = decodeMap(encoded);
    StoredUtxo utxo;
    utxo.txid = displayHexToInternal(fields.at("txid"));
    utxo.vout = std::stoi(fields.at("vout"));
    utxo.height = std::stoi(fields.at("height"));
    utxo.value = std::stoll(fields.at("value"));
    utxo.scriptPubkey = hexToBytes(fields.at("script_pubkey"));
    utxo.coinbase = fields.at("coinbase") == "1";
    return utxo;
}

std::string encodeUndo(const std::vector<StoredUtxo>& entries) {
    std::ostringstream out;
    for (const auto& entry : entries) {
        const auto encoded = encodeUtxo(entry);
        out << encoded.size() << '\n' << encoded;
    }
    return out.str();
}

std::vector<StoredUtxo> decodeUndo(const std::string& encoded) {
    std::vector<StoredUtxo> entries;
    std::size_t pos = 0;
    while (pos < encoded.size()) {
        const auto nl = encoded.find('\n', pos);
        if (nl == std::string::npos) {
            break;
        }
        const auto len = static_cast<std::size_t>(std::stoull(encoded.substr(pos, nl - pos)));
        const auto valueStart = nl + 1;
        entries.push_back(decodeUtxo(encoded.substr(valueStart, len)));
        pos = valueStart + len;
    }
    return entries;
}

StoredBlockRow decodeBlockRow(const std::string& encoded) {
    const auto fields = decodeMap(encoded);
    StoredBlockRow row;
    row.height = std::stoi(fields.at("height"));
    row.blockHash = fields.at("block_hash");
    row.fileName = fields.at("file_name");
    row.fileOffset = std::stoi(fields.at("file_offset"));
    row.size = std::stoi(fields.at("size"));
    return row;
}

int blockFileNumber(const std::string& fileName) {
    if (fileName.rfind("blk", 0) != 0) {
        return 0;
    }
    const auto dot = fileName.find('.');
    const auto number = fileName.substr(3, dot == std::string::npos ? std::string::npos : dot - 3);
    return number.empty() ? 0 : std::stoi(number);
}

std::string encodeBlockRow(const StoredBlockRow& row) {
    return codec_v2::encodeBlockIndexValue(codec_v2::displayHexToInternal(row.blockHash), blockFileNumber(row.fileName),
                                           row.fileOffset, row.size);
}

void checkStatus(const rocksdb::Status& status, const std::string& action) {
    if (!status.ok()) {
        throw std::runtime_error(action + ": " + status.ToString());
    }
}

bool keyStartsWith(const rocksdb::Slice& key, const std::string& prefix) {
    return key.size() >= prefix.size() && std::string_view(key.data(), prefix.size()) == prefix;
}

struct DbOutpointKey {
    std::vector<std::uint8_t> txid;
    int vout = 0;

    bool operator==(const DbOutpointKey& other) const { return vout == other.vout && txid == other.txid; }
};

struct DbOutpointKeyHash {
    std::size_t operator()(const DbOutpointKey& key) const {
        std::size_t hash = static_cast<std::size_t>(key.vout);
        for (const auto byte : key.txid) {
            hash = hash * 131 + byte;
        }
        return hash;
    }
};

class RocksDbNodeStateStore final : public NodeStateStore {
public:
    explicit RocksDbNodeStateStore(const std::filesystem::path& path) : path_(path.string()) {
        std::filesystem::create_directories(path);
        rocksdb::Options options;
        options.create_if_missing = true;
        options.write_buffer_size = kRocksDbWriteBufferBytes;
        options.max_write_buffer_number = kRocksDbMaxWriteBuffers;
        options.max_background_jobs = kRocksDbMaxBackgroundJobs;
        options.IncreaseParallelism(options.max_background_jobs);
        options.OptimizeLevelStyleCompaction();
        rocksdb::BlockBasedTableOptions tableOptions;
        tableOptions.block_cache = rocksdb::NewLRUCache(kRocksDbBlockCacheBytes);
        tableOptions.filter_policy.reset(rocksdb::NewBloomFilterPolicy(10, false));
        options.table_factory.reset(rocksdb::NewBlockBasedTableFactory(tableOptions));
        disableWal_ = envFlag("CPBITNODE_ROCKSDB_DISABLE_WAL");
#if ROCKSDB_MAJOR >= 10
        checkStatus(rocksdb::DB::Open(options, path_, &db_), "open rocksdb node state");
#else
        rocksdb::DB* raw = nullptr;
        checkStatus(rocksdb::DB::Open(options, path_, &raw), "open rocksdb node state");
        db_.reset(raw);
#endif
        const auto codec = getCodecMetadata("codec_version");
        if (!codec.has_value()) {
            if (hasAnyRecord()) {
                throw std::runtime_error(
                    "incompatible Cpp RocksDB chainstate generation: missing codec_version=2 metadata; rebuild required");
            }
            initializeCodecMetadata();
            seedPhases();
        } else if (*codec != "2") {
            throw std::runtime_error("unsupported Cpp RocksDB codec_version=" + *codec + "; rebuild required");
        }
        activeChain_ = getCodecMetadata("chain").value_or(std::string(kDefaultChain));
        initializeCachedState();
    }

    NodeStateMetadata nodeStateMetadata() const override {
        NodeStateMetadata meta;
        meta.backendName = "rocksdb";
        meta.backendPath = path_;
        meta.status = getCodecMetadata("status").value_or("usable");
        meta.generationId = getCodecMetadata("generation_id").value_or("");
        meta.schemaVersion = getCodecMetadata("schema_version").value_or("2");
        return meta;
    }

    void setMeta(const std::string& key, const std::string& value) override {
        checkStatus(db_->Put(writeOptions(), codec_v2::keyMetadata("user." + key), codec_v2::encodeMetadataValue(value)),
                    "write meta");
    }

    std::optional<std::string> getMeta(const std::string& key) const override {
        return getCodecMetadata("user." + key);
    }

    void updatePhase(const std::string& phase, const std::optional<std::string>& status = std::nullopt,
                     const std::optional<std::string>& notes = std::nullopt) override {
        auto row = phaseRow(phase);
        if (!row.has_value()) {
            throw std::runtime_error("Unknown phase " + phase);
        }
        if (status) {
            (*row)["status"] = *status;
        }
        if (notes) {
            (*row)["notes"] = *notes;
        }
        (*row)["updated_at"] = utcNow();
        checkStatus(db_->Put(writeOptions(), phaseKey(phase), encodeMap(*row)), "write phase");
    }

    std::vector<std::map<std::string, std::string>> listPhases() const override {
        return listMapPrefix("phase/");
    }

    void logEvent(const std::string& category, const std::string& message, const std::string& level = "info",
                  const std::string& detailsJson = "{}") override {
        const int next = nextCounter("counter/event_id");
        checkStatus(db_->Put(writeOptions(), "event/" + padInt(next),
                             encodeMap({{"id", std::to_string(next)},
                                        {"category", category},
                                        {"level", level},
                                        {"message", message},
                                        {"details_json", detailsJson},
                                        {"created_at", utcNow()}})),
                    "write event");
    }

    void upsertSyncState(const std::string& chain, std::optional<int> bestHeight = std::nullopt,
                         const std::optional<std::string>& bestHash = std::nullopt,
                         std::optional<int> headerCount = std::nullopt,
                         const std::optional<std::string>& syncStatus = std::nullopt) override {
        auto row = getSyncState(chain).value_or(std::map<std::string, std::string>{
            {"chain", chain}, {"best_height", "0"}, {"best_hash", ""}, {"header_count", "0"},
            {"sync_status", "starting"}});
        if (bestHeight) {
            row["best_height"] = std::to_string(*bestHeight);
        }
        if (bestHash) {
            row["best_hash"] = *bestHash;
        }
        if (headerCount) {
            row["header_count"] = std::to_string(*headerCount);
        }
        if (syncStatus) {
            row["sync_status"] = *syncStatus;
        }
        row["updated_at"] = utcNow();
        checkStatus(db_->Put(writeOptions(), "sync/" + chain, encodeMap(row)), "write sync state");
    }

    std::optional<std::map<std::string, std::string>> getSyncState(const std::string& chain) const override {
        return getMap("sync/" + chain);
    }

    int recordPeerConnected(const std::string& host, int port, const std::string& userAgent = "",
                            const std::string& direction = "outbound") override {
        const int id = nextCounter("counter/peer_id");
        checkStatus(db_->Put(writeOptions(), "peer/" + padInt(id),
                             encodeMap({{"id", std::to_string(id)},
                                        {"host", host},
                                        {"port", std::to_string(port)},
                                        {"connected_at", utcNow()},
                                        {"disconnected_at", ""},
                                        {"direction", direction},
                                        {"services", "0"},
                                        {"peer_version", "0"},
                                        {"user_agent", userAgent},
                                        {"start_height", "0"},
                                        {"last_seen_at", utcNow()},
                                        {"ban_score", "0"},
                                        {"status", "connected"}})),
                    "write peer");
        return id;
    }

    void recordPeerDisconnected(int peerId) override {
        auto row = getMap("peer/" + padInt(peerId));
        if (!row) {
            return;
        }
        (*row)["disconnected_at"] = utcNow();
        (*row)["status"] = "disconnected";
        checkStatus(db_->Put(writeOptions(), "peer/" + padInt(peerId), encodeMap(*row)), "disconnect peer");
    }

    void touchPeer(int peerId) override {
        auto row = getMap("peer/" + padInt(peerId));
        if (!row) {
            return;
        }
        (*row)["last_seen_at"] = utcNow();
        checkStatus(db_->Put(writeOptions(), "peer/" + padInt(peerId), encodeMap(*row)), "touch peer");
    }

    void recordPeerAddress(const std::string& host, int port, std::uint64_t services = 0,
                           const std::string& source = "addr") override {
        const auto key = peerAddressKey(host, port);
        auto row = getMap(key).value_or(std::map<std::string, std::string>{{"ban_score", "0"}});
        row["host"] = host;
        row["port"] = std::to_string(port);
        row["services"] = std::to_string(services);
        row["source"] = source;
        row["last_seen_at"] = utcNow();
        checkStatus(db_->Put(writeOptions(), key, encodeMap(row)), "write peer address");
    }

    int getPeerEndpointBanScore(const std::string& host, int port) const override {
        const auto row = getMap(peerAddressKey(host, port));
        return row ? std::stoi(row->at("ban_score")) : 0;
    }

    int incrementPeerBanScore(const std::string& host, int port, int delta, int peerId = 0) override {
        (void)peerId;
        const auto current = getPeerEndpointBanScore(host, port);
        const int next = std::max(0, current + delta);
        recordPeerAddress(host, port, 0, "ban");
        auto row = getMap(peerAddressKey(host, port)).value();
        row["ban_score"] = std::to_string(next);
        checkStatus(db_->Put(writeOptions(), peerAddressKey(host, port), encodeMap(row)), "write ban score");
        return next;
    }

    void decayPeerBanScore(const std::string& host, int port, int amount, int peerId = 0) override {
        (void)peerId;
        (void)incrementPeerBanScore(host, port, -amount);
    }

    std::vector<std::pair<std::string, int>> listPeerAddressEndpoints(int limit = 32) const override {
        std::vector<std::pair<std::string, int>> endpoints;
        for (const auto& row : listMapPrefix("peeraddr/")) {
            if (static_cast<int>(endpoints.size()) >= limit) {
                break;
            }
            endpoints.push_back({row.at("host"), std::stoi(row.at("port"))});
        }
        return endpoints;
    }

    void recordHeader(int height, const std::string& blockHash, const std::string& prevHash, int timestamp,
                      const std::string& headerSerializedHex = "") override {
        recordHeaders({HeaderRecord{height, blockHash, prevHash, timestamp, headerSerializedHex}});
    }

    void recordHeaders(const std::vector<HeaderRecord>& headers) override {
        if (headers.empty()) {
            return;
        }
        rocksdb::WriteBatch batch;
        int nextHeaderCount = cachedHeaderCount_;
        for (const auto& header : headers) {
            (void)header.blockHash;
            (void)header.prevHash;
            (void)header.timestamp;
            const auto serialized = header.headerSerializedHex.empty()
                                        ? std::vector<std::uint8_t>{}
                                        : codec_v2::hexToBytes(header.headerSerializedHex);
            batch.Put(headerHeightKey(header.height), codec_v2::encodeHeaderValue(serialized));
            nextHeaderCount = std::max(nextHeaderCount, header.height + 1);
        }
        setCounter(batch, "counter/header_count", nextHeaderCount);
        checkStatus(db_->Write(writeOptions(), &batch), "write headers");
        cachedHeaderCount_ = nextHeaderCount;
        for (const auto& header : headers) {
            cachedHeaderHashes_[header.height] = header.blockHash;
            cachedMaxHeaderHeight_ = std::max(cachedMaxHeaderHeight_, header.height);
        }
    }

    std::optional<int> lookupHeaderHeight(const std::string& blockHashHex) const override {
        const auto target = codec_v2::displayHexToInternal(blockHashHex);
        std::unique_ptr<rocksdb::Iterator> it(db_->NewIterator(rocksdb::ReadOptions()));
        const auto prefix = headerPrefix();
        for (it->Seek(prefix); it->Valid() && keyStartsWith(it->key(), prefix); it->Next()) {
            const auto serialized = codec_v2::decodeHeaderValue(it->value().ToString());
            if (serialized.empty()) {
                continue;
            }
            const auto [header, next] = messages::deserializeBlockHeader(serialized);
            (void)next;
            if (header.blockHash() == target) {
                return codec_v2::heightFromKey(it->key().ToString());
            }
        }
        checkStatus(it->status(), "lookup header height");
        return std::nullopt;
    }

    std::optional<std::string> getHeaderSerializedHex(int height) const override {
        const auto encoded = getString(headerHeightKey(height));
        if (!encoded) {
            return std::nullopt;
        }
        const auto serialized = codec_v2::decodeHeaderValue(*encoded);
        if (serialized.empty()) {
            return std::nullopt;
        }
        return codec_v2::bytesToHex(serialized);
    }

    std::optional<StoredBlockRow> getStoredBlockForHashHex(const std::string& blockHashHex) const override {
        std::unique_ptr<rocksdb::Iterator> it(db_->NewIterator(rocksdb::ReadOptions()));
        const auto prefix = blockPrefix();
        for (it->Seek(prefix); it->Valid() && keyStartsWith(it->key(), prefix); it->Next()) {
            const auto height = codec_v2::heightFromKey(it->key().ToString());
            auto row = codec_v2::decodeBlockIndexValue(height, it->value().ToString());
            if (row.blockHash == blockHashHex) {
                return row;
            }
        }
        checkStatus(it->status(), "lookup block by hash");
        return std::nullopt;
    }

    int headerCount() const override { return cachedHeaderCount_; }
    int blockCount() const override { return countPrefix(blockPrefix()); }
    int utxoCount() const override { return cachedUtxoCount_; }
    int getValidatedHeight(const std::string& chain) const override {
        if (chain == activeChain_) {
            return cachedTipHeight_;
        }
        const auto tip = getString(codec_v2::keyTip(chain));
        if (!tip) {
            return -1;
        }
        return codec_v2::decodeTipValue(*tip).first;
    }
    std::string getValidatedHash(const std::string& chain) const override {
        if (chain == activeChain_) {
            return cachedTipHash_;
        }
        const auto tip = getString(codec_v2::keyTip(chain));
        if (!tip) {
            return "";
        }
        return codec_v2::internalToDisplayHex(codec_v2::decodeTipValue(*tip).second);
    }
    int maxHeaderHeight() const override { return cachedMaxHeaderHeight_; }

    void setValidatedTip(int height, const std::string& blockHashHex,
                         const std::string& chain = "testnet4") override {
        rocksdb::WriteBatch batch;
        batch.Put(codec_v2::keyTip(chain), codec_v2::encodeTipValue(height, codec_v2::displayHexToInternal(blockHashHex)));
        setCodecMetadata(batch, "tip_height", std::to_string(height));
        setCodecMetadata(batch, "tip_hash", blockHashHex);
        setCodecMetadata(batch, "updated_at", utcNow());
        checkStatus(db_->Write(writeOptions(), &batch), "write validated tip");
        if (chain == activeChain_) {
            cachedTipHeight_ = height;
            cachedTipHash_ = blockHashHex;
        }
    }

    void recordBlock(int height, const std::string& blockHash, const std::string& fileName, int fileOffset,
                     int size) override {
        StoredBlockRow row{height, blockHash, fileName, fileOffset, size};
        rocksdb::WriteBatch batch;
        batch.Put(blockHeightKey(height), encodeBlockRow(row));
        checkStatus(db_->Write(writeOptions(), &batch), "write block index");
    }

    void addUtxo(const std::vector<std::uint8_t>& txid, int vout, int height, std::int64_t value,
                 const std::vector<std::uint8_t>& scriptPubkey, bool coinbase) override {
        StoredUtxo utxo{txid, vout, height, value, scriptPubkey, coinbase};
        rocksdb::WriteBatch batch;
        const auto key = utxoKey(txid, vout);
        batch.Put(key, codec_v2::encodeUtxoValue(utxo));
        batch.Put(createdHeightKey(height, key), "");
        const int nextUtxoCount = cachedUtxoCount_ + 1;
        setCounter(batch, "counter/utxo_count", nextUtxoCount);
        checkStatus(db_->Write(writeOptions(), &batch), "write utxo");
        cachedUtxoCount_ = nextUtxoCount;
    }

    std::optional<StoredUtxo> getUtxo(const std::vector<std::uint8_t>& txid, int vout) const override {
        const auto encoded = getString(utxoKey(txid, vout));
        return encoded ? std::optional<StoredUtxo>(codec_v2::decodeUtxoValue(txid, vout, *encoded)) : std::nullopt;
    }

    std::vector<std::optional<StoredUtxo>> getUtxos(const std::vector<Outpoint>& outpoints) const override {
        if (outpoints.empty()) {
            return {};
        }
        std::vector<std::string> keys;
        keys.reserve(outpoints.size());
        for (const auto& outpoint : outpoints) {
            keys.push_back(utxoKey(outpoint.txid, outpoint.vout));
        }
        std::vector<rocksdb::Slice> slices;
        slices.reserve(keys.size());
        for (const auto& key : keys) {
            slices.emplace_back(key);
        }
        std::vector<std::string> values(keys.size());
        const auto statuses = db_->MultiGet(rocksdb::ReadOptions(), slices, &values);
        std::vector<std::optional<StoredUtxo>> out;
        out.reserve(outpoints.size());
        for (std::size_t index = 0; index < outpoints.size(); ++index) {
            if (statuses[index].IsNotFound()) {
                out.push_back(std::nullopt);
                continue;
            }
            checkStatus(statuses[index], "read rocksdb utxo");
            out.push_back(codec_v2::decodeUtxoValue(outpoints[index].txid, outpoints[index].vout, values[index]));
        }
        return out;
    }

    void spendUtxo(const std::vector<std::uint8_t>& txid, int vout) override {
        const auto key = utxoKey(txid, vout);
        const auto existing = getUtxo(txid, vout);
        if (!existing) {
            throw std::runtime_error("UTXO not found");
        }
        rocksdb::WriteBatch batch;
        batch.Delete(key);
        batch.Delete(createdHeightKey(existing->height, key));
        const int nextUtxoCount = std::max(0, cachedUtxoCount_ - 1);
        setCounter(batch, "counter/utxo_count", nextUtxoCount);
        checkStatus(db_->Write(writeOptions(), &batch), "delete utxo");
        cachedUtxoCount_ = nextUtxoCount;
    }

    void replaceUtxoUndo(const std::string& chain, int height, const std::vector<StoredUtxo>& entries) override {
        checkStatus(db_->Put(writeOptions(), undoKey(chain, height), codec_v2::encodeUndoValue(entries)), "write undo");
    }

    std::vector<StoredUtxo> takeUtxoUndo(const std::string& chain, int height) override {
        const auto key = undoKey(chain, height);
        const auto encoded = getString(key);
        if (!encoded) {
            throw std::runtime_error("missing rocksdb undo");
        }
        checkStatus(db_->Delete(writeOptions(), key), "delete undo");
        return codec_v2::decodeUndoValue(*encoded);
    }

    void deleteUtxosCreatedAtHeight(int height) override {
        rocksdb::WriteBatch batch;
        int deleted = 0;
        const auto prefix = createdHeightPrefix(height);
        std::unique_ptr<rocksdb::Iterator> it(db_->NewIterator(rocksdb::ReadOptions()));
        for (it->Seek(prefix); it->Valid() && keyStartsWith(it->key(), prefix); it->Next()) {
            const auto indexKey = it->key().ToString();
            const auto key = indexKey.substr(prefix.size());
            batch.Delete(key);
            batch.Delete(indexKey);
            deleted += 1;
        }
        checkStatus(it->status(), "iterate utxos by height");
        const int nextUtxoCount = std::max(0, cachedUtxoCount_ - deleted);
        setCounter(batch, "counter/utxo_count", nextUtxoCount);
        checkStatus(db_->Write(writeOptions(), &batch), "delete created utxos");
        cachedUtxoCount_ = nextUtxoCount;
    }

    void resetValidatedChain(const std::string& chain, const std::string& genesisHash) override {
        rocksdb::WriteBatch batch;
        deletePrefix(batch, utxoPrefix(chain));
        deletePrefix(batch, "utxo_by_height/");
        deletePrefix(batch, codec_v2::prefixUndo(chain));
        batch.Put(codec_v2::keyTip(chain), codec_v2::encodeTipValue(0, codec_v2::displayHexToInternal(genesisHash)));
        setCounter(batch, "counter/utxo_count", 0);
        setCodecMetadata(batch, "chain", chain);
        setCodecMetadata(batch, "network", chain);
        setCodecMetadata(batch, "tip_height", "0");
        setCodecMetadata(batch, "tip_hash", genesisHash);
        setCodecMetadata(batch, "updated_at", utcNow());
        checkStatus(db_->Write(writeOptions(), &batch), "reset validated chain");
        activeChain_ = chain;
        cachedUtxoCount_ = 0;
        cachedTipHeight_ = 0;
        cachedTipHash_ = genesisHash;
    }

    void commitBlock(const BlockCommit& commit) override {
        rocksdb::WriteBatch batch;
        std::unordered_map<DbOutpointKey, StoredUtxo, DbOutpointKeyHash> undoByOutpoint;
        for (const auto& entry : commit.undo) {
            validateTxid(entry.txid);
            undoByOutpoint[DbOutpointKey{entry.txid, entry.vout}] = entry;
        }
        for (const auto& spend : commit.spends) {
            const auto key = utxoKey(spend.txid, spend.vout);
            batch.Delete(key);
            const auto undo = undoByOutpoint.find(DbOutpointKey{spend.txid, spend.vout});
            if (undo != undoByOutpoint.end()) {
                batch.Delete(createdHeightKey(undo->second.height, key));
            }
        }
        for (const auto& create : commit.creates) {
            StoredUtxo utxo{create.txid, create.vout, create.height, create.value, create.scriptPubkey,
                            create.coinbase};
            const auto key = utxoKey(create.txid, create.vout);
            batch.Put(key, codec_v2::encodeUtxoValue(utxo));
            batch.Put(createdHeightKey(create.height, key), "");
        }
        batch.Put(undoKey(commit.chain, commit.height), codec_v2::encodeUndoValue(commit.undo));
        batch.Put(codec_v2::keyTip(commit.chain),
                  codec_v2::encodeTipValue(commit.height, codec_v2::displayHexToInternal(commit.blockHash)));
        if (commit.blockIndex.has_value()) {
            batch.Put(blockHeightKey(commit.blockIndex->height), encodeBlockRow(*commit.blockIndex));
        }
        const int nextUtxoCount = std::max(0, cachedUtxoCount_ - static_cast<int>(commit.spends.size()) +
                                                  static_cast<int>(commit.creates.size()));
        setCounter(batch, "counter/utxo_count", nextUtxoCount);
        const int validatedTotal = cachedValidatedTotal_ + 1;
        setCodecMetadata(batch, "user.metric_blocks_validated_total", std::to_string(validatedTotal));
        setCodecMetadata(batch, "tip_height", std::to_string(commit.height));
        setCodecMetadata(batch, "tip_hash", commit.blockHash);
        checkStatus(db_->Write(writeOptions(), &batch), "commit block");
        cachedUtxoCount_ = nextUtxoCount;
        cachedValidatedTotal_ = validatedTotal;
        if (commit.chain == activeChain_) {
            cachedTipHeight_ = commit.height;
            cachedTipHash_ = commit.blockHash;
        }
    }

    std::optional<std::string> getHeaderHash(int height) const override {
        const auto cached = cachedHeaderHashes_.find(height);
        if (cached != cachedHeaderHashes_.end()) {
            return cached->second;
        }
        const auto encoded = getString(headerHeightKey(height));
        if (!encoded) {
            return std::nullopt;
        }
        const auto serialized = codec_v2::decodeHeaderValue(*encoded);
        if (serialized.empty()) {
            return std::nullopt;
        }
        const auto [header, next] = messages::deserializeBlockHeader(serialized);
        (void)next;
        const auto hash = header.blockHashHex();
        cachedHeaderHashes_[height] = hash;
        return hash;
    }

    std::optional<StoredBlockRow> getBlock(int height) const override {
        const auto encoded = getString(blockHeightKey(height));
        return encoded ? std::optional<StoredBlockRow>(codec_v2::decodeBlockIndexValue(height, *encoded))
                       : std::nullopt;
    }

    int maxStoredBlockHeight() const override { return maxHeightForPrefix(blockPrefix()); }

    std::vector<int> listMissingBlockHeights(int limit = 32) const override {
        std::vector<int> missing;
        std::unique_ptr<rocksdb::Iterator> it(db_->NewIterator(rocksdb::ReadOptions()));
        const auto prefix = headerPrefix();
        for (it->Seek(prefix); it->Valid() && keyStartsWith(it->key(), prefix); it->Next()) {
            const int height = codec_v2::heightFromKey(it->key().ToString());
            if (height == 0) {
                continue;
            }
            if (!getString(blockHeightKey(height))) {
                missing.push_back(height);
                if (static_cast<int>(missing.size()) >= limit) {
                    break;
                }
            }
        }
        checkStatus(it->status(), "iterate missing blocks");
        return missing;
    }

    std::vector<std::map<std::string, std::string>> listWireCapabilities() const override {
        std::vector<std::map<std::string, std::string>> rows;
        const auto marked = wireCapabilityMap();
        for (const auto& cap : wire::capabilities()) {
            rows.push_back(wireRow(cap, marked.contains(cap.id) ? marked.at(cap.id) : (cap.implemented ? 1 : 0),
                                   getMap("wire/" + cap.id)));
        }
        return rows;
    }

    std::string wireProgressJson() const override {
        std::vector<std::string> caps;
        for (const auto& row : listWireCapabilities()) {
            std::map<std::string, std::string> fields;
            for (const auto& [key, value] : row) {
                fields[key] = util::jsonString(value);
            }
            caps.push_back(util::jsonObject(fields));
        }
        return util::jsonObject({{"summary", jsonStringMap(wireProgressSummary())},
                                 {"checkpoints", jsonMapOfStringMaps(wireProgressCheckpoints())},
                                 {"capabilities", util::jsonArray(caps)}});
    }

    void markWireCapability(const std::string& capabilityId, bool implemented,
                            const std::string& verifiedBy = "live", const std::string& notes = "") override {
        const auto* found = findWireCapability(capabilityId);
        if (found == nullptr) {
            throw std::runtime_error("Unknown wire capability " + capabilityId);
        }
        const auto row = wireRow(*found, implemented ? 1 : 0, std::nullopt, verifiedBy, notes);
        checkStatus(db_->Put(writeOptions(), "wire/" + capabilityId, encodeMap(row)), "write wire cap");
    }

    std::map<std::string, int> wireCapabilityMap() const override {
        std::map<std::string, int> out;
        for (const auto& cap : wire::capabilities()) {
            out[cap.id] = cap.implemented ? 1 : 0;
        }
        for (const auto& row : listMapPrefix("wire/")) {
            out[row.at("capability_id")] = std::stoi(row.at("implemented"));
        }
        return out;
    }

    std::map<std::string, std::string> wireProgressSummary() const override {
        return wire::fullNodeWireProgress(wireCapabilityMap());
    }

    std::map<std::string, std::map<std::string, std::string>> wireProgressCheckpoints() const override {
        return wire::checkpointStatus(wireCapabilityMap());
    }

    std::vector<std::map<std::string, std::string>> recentEvents(int limit = 20) const override {
        auto rows = listMapPrefix("event/");
        std::reverse(rows.begin(), rows.end());
        if (static_cast<int>(rows.size()) > limit) {
            rows.resize(static_cast<std::size_t>(limit));
        }
        return rows;
    }

    std::string summaryJson(const std::string& chain) const override {
        const auto state = getSyncState(chain).value_or(std::map<std::string, std::string>{});
        const auto phases = listPhases();
        const auto events = recentEvents();
        std::vector<std::string> phaseJson;
        for (const auto& row : phases) {
            std::map<std::string, std::string> fields;
            for (const auto& [key, value] : row) {
                fields[key] = util::jsonString(value);
            }
            phaseJson.push_back(util::jsonObject(fields));
        }
        std::vector<std::string> eventJson;
        for (const auto& row : events) {
            std::map<std::string, std::string> fields;
            for (const auto& [key, value] : row) {
                fields[key] = util::jsonString(value);
            }
            eventJson.push_back(util::jsonObject(fields));
        }
        return util::jsonObject({{"chain", util::jsonString(chain)},
                                 {"best_height", state.contains("best_height") ? state.at("best_height") : "0"},
                                 {"header_count", std::to_string(headerCount())},
                                 {"block_count", std::to_string(blockCount())},
                                 {"utxo_count", std::to_string(utxoCount())},
                                 {"peer_count", std::to_string(countPrefix("peer/"))},
                                 {"phases", util::jsonArray(phaseJson)},
                                 {"recent_events", util::jsonArray(eventJson)},
                                 {"wire", wireProgressJson()}});
    }

    int peerCount() const override { return countPrefix("peer/"); }

    int connectedPeerCount() const override {
        int count = 0;
        for (const auto& row : listMapPrefix("peer/")) {
            if (row.contains("status") && row.at("status") == "connected") {
                count += 1;
            }
        }
        return count;
    }

private:
    static bool envFlag(const char* name) {
        const char* raw = std::getenv(name);
        return raw != nullptr && std::string_view(raw) != "" && std::string_view(raw) != "0";
    }

    rocksdb::WriteOptions writeOptions() const {
        rocksdb::WriteOptions options;
        options.disableWAL = disableWal_;
        return options;
    }

    std::optional<std::string> getString(const std::string& key) const {
        std::string value;
        const auto status = db_->Get(rocksdb::ReadOptions(), key, &value);
        if (status.IsNotFound()) {
            return std::nullopt;
        }
        checkStatus(status, "read " + key);
        return value;
    }

    std::optional<std::map<std::string, std::string>> getMap(const std::string& key) const {
        const auto value = getString(key);
        return value ? std::optional<std::map<std::string, std::string>>(decodeMap(*value)) : std::nullopt;
    }

    std::optional<std::string> getCodecMetadata(const std::string& name) const {
        const auto raw = getString(codec_v2::keyMetadata(name));
        return raw ? std::optional<std::string>(codec_v2::decodeMetadataValue(*raw)) : std::nullopt;
    }

    static void setCodecMetadata(rocksdb::WriteBatch& batch, const std::string& name, const std::string& value) {
        batch.Put(codec_v2::keyMetadata(name), codec_v2::encodeMetadataValue(value));
    }

    bool hasAnyRecord() const {
        std::unique_ptr<rocksdb::Iterator> it(db_->NewIterator(rocksdb::ReadOptions()));
        it->SeekToFirst();
        const bool any = it->Valid();
        checkStatus(it->status(), "inspect rocksdb generation");
        return any;
    }

    void initializeCodecMetadata() {
        const auto now = utcNow();
        rocksdb::WriteBatch batch;
        setCodecMetadata(batch, "codec_version", "2");
        setCodecMetadata(batch, "backend_name", "rocksdb");
        setCodecMetadata(batch, "backend_version", rocksdb::GetRocksVersionAsString());
        setCodecMetadata(batch, "schema_version", "2");
        setCodecMetadata(batch, "chain", std::string(kDefaultChain));
        setCodecMetadata(batch, "network", std::string(kDefaultChain));
        setCodecMetadata(batch, "generation_id", "cpp-rocksdb-codec-v2-" + now);
        setCodecMetadata(batch, "status", "usable");
        setCodecMetadata(batch, "created_at", now);
        setCodecMetadata(batch, "updated_at", now);
        setCodecMetadata(batch, "tip_height", "-1");
        setCodecMetadata(batch, "tip_hash", "");
        setCodecMetadata(batch, "rocksdb_block_cache_bytes", std::to_string(kRocksDbBlockCacheBytes));
        setCodecMetadata(batch, "rocksdb_bloom_filter_bits_per_key", "10");
        setCodecMetadata(batch, "rocksdb_write_buffer_size", std::to_string(kRocksDbWriteBufferBytes));
        setCodecMetadata(batch, "rocksdb_max_write_buffer_number", std::to_string(kRocksDbMaxWriteBuffers));
        setCodecMetadata(batch, "rocksdb_max_background_jobs", std::to_string(kRocksDbMaxBackgroundJobs));
        setCodecMetadata(batch, "rocksdb_wal", disableWal_ ? "disabled" : "enabled");
        checkStatus(db_->Write(writeOptions(), &batch), "initialize codec v2 metadata");
    }

    void initializeCachedState() {
        rocksdb::WriteBatch batch;
        bool shouldPersist = false;

        const auto headerCounter = readCounter("counter/header_count");
        if (headerCounter.has_value()) {
            cachedHeaderCount_ = *headerCounter;
        } else {
            cachedHeaderCount_ = countPrefix(headerPrefix());
            setCounter(batch, "counter/header_count", cachedHeaderCount_);
            shouldPersist = true;
        }
        cachedMaxHeaderHeight_ = maxHeightForPrefix(headerPrefix());

        const auto utxoCounter = readCounter("counter/utxo_count");
        if (utxoCounter.has_value()) {
            cachedUtxoCount_ = *utxoCounter;
        } else {
            cachedUtxoCount_ = countPrefix(utxoPrefix());
            setCounter(batch, "counter/utxo_count", cachedUtxoCount_);
            shouldPersist = true;
        }

        const auto validatedTotal = getCodecMetadata("user.metric_blocks_validated_total");
        if (validatedTotal.has_value()) {
            cachedValidatedTotal_ = std::stoi(*validatedTotal);
        } else {
            cachedValidatedTotal_ = 0;
            setCodecMetadata(batch, "user.metric_blocks_validated_total", "0");
            shouldPersist = true;
        }

        const auto tip = getString(codec_v2::keyTip(activeChain_));
        if (tip.has_value()) {
            const auto decoded = codec_v2::decodeTipValue(*tip);
            cachedTipHeight_ = decoded.first;
            cachedTipHash_ = codec_v2::internalToDisplayHex(decoded.second);
        } else {
            cachedTipHeight_ = -1;
            cachedTipHash_.clear();
        }

        if (shouldPersist) {
            checkStatus(db_->Write(writeOptions(), &batch), "initialize cached counters");
        }
    }

    std::vector<std::map<std::string, std::string>> listMapPrefix(const std::string& prefix) const {
        std::vector<std::map<std::string, std::string>> rows;
        std::unique_ptr<rocksdb::Iterator> it(db_->NewIterator(rocksdb::ReadOptions()));
        for (it->Seek(prefix); it->Valid() && keyStartsWith(it->key(), prefix); it->Next()) {
            rows.push_back(decodeMap(it->value().ToString()));
        }
        checkStatus(it->status(), "iterate " + prefix);
        return rows;
    }

    int countPrefix(const std::string& prefix) const {
        int count = 0;
        std::unique_ptr<rocksdb::Iterator> it(db_->NewIterator(rocksdb::ReadOptions()));
        for (it->Seek(prefix); it->Valid() && keyStartsWith(it->key(), prefix); it->Next()) {
            count += 1;
        }
        checkStatus(it->status(), "count " + prefix);
        return count;
    }

    int maxHeightForPrefix(const std::string& prefix) const {
        int maxHeight = -1;
        std::unique_ptr<rocksdb::Iterator> it(db_->NewIterator(rocksdb::ReadOptions()));
        for (it->Seek(prefix); it->Valid() && keyStartsWith(it->key(), prefix); it->Next()) {
            maxHeight = std::max(maxHeight, codec_v2::heightFromKey(it->key().ToString()));
        }
        checkStatus(it->status(), "max height " + prefix);
        return maxHeight;
    }

    int nextCounter(const std::string& key) {
        const int next = std::stoi(getString(key).value_or("0")) + 1;
        checkStatus(db_->Put(writeOptions(), key, std::to_string(next)), "write counter");
        return next;
    }

    std::optional<int> readCounter(const std::string& key) const {
        const auto raw = getString(key);
        if (!raw) {
            return std::nullopt;
        }
        return std::stoi(*raw);
    }

    static void setCounter(rocksdb::WriteBatch& batch, const std::string& key, int value) {
        batch.Put(key, std::to_string(std::max(0, value)));
    }

    void deletePrefix(rocksdb::WriteBatch& batch, const std::string& prefix) {
        std::unique_ptr<rocksdb::Iterator> it(db_->NewIterator(rocksdb::ReadOptions()));
        for (it->Seek(prefix); it->Valid() && keyStartsWith(it->key(), prefix); it->Next()) {
            batch.Delete(it->key());
        }
        checkStatus(it->status(), "delete prefix " + prefix);
    }

    void seedPhases() {
        const std::vector<std::map<std::string, std::string>> rows = {
            phaseSeed("phase0", "Wire + handshake", "in_progress", "Message framing, version/verack, Docker scaffold"),
            phaseSeed("phase1", "Header sync", "pending", "Block locator, header chain persistence"),
            phaseSeed("phase2", "Block download", "pending", "Parallel getdata, raw block storage"),
            phaseSeed("phase3", "Consensus validation", "pending", "PoW, merkle root, and script verification"),
            phaseSeed("phase4", "Mempool + relay", "pending", "Tx admission and rebroadcast"),
            phaseSeed("phase5", "Hardening", "pending", "Metrics, peer banning, optional BIP324"),
        };
        rocksdb::WriteBatch batch;
        for (const auto& row : rows) {
            batch.Put(phaseKey(row.at("phase")), encodeMap(row));
        }
        checkStatus(db_->Write(writeOptions(), &batch), "seed phases");
    }

    static std::map<std::string, std::string> phaseSeed(const std::string& phase, const std::string& title,
                                                        const std::string& status, const std::string& notes) {
        return {{"phase", phase}, {"title", title}, {"status", status}, {"notes", notes}, {"updated_at", utcNow()}};
    }

    std::optional<std::map<std::string, std::string>> phaseRow(const std::string& phase) const {
        return getMap(phaseKey(phase));
    }

    static std::string phaseKey(const std::string& phase) { return "phase/" + phase; }
    std::string activeChain() const { return activeChain_; }
    std::string utxoPrefix() const { return utxoPrefix(activeChain()); }
    static std::string utxoPrefix(const std::string& chain) { return codec_v2::prefixUtxo(chain); }
    std::string headerPrefix() const { return codec_v2::prefixHeader(activeChain()); }
    std::string blockPrefix() const { return codec_v2::prefixBlockIndex(activeChain()); }
    std::string headerHeightKey(int height) const { return codec_v2::keyHeader(activeChain(), height); }
    std::string blockHeightKey(int height) const { return codec_v2::keyBlockIndex(activeChain(), height); }
    static std::string peerAddressKey(const std::string& host, int port) {
        return "peeraddr/" + host + "/" + std::to_string(port);
    }
    std::string utxoKey(const std::vector<std::uint8_t>& txid, int vout) const {
        validateTxid(txid);
        return codec_v2::keyUtxo(activeChain(), txid, vout);
    }
    static void validateTxid(const std::vector<std::uint8_t>& txid) {
        if (txid.size() != 32) {
            throw std::invalid_argument("txid must be 32 bytes");
        }
    }
    static std::string createdHeightPrefix(int height) { return "utxo_by_height/" + padInt(height) + "/"; }
    static std::string createdHeightKey(int height, const std::string& key) {
        return createdHeightPrefix(height) + key;
    }
    static std::string undoKey(const std::string& chain, int height) {
        return codec_v2::keyUndo(chain, height);
    }

    static const wire::WireCapability* findWireCapability(const std::string& id) {
        for (const auto& cap : wire::capabilities()) {
            if (cap.id == id) {
                return &cap;
            }
        }
        return nullptr;
    }

    static std::map<std::string, std::string> wireRow(
        const wire::WireCapability& cap, int implemented,
        const std::optional<std::map<std::string, std::string>>& stored = std::nullopt,
        const std::string& verifiedBy = "code", const std::string& notes = "") {
        auto row = stored.value_or(std::map<std::string, std::string>{});
        row["capability_id"] = cap.id;
        row["checkpoint"] = cap.checkpoint;
        row["category"] = cap.category;
        row["name"] = cap.name;
        row["description"] = cap.description;
        row["required"] = cap.required ? "1" : "0";
        row["implemented"] = std::to_string(implemented);
        if (!row.contains("verified_by") || !verifiedBy.empty()) {
            row["verified_by"] = verifiedBy;
        }
        if (!row.contains("verified_at") || !verifiedBy.empty()) {
            row["verified_at"] = utcNow();
        }
        if (!row.contains("notes") || !notes.empty()) {
            row["notes"] = notes;
        }
        return row;
    }

    std::string path_;
    std::unique_ptr<rocksdb::DB> db_;
    bool disableWal_ = false;
    std::string activeChain_ = std::string(kDefaultChain);
    int cachedHeaderCount_ = 0;
    int cachedUtxoCount_ = 0;
    int cachedValidatedTotal_ = 0;
    int cachedTipHeight_ = -1;
    std::string cachedTipHash_;
    int cachedMaxHeaderHeight_ = -1;
    mutable std::unordered_map<int, std::string> cachedHeaderHashes_;
};

}  // namespace

std::unique_ptr<NodeStateStore> openRocksDbNodeStateStore(const std::string& dataDir) {
    return std::make_unique<RocksDbNodeStateStore>(std::filesystem::path(dataDir) / "chainstate-rocksdb");
}

}  // namespace cpbitnode::db
