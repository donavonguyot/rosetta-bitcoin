#include "cpbitnode/db/node_state.hpp"

#include "cpbitnode/util/json.hpp"
#include "cpbitnode/wire/capabilities.hpp"

#include <algorithm>
#include <chrono>
#include <filesystem>
#include <iomanip>
#include <sstream>
#include <stdexcept>
#include <string_view>

#ifdef CPBITNODE_USE_ROCKSDB
#include <rocksdb/db.h>
#include <rocksdb/iterator.h>
#include <rocksdb/options.h>
#include <rocksdb/version.h>
#include <rocksdb/write_batch.h>
#endif

namespace cpbitnode::db {
namespace {

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
        {"txid", utxo.txid},
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
    utxo.txid = fields.at("txid");
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

std::string encodeBlockRow(const StoredBlockRow& row) {
    return encodeMap({
        {"height", std::to_string(row.height)},
        {"block_hash", row.blockHash},
        {"file_name", row.fileName},
        {"file_offset", std::to_string(row.fileOffset)},
        {"size", std::to_string(row.size)},
        {"received_at", utcNow()},
    });
}

#ifdef CPBITNODE_USE_ROCKSDB
void checkStatus(const rocksdb::Status& status, const std::string& action) {
    if (!status.ok()) {
        throw std::runtime_error(action + ": " + status.ToString());
    }
}

bool keyStartsWith(const rocksdb::Slice& key, const std::string& prefix) {
    return key.size() >= prefix.size() && std::string_view(key.data(), prefix.size()) == prefix;
}

class RocksDbNodeStateStore final : public NodeStateStore {
public:
    explicit RocksDbNodeStateStore(const std::filesystem::path& path) : path_(path.string()) {
        std::filesystem::create_directories(path);
        rocksdb::Options options;
        options.create_if_missing = true;
#if ROCKSDB_MAJOR >= 10
        checkStatus(rocksdb::DB::Open(options, path_, &db_), "open rocksdb node state");
#else
        rocksdb::DB* raw = nullptr;
        checkStatus(rocksdb::DB::Open(options, path_, &raw), "open rocksdb node state");
        db_.reset(raw);
#endif
        std::string generation;
        const auto status = db_->Get(rocksdb::ReadOptions(), "meta/generation_id", &generation);
        if (status.IsNotFound()) {
            generation = "rocksdb-cpp";
            checkStatus(db_->Put(rocksdb::WriteOptions(), "meta/generation_id", generation),
                        "write rocksdb generation");
            checkStatus(db_->Put(rocksdb::WriteOptions(), "meta/schema_version", "1"), "write rocksdb schema");
            seedPhases();
        } else {
            checkStatus(status, "read rocksdb generation");
        }
    }

    NodeStateMetadata nodeStateMetadata() const override {
        NodeStateMetadata meta;
        meta.backendName = "rocksdb";
        meta.backendPath = path_;
        meta.status = "usable";
        meta.generationId = getString("meta/generation_id").value_or("");
        meta.schemaVersion = getString("meta/schema_version").value_or("1");
        return meta;
    }

    void setMeta(const std::string& key, const std::string& value) override {
        checkStatus(db_->Put(rocksdb::WriteOptions(), "meta/user/" + key, value), "write meta");
    }

    std::optional<std::string> getMeta(const std::string& key) const override {
        return getString("meta/user/" + key);
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
        checkStatus(db_->Put(rocksdb::WriteOptions(), phaseKey(phase), encodeMap(*row)), "write phase");
    }

    std::vector<std::map<std::string, std::string>> listPhases() const override {
        return listMapPrefix("phase/");
    }

    void logEvent(const std::string& category, const std::string& message, const std::string& level = "info",
                  const std::string& detailsJson = "{}") override {
        const int next = nextCounter("counter/event_id");
        checkStatus(db_->Put(rocksdb::WriteOptions(), "event/" + padInt(next),
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
        checkStatus(db_->Put(rocksdb::WriteOptions(), "sync/" + chain, encodeMap(row)), "write sync state");
    }

    std::optional<std::map<std::string, std::string>> getSyncState(const std::string& chain) const override {
        return getMap("sync/" + chain);
    }

    int recordPeerConnected(const std::string& host, int port, const std::string& userAgent = "",
                            const std::string& direction = "outbound") override {
        const int id = nextCounter("counter/peer_id");
        checkStatus(db_->Put(rocksdb::WriteOptions(), "peer/" + padInt(id),
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
        checkStatus(db_->Put(rocksdb::WriteOptions(), "peer/" + padInt(peerId), encodeMap(*row)), "disconnect peer");
    }

    void touchPeer(int peerId) override {
        auto row = getMap("peer/" + padInt(peerId));
        if (!row) {
            return;
        }
        (*row)["last_seen_at"] = utcNow();
        checkStatus(db_->Put(rocksdb::WriteOptions(), "peer/" + padInt(peerId), encodeMap(*row)), "touch peer");
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
        checkStatus(db_->Put(rocksdb::WriteOptions(), key, encodeMap(row)), "write peer address");
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
        checkStatus(db_->Put(rocksdb::WriteOptions(), peerAddressKey(host, port), encodeMap(row)), "write ban score");
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
        const auto row = encodeMap({{"height", std::to_string(height)},
                                    {"block_hash", blockHash},
                                    {"prev_hash", prevHash},
                                    {"timestamp", std::to_string(timestamp)},
                                    {"received_at", utcNow()},
                                    {"header_serialized_hex", headerSerializedHex}});
        rocksdb::WriteBatch batch;
        batch.Put(headerHeightKey(height), row);
        batch.Put("header/by_hash/" + blockHash, std::to_string(height));
        checkStatus(db_->Write(rocksdb::WriteOptions(), &batch), "write header");
    }

    std::optional<int> lookupHeaderHeight(const std::string& blockHashHex) const override {
        const auto raw = getString("header/by_hash/" + blockHashHex);
        return raw ? std::optional<int>(std::stoi(*raw)) : std::nullopt;
    }

    std::optional<std::string> getHeaderSerializedHex(int height) const override {
        const auto row = getMap(headerHeightKey(height));
        if (!row || !row->contains("header_serialized_hex") || row->at("header_serialized_hex").empty()) {
            return std::nullopt;
        }
        return row->at("header_serialized_hex");
    }

    std::optional<StoredBlockRow> getStoredBlockForHashHex(const std::string& blockHashHex) const override {
        const auto height = getString("block/by_hash/" + blockHashHex);
        if (!height) {
            return std::nullopt;
        }
        return getBlock(std::stoi(*height));
    }

    int headerCount() const override { return countPrefix("header/by_height/"); }
    int blockCount() const override { return countPrefix("block/by_height/"); }
    int utxoCount() const override { return countPrefix("utxo/"); }
    int getValidatedHeight(const std::string& chain) const override {
        return std::stoi(getString("tip/" + chain + "/height").value_or("-1"));
    }
    std::string getValidatedHash(const std::string& chain) const override {
        return getString("tip/" + chain + "/hash").value_or("");
    }
    int maxHeaderHeight() const override { return maxHeightForPrefix("header/by_height/"); }

    void setValidatedTip(int height, const std::string& blockHashHex,
                         const std::string& chain = "testnet4") override {
        rocksdb::WriteBatch batch;
        batch.Put("tip/" + chain + "/height", std::to_string(height));
        batch.Put("tip/" + chain + "/hash", blockHashHex);
        checkStatus(db_->Write(rocksdb::WriteOptions(), &batch), "write validated tip");
    }

    void recordBlock(int height, const std::string& blockHash, const std::string& fileName, int fileOffset,
                     int size) override {
        StoredBlockRow row{height, blockHash, fileName, fileOffset, size};
        rocksdb::WriteBatch batch;
        batch.Put(blockHeightKey(height), encodeBlockRow(row));
        batch.Put("block/by_hash/" + blockHash, std::to_string(height));
        checkStatus(db_->Write(rocksdb::WriteOptions(), &batch), "write block index");
    }

    void addUtxo(const std::vector<std::uint8_t>& txid, int vout, int height, std::int64_t value,
                 const std::vector<std::uint8_t>& scriptPubkey, bool coinbase) override {
        if (txid.size() != 32) {
            throw std::invalid_argument("txid must be 32 bytes");
        }
        StoredUtxo utxo{txidDisplayHex(txid), vout, height, value, scriptPubkey, coinbase};
        checkStatus(db_->Put(rocksdb::WriteOptions(), utxoKey(txid, vout), encodeUtxo(utxo)), "write utxo");
    }

    std::optional<StoredUtxo> getUtxo(const std::vector<std::uint8_t>& txid, int vout) const override {
        const auto encoded = getString(utxoKey(txid, vout));
        return encoded ? std::optional<StoredUtxo>(decodeUtxo(*encoded)) : std::nullopt;
    }

    void spendUtxo(const std::vector<std::uint8_t>& txid, int vout) override {
        const auto key = utxoKey(txid, vout);
        if (!getString(key)) {
            throw std::runtime_error("UTXO not found");
        }
        checkStatus(db_->Delete(rocksdb::WriteOptions(), key), "delete utxo");
    }

    void replaceUtxoUndo(const std::string& chain, int height, const std::vector<StoredUtxo>& entries) override {
        checkStatus(db_->Put(rocksdb::WriteOptions(), undoKey(chain, height), encodeUndo(entries)), "write undo");
    }

    std::vector<StoredUtxo> takeUtxoUndo(const std::string& chain, int height) override {
        const auto key = undoKey(chain, height);
        const auto encoded = getString(key);
        if (!encoded) {
            throw std::runtime_error("missing rocksdb undo");
        }
        checkStatus(db_->Delete(rocksdb::WriteOptions(), key), "delete undo");
        return decodeUndo(*encoded);
    }

    void deleteUtxosCreatedAtHeight(int height) override {
        rocksdb::WriteBatch batch;
        std::unique_ptr<rocksdb::Iterator> it(db_->NewIterator(rocksdb::ReadOptions()));
        for (it->Seek("utxo/"); it->Valid() && keyStartsWith(it->key(), "utxo/"); it->Next()) {
            if (decodeUtxo(it->value().ToString()).height == height) {
                batch.Delete(it->key());
            }
        }
        checkStatus(it->status(), "iterate utxos by height");
        checkStatus(db_->Write(rocksdb::WriteOptions(), &batch), "delete created utxos");
    }

    void resetValidatedChain(const std::string& chain, const std::string& genesisHash) override {
        rocksdb::WriteBatch batch;
        deletePrefix(batch, "utxo/");
        deletePrefix(batch, "undo/" + chain + "/");
        batch.Put("tip/" + chain + "/height", "0");
        batch.Put("tip/" + chain + "/hash", genesisHash);
        checkStatus(db_->Write(rocksdb::WriteOptions(), &batch), "reset validated chain");
    }

    std::optional<std::string> getHeaderHash(int height) const override {
        const auto row = getMap(headerHeightKey(height));
        return row ? std::optional<std::string>(row->at("block_hash")) : std::nullopt;
    }

    std::optional<StoredBlockRow> getBlock(int height) const override {
        const auto encoded = getString(blockHeightKey(height));
        return encoded ? std::optional<StoredBlockRow>(decodeBlockRow(*encoded)) : std::nullopt;
    }

    int maxStoredBlockHeight() const override { return maxHeightForPrefix("block/by_height/"); }

    std::vector<int> listMissingBlockHeights(int limit = 32) const override {
        std::vector<int> missing;
        std::unique_ptr<rocksdb::Iterator> it(db_->NewIterator(rocksdb::ReadOptions()));
        for (it->Seek("header/by_height/"); it->Valid() && keyStartsWith(it->key(), "header/by_height/");
             it->Next()) {
            const auto key = it->key().ToString();
            const int height = std::stoi(key.substr(std::string("header/by_height/").size()));
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
        checkStatus(db_->Put(rocksdb::WriteOptions(), "wire/" + capabilityId, encodeMap(row)), "write wire cap");
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

private:
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
            maxHeight = std::max(maxHeight, std::stoi(it->key().ToString().substr(prefix.size())));
        }
        checkStatus(it->status(), "max height " + prefix);
        return maxHeight;
    }

    int nextCounter(const std::string& key) {
        const int next = std::stoi(getString(key).value_or("0")) + 1;
        checkStatus(db_->Put(rocksdb::WriteOptions(), key, std::to_string(next)), "write counter");
        return next;
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
        checkStatus(db_->Write(rocksdb::WriteOptions(), &batch), "seed phases");
    }

    static std::map<std::string, std::string> phaseSeed(const std::string& phase, const std::string& title,
                                                        const std::string& status, const std::string& notes) {
        return {{"phase", phase}, {"title", title}, {"status", status}, {"notes", notes}, {"updated_at", utcNow()}};
    }

    std::optional<std::map<std::string, std::string>> phaseRow(const std::string& phase) const {
        return getMap(phaseKey(phase));
    }

    static std::string phaseKey(const std::string& phase) { return "phase/" + phase; }
    static std::string headerHeightKey(int height) { return "header/by_height/" + padInt(height); }
    static std::string blockHeightKey(int height) { return "block/by_height/" + padInt(height); }
    static std::string peerAddressKey(const std::string& host, int port) {
        return "peeraddr/" + host + "/" + std::to_string(port);
    }
    static std::string utxoKey(const std::vector<std::uint8_t>& txid, int vout) {
        return "utxo/" + txidDisplayHex(txid) + "/" + std::to_string(vout);
    }
    static std::string undoKey(const std::string& chain, int height) {
        return "undo/" + chain + "/" + std::to_string(height);
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
};
#endif

}  // namespace

std::unique_ptr<NodeStateStore> openRocksDbNodeStateStore(const std::string& dataDir) {
#ifdef CPBITNODE_USE_ROCKSDB
    return std::make_unique<RocksDbNodeStateStore>(std::filesystem::path(dataDir) / "chainstate-rocksdb");
#else
    (void)dataDir;
    throw std::runtime_error("RocksDB support is not compiled in");
#endif
}

}  // namespace cpbitnode::db
