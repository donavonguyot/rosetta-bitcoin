#include "cpbitnode/db/chainstate.hpp"

#include <algorithm>
#include <filesystem>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string_view>
#include <utility>

#ifdef CPBITNODE_USE_ROCKSDB
#include <rocksdb/db.h>
#include <rocksdb/iterator.h>
#include <rocksdb/options.h>
#include <rocksdb/version.h>
#include <rocksdb/write_batch.h>
#endif

namespace cpbitnode::db {
namespace {

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

std::string encodeUtxo(const StoredUtxo& utxo) {
    std::ostringstream out;
    out << utxo.txid << '\n'
        << utxo.vout << '\n'
        << utxo.height << '\n'
        << utxo.value << '\n'
        << (utxo.coinbase ? 1 : 0) << '\n'
        << bytesToHex(utxo.scriptPubkey);
    return out.str();
}

StoredUtxo decodeUtxo(const std::string& encoded) {
    std::istringstream in(encoded);
    StoredUtxo utxo;
    std::string line;
    std::getline(in, utxo.txid);
    std::getline(in, line);
    utxo.vout = std::stoi(line);
    std::getline(in, line);
    utxo.height = std::stoi(line);
    std::getline(in, line);
    utxo.value = std::stoll(line);
    std::getline(in, line);
    utxo.coinbase = line == "1";
    std::getline(in, line);
    utxo.scriptPubkey = hexToBytes(line);
    return utxo;
}

std::string encodeUndo(const std::vector<StoredUtxo>& entries) {
    std::ostringstream out;
    for (const auto& entry : entries) {
        out << encodeUtxo(entry) << "\n---\n";
    }
    return out.str();
}

std::vector<StoredUtxo> decodeUndo(const std::string& encoded) {
    std::vector<StoredUtxo> entries;
    std::string current;
    std::istringstream in(encoded);
    std::string line;
    while (std::getline(in, line)) {
        if (line == "---") {
            if (!current.empty()) {
                entries.push_back(decodeUtxo(current));
                current.clear();
            }
            continue;
        }
        current += line;
        current += '\n';
    }
    if (!current.empty()) {
        entries.push_back(decodeUtxo(current));
    }
    return entries;
}

std::string utxoKey(const std::vector<std::uint8_t>& txid, int vout) {
    return "utxo/" + txidDisplayHex(txid) + "/" + std::to_string(vout);
}

std::string undoKey(const std::string& chain, int height) {
    return "undo/" + chain + "/" + std::to_string(height);
}

std::string tipHeightKey(const std::string& chain) {
    return "tip/" + chain + "/height";
}

std::string tipHashKey(const std::string& chain) {
    return "tip/" + chain + "/hash";
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

class RocksDbChainstateStore final : public ChainstateStore {
public:
    explicit RocksDbChainstateStore(const std::filesystem::path& path) : path_(path.string()) {
        std::filesystem::create_directories(path);
        rocksdb::Options options;
        options.create_if_missing = true;
#if ROCKSDB_MAJOR >= 10
        checkStatus(rocksdb::DB::Open(options, path_, &db_), "open rocksdb chainstate");
#else
        rocksdb::DB* raw = nullptr;
        checkStatus(rocksdb::DB::Open(options, path_, &raw), "open rocksdb chainstate");
        db_.reset(raw);
#endif
        std::string generation;
        const auto status = db_->Get(rocksdb::ReadOptions(), "meta/generation_id", &generation);
        if (status.IsNotFound()) {
            generation = "rocksdb-cpp";
            checkStatus(db_->Put(rocksdb::WriteOptions(), "meta/generation_id", generation),
                        "write rocksdb generation");
            checkStatus(db_->Put(rocksdb::WriteOptions(), "meta/schema_version", "1"), "write rocksdb schema");
        } else {
            checkStatus(status, "read rocksdb generation");
        }
    }

    ChainstateMetadata metadata() const override {
        ChainstateMetadata meta;
        meta.backendName = "rocksdb";
        meta.backendPath = path_;
        meta.status = "usable";
        db_->Get(rocksdb::ReadOptions(), "meta/generation_id", &meta.generationId);
        db_->Get(rocksdb::ReadOptions(), "meta/schema_version", &meta.schemaVersion);
        if (meta.schemaVersion.empty()) {
            meta.schemaVersion = "1";
        }
        return meta;
    }

    ChainstateTip readTip(const std::string& chain) const override {
        std::string height;
        std::string hash;
        if (db_->Get(rocksdb::ReadOptions(), tipHeightKey(chain), &height).ok()) {
            db_->Get(rocksdb::ReadOptions(), tipHashKey(chain), &hash);
            return ChainstateTip{std::stoi(height), hash};
        }
        return ChainstateTip{-1, ""};
    }

    void setTip(const std::string& chain, int height, const std::string& blockHashHex) override {
        rocksdb::WriteBatch batch;
        batch.Put(tipHeightKey(chain), std::to_string(height));
        batch.Put(tipHashKey(chain), blockHashHex);
        checkStatus(db_->Write(rocksdb::WriteOptions(), &batch), "write rocksdb tip");
    }

    int utxoCount() const override {
        int count = 0;
        std::unique_ptr<rocksdb::Iterator> it(db_->NewIterator(rocksdb::ReadOptions()));
        for (it->Seek("utxo/"); it->Valid() && keyStartsWith(it->key(), "utxo/"); it->Next()) {
            count += 1;
        }
        checkStatus(it->status(), "iterate rocksdb utxos");
        return count;
    }

    std::optional<StoredUtxo> getUtxo(const std::vector<std::uint8_t>& txid, int vout) const override {
        std::string value;
        const auto status = db_->Get(rocksdb::ReadOptions(), utxoKey(txid, vout), &value);
        if (status.IsNotFound()) {
            return std::nullopt;
        }
        checkStatus(status, "read rocksdb utxo");
        return decodeUtxo(value);
    }

    void addUtxo(const std::vector<std::uint8_t>& txid, int vout, int height, std::int64_t value,
                 const std::vector<std::uint8_t>& scriptPubkey, bool coinbase) override {
        StoredUtxo utxo{txidDisplayHex(txid), vout, height, value, scriptPubkey, coinbase};
        checkStatus(db_->Put(rocksdb::WriteOptions(), utxoKey(txid, vout), encodeUtxo(utxo)),
                    "write rocksdb utxo");
    }

    void spendUtxo(const std::vector<std::uint8_t>& txid, int vout) override {
        checkStatus(db_->Delete(rocksdb::WriteOptions(), utxoKey(txid, vout)), "delete rocksdb utxo");
    }

    void replaceUtxoUndo(const std::string& chain, int height, const std::vector<StoredUtxo>& entries) override {
        checkStatus(db_->Put(rocksdb::WriteOptions(), undoKey(chain, height), encodeUndo(entries)),
                    "write rocksdb undo");
    }

    std::vector<StoredUtxo> takeUtxoUndo(const std::string& chain, int height) override {
        std::string value;
        const auto key = undoKey(chain, height);
        const auto status = db_->Get(rocksdb::ReadOptions(), key, &value);
        if (status.IsNotFound()) {
            throw std::runtime_error("missing rocksdb undo");
        }
        checkStatus(status, "read rocksdb undo");
        checkStatus(db_->Delete(rocksdb::WriteOptions(), key), "delete rocksdb undo");
        return decodeUndo(value);
    }

    void deleteUtxosCreatedAtHeight(int height) override {
        rocksdb::WriteBatch batch;
        std::unique_ptr<rocksdb::Iterator> it(db_->NewIterator(rocksdb::ReadOptions()));
        for (it->Seek("utxo/"); it->Valid() && keyStartsWith(it->key(), "utxo/"); it->Next()) {
            const auto utxo = decodeUtxo(it->value().ToString());
            if (utxo.height == height) {
                batch.Delete(it->key());
            }
        }
        checkStatus(it->status(), "iterate rocksdb utxos for delete");
        checkStatus(db_->Write(rocksdb::WriteOptions(), &batch), "delete rocksdb created utxos");
    }

    void resetValidatedChain(const std::string& chain, const std::string& genesisHash) override {
        rocksdb::WriteBatch batch;
        std::unique_ptr<rocksdb::Iterator> it(db_->NewIterator(rocksdb::ReadOptions()));
        for (it->Seek("utxo/"); it->Valid() && keyStartsWith(it->key(), "utxo/"); it->Next()) {
            batch.Delete(it->key());
        }
        const auto undoPrefix = "undo/" + chain + "/";
        for (it->Seek(undoPrefix); it->Valid() && keyStartsWith(it->key(), undoPrefix); it->Next()) {
            batch.Delete(it->key());
        }
        batch.Put(tipHeightKey(chain), "0");
        batch.Put(tipHashKey(chain), genesisHash);
        checkStatus(it->status(), "iterate rocksdb reset");
        checkStatus(db_->Write(rocksdb::WriteOptions(), &batch), "reset rocksdb chainstate");
    }

private:
    std::string path_;
    std::unique_ptr<rocksdb::DB> db_;
};
#endif

}  // namespace

NodeStateChainstateStore::NodeStateChainstateStore(NodeStateStore& state) : state_(state) {}

ChainstateMetadata NodeStateChainstateStore::metadata() const {
    const auto stateMeta = state_.nodeStateMetadata();
    ChainstateMetadata meta;
    meta.backendName = stateMeta.backendName;
    meta.backendPath = stateMeta.backendPath;
    meta.status = stateMeta.status;
    meta.generationId = stateMeta.generationId;
    meta.schemaVersion = stateMeta.schemaVersion;
    return meta;
}

ChainstateTip NodeStateChainstateStore::readTip(const std::string& chain) const {
    return ChainstateTip{state_.getValidatedHeight(chain), state_.getValidatedHash(chain)};
}

void NodeStateChainstateStore::setTip(const std::string& chain, int height, const std::string& blockHashHex) {
    state_.setValidatedTip(height, blockHashHex, chain);
}

int NodeStateChainstateStore::utxoCount() const {
    return state_.utxoCount();
}

std::optional<StoredUtxo> NodeStateChainstateStore::getUtxo(const std::vector<std::uint8_t>& txid, int vout) const {
    return state_.getUtxo(txid, vout);
}

void NodeStateChainstateStore::addUtxo(const std::vector<std::uint8_t>& txid, int vout, int height, std::int64_t value,
                                       const std::vector<std::uint8_t>& scriptPubkey, bool coinbase) {
    state_.addUtxo(txid, vout, height, value, scriptPubkey, coinbase);
}

void NodeStateChainstateStore::spendUtxo(const std::vector<std::uint8_t>& txid, int vout) {
    state_.spendUtxo(txid, vout);
}

void NodeStateChainstateStore::replaceUtxoUndo(const std::string& chain, int height, const std::vector<StoredUtxo>& entries) {
    state_.replaceUtxoUndo(chain, height, entries);
}

std::vector<StoredUtxo> NodeStateChainstateStore::takeUtxoUndo(const std::string& chain, int height) {
    return state_.takeUtxoUndo(chain, height);
}

void NodeStateChainstateStore::deleteUtxosCreatedAtHeight(int height) {
    state_.deleteUtxosCreatedAtHeight(height);
}

void NodeStateChainstateStore::resetValidatedChain(const std::string& chain, const std::string& genesisHash) {
    state_.resetValidatedChain(chain, genesisHash);
}

std::unique_ptr<ChainstateStore> openChainstateStore(const std::string& backend, const std::string& dataDir,
                                                     NodeStateStore& state) {
    (void)backend;
    (void)dataDir;
    return std::make_unique<NodeStateChainstateStore>(state);
}

std::string defaultChainstateBackend() {
    return "sqlite";
}

std::string chainstateBackendName(const ChainstateStore& store) {
    return store.metadata().backendName;
}

}  // namespace cpbitnode::db
