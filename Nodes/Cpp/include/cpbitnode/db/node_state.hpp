#pragma once

#include <algorithm>
#include <array>
#include <cstdint>
#include <map>
#include <memory>
#include <optional>
#include <span>
#include <stdexcept>
#include <string>
#include <vector>

namespace cpbitnode::db {

struct StorageTimingSnapshot {
    long long utxoDeletePrepareUs = 0;
    long long utxoPutPrepareUs = 0;
    long long undoPutPrepareUs = 0;
    long long metadataPutPrepareUs = 0;
    long long rocksdbWriteUs = 0;
    long long commitBatchPuts = 0;
    long long commitBatchDeletes = 0;
    long long commitKeyBytes = 0;
    long long commitValueBytes = 0;
    long long commitUtxoPuts = 0;
    long long commitUtxoDeletes = 0;
    long long commitUndoBytes = 0;
    long long commitCreatedListBytes = 0;
    long long commitMetadataPuts = 0;
    long long commitBlockIndexBytes = 0;
};

struct DbOutpointKey {
    std::array<std::uint8_t, 32> txid{};
    std::uint32_t vout = 0;

    bool operator==(const DbOutpointKey& other) const { return txid == other.txid && vout == other.vout; }
};

struct DbOutpointKeyHash {
    std::size_t operator()(const DbOutpointKey& key) const {
        std::size_t hash = 1469598103934665603ULL;
        for (const auto byte : key.txid) {
            hash ^= byte;
            hash *= 1099511628211ULL;
        }
        hash ^= key.vout;
        hash *= 1099511628211ULL;
        return hash;
    }
};

struct StoredBlockRow {
    int height = 0;
    std::string blockHash;
    std::string fileName;
    int fileOffset = 0;
    int size = 0;
};

struct StoredUtxo {
    std::vector<std::uint8_t> txid;
    int vout = 0;
    int height = 0;
    std::int64_t value = 0;
    std::vector<std::uint8_t> scriptPubkey;
    bool coinbase = false;
};

struct StoredUtxoRef {
    DbOutpointKey outpoint;
    int height = 0;
    std::int64_t value = 0;
    std::vector<std::uint8_t> scriptPubkey;
    bool coinbase = false;
};

struct Outpoint {
    std::vector<std::uint8_t> txid;
    int vout = 0;
};

struct HeaderRecord {
    int height = 0;
    std::string blockHash;
    std::string prevHash;
    int timestamp = 0;
    std::string headerSerializedHex;
};

struct UtxoCreate {
    std::vector<std::uint8_t> txid;
    int vout = 0;
    int height = 0;
    std::int64_t value = 0;
    std::vector<std::uint8_t> scriptPubkey;
    bool coinbase = false;
};

struct UtxoCreateRef {
    DbOutpointKey outpoint;
    int height = 0;
    std::int64_t value = 0;
    std::vector<std::uint8_t> scriptPubkey;
    bool coinbase = false;
};

struct BlockCommit {
    std::string chain;
    int height = 0;
    std::string blockHash;
    std::vector<Outpoint> spends;
    std::vector<UtxoCreate> creates;
    std::vector<StoredUtxo> undo;
    std::optional<StoredBlockRow> blockIndex;
};

struct BlockCommitNative {
    std::string chain;
    int height = 0;
    std::string blockHash;
    std::vector<DbOutpointKey> spends;
    std::vector<UtxoCreateRef> creates;
    std::vector<StoredUtxoRef> undo;
    std::optional<StoredBlockRow> blockIndex;
};

struct NodeStateMetadata {
    std::string backendName;
    std::string backendPath;
    std::string status = "usable";
    std::string generationId;
    std::string schemaVersion = "1";
};

class NodeStateStore {
public:
    virtual ~NodeStateStore() = default;

    virtual NodeStateMetadata nodeStateMetadata() const = 0;

    virtual void setMeta(const std::string& key, const std::string& value) = 0;
    virtual std::optional<std::string> getMeta(const std::string& key) const = 0;

    virtual void updatePhase(const std::string& phase, const std::optional<std::string>& status = std::nullopt,
                             const std::optional<std::string>& notes = std::nullopt) = 0;
    virtual std::vector<std::map<std::string, std::string>> listPhases() const = 0;

    virtual void logEvent(const std::string& category, const std::string& message, const std::string& level = "info",
                          const std::string& detailsJson = "{}") = 0;

    virtual void upsertSyncState(const std::string& chain, std::optional<int> bestHeight = std::nullopt,
                                 const std::optional<std::string>& bestHash = std::nullopt,
                                 std::optional<int> headerCount = std::nullopt,
                                 const std::optional<std::string>& syncStatus = std::nullopt) = 0;
    virtual std::optional<std::map<std::string, std::string>> getSyncState(const std::string& chain) const = 0;

    virtual int recordPeerConnected(const std::string& host, int port, const std::string& userAgent = "",
                                    const std::string& direction = "outbound") = 0;
    virtual void recordPeerDisconnected(int peerId) = 0;
    virtual void touchPeer(int peerId) = 0;
    virtual void recordPeerAddress(const std::string& host, int port, std::uint64_t services = 0,
                                   const std::string& source = "addr") = 0;
    virtual int getPeerEndpointBanScore(const std::string& host, int port) const = 0;
    virtual int incrementPeerBanScore(const std::string& host, int port, int delta, int peerId = 0) = 0;
    virtual void decayPeerBanScore(const std::string& host, int port, int amount, int peerId = 0) = 0;
    virtual std::vector<std::pair<std::string, int>> listPeerAddressEndpoints(int limit = 32) const = 0;

    virtual void recordHeader(int height, const std::string& blockHash, const std::string& prevHash, int timestamp,
                              const std::string& headerSerializedHex = "") = 0;
    virtual void recordHeaders(const std::vector<HeaderRecord>& headers) = 0;
    virtual std::optional<int> lookupHeaderHeight(const std::string& blockHashHex) const = 0;
    virtual std::optional<std::string> getHeaderSerializedHex(int height) const = 0;
    virtual std::optional<StoredBlockRow> getStoredBlockForHashHex(const std::string& blockHashHex) const = 0;
    virtual int headerCount() const = 0;
    virtual int blockCount() const = 0;
    virtual int utxoCount() const = 0;
    virtual int getValidatedHeight(const std::string& chain) const = 0;
    virtual std::string getValidatedHash(const std::string& chain) const = 0;
    virtual int maxHeaderHeight() const = 0;

    virtual void setValidatedTip(int height, const std::string& blockHashHex,
                                 const std::string& chain = "testnet4") = 0;
    virtual void recordBlock(int height, const std::string& blockHash, const std::string& fileName, int fileOffset,
                             int size) = 0;
    virtual void addUtxo(const std::vector<std::uint8_t>& txid, int vout, int height, std::int64_t value,
                         const std::vector<std::uint8_t>& scriptPubkey, bool coinbase) = 0;
    virtual std::optional<StoredUtxo> getUtxo(const std::vector<std::uint8_t>& txid, int vout) const = 0;
    virtual std::vector<std::optional<StoredUtxo>> getUtxos(const std::vector<Outpoint>& outpoints) const = 0;
    virtual std::vector<std::optional<StoredUtxoRef>> getUtxos(std::span<const DbOutpointKey> outpoints) const;
    virtual void spendUtxo(const std::vector<std::uint8_t>& txid, int vout) = 0;
    virtual void replaceUtxoUndo(const std::string& chain, int height, const std::vector<StoredUtxo>& entries) = 0;
    virtual std::vector<StoredUtxo> takeUtxoUndo(const std::string& chain, int height) = 0;
    virtual void deleteUtxosCreatedAtHeight(int height) = 0;
    virtual void resetValidatedChain(const std::string& chain, const std::string& genesisHash) = 0;
    virtual void commitBlock(const BlockCommit& commit) = 0;
    virtual void commitBlock(const BlockCommitNative& commit);
    virtual std::optional<std::string> getHeaderHash(int height) const = 0;
    virtual std::optional<StoredBlockRow> getBlock(int height) const = 0;
    virtual int maxStoredBlockHeight() const = 0;
    virtual std::vector<int> listMissingBlockHeights(int limit = 32) const = 0;

    virtual std::vector<std::map<std::string, std::string>> listWireCapabilities() const = 0;
    virtual std::string wireProgressJson() const = 0;
    virtual void markWireCapability(const std::string& capabilityId, bool implemented,
                                    const std::string& verifiedBy = "live", const std::string& notes = "") = 0;
    virtual std::map<std::string, int> wireCapabilityMap() const = 0;
    virtual std::map<std::string, std::string> wireProgressSummary() const = 0;
    virtual std::map<std::string, std::map<std::string, std::string>> wireProgressCheckpoints() const = 0;

    virtual std::vector<std::map<std::string, std::string>> recentEvents(int limit = 20) const = 0;
    virtual std::string summaryJson(const std::string& chain) const = 0;
    virtual int peerCount() const = 0;
    virtual int connectedPeerCount() const = 0;
};

inline std::vector<std::uint8_t> txidVector(const DbOutpointKey& key) {
    return std::vector<std::uint8_t>(key.txid.begin(), key.txid.end());
}

inline DbOutpointKey makeDbOutpointKey(const std::vector<std::uint8_t>& txid, int vout) {
    if (txid.size() != 32) {
        throw std::invalid_argument("outpoint txid must be 32 bytes");
    }
    if (vout < 0) {
        throw std::invalid_argument("outpoint vout must be non-negative");
    }
    DbOutpointKey key;
    std::copy(txid.begin(), txid.end(), key.txid.begin());
    key.vout = static_cast<std::uint32_t>(vout);
    return key;
}

inline StoredUtxoRef toStoredUtxoRef(const StoredUtxo& utxo) {
    return StoredUtxoRef{makeDbOutpointKey(utxo.txid, utxo.vout), utxo.height, utxo.value, utxo.scriptPubkey,
                         utxo.coinbase};
}

inline StoredUtxo toStoredUtxo(const StoredUtxoRef& utxo) {
    return StoredUtxo{txidVector(utxo.outpoint), static_cast<int>(utxo.outpoint.vout), utxo.height, utxo.value,
                      utxo.scriptPubkey, utxo.coinbase};
}

inline std::vector<std::optional<StoredUtxoRef>> NodeStateStore::getUtxos(
    std::span<const DbOutpointKey> outpoints) const {
    std::vector<Outpoint> legacy;
    legacy.reserve(outpoints.size());
    for (const auto& outpoint : outpoints) {
        legacy.push_back(Outpoint{txidVector(outpoint), static_cast<int>(outpoint.vout)});
    }
    const auto loaded = getUtxos(legacy);
    std::vector<std::optional<StoredUtxoRef>> out;
    out.reserve(loaded.size());
    for (const auto& utxo : loaded) {
        out.push_back(utxo ? std::optional<StoredUtxoRef>(toStoredUtxoRef(*utxo)) : std::nullopt);
    }
    return out;
}

inline void NodeStateStore::commitBlock(const BlockCommitNative& commit) {
    BlockCommit legacy;
    legacy.chain = commit.chain;
    legacy.height = commit.height;
    legacy.blockHash = commit.blockHash;
    legacy.blockIndex = commit.blockIndex;
    legacy.spends.reserve(commit.spends.size());
    for (const auto& spend : commit.spends) {
        legacy.spends.push_back(Outpoint{txidVector(spend), static_cast<int>(spend.vout)});
    }
    legacy.creates.reserve(commit.creates.size());
    for (const auto& create : commit.creates) {
        legacy.creates.push_back(UtxoCreate{txidVector(create.outpoint), static_cast<int>(create.outpoint.vout),
                                            create.height, create.value, create.scriptPubkey, create.coinbase});
    }
    legacy.undo.reserve(commit.undo.size());
    for (const auto& undo : commit.undo) {
        legacy.undo.push_back(toStoredUtxo(undo));
    }
    commitBlock(legacy);
}

std::unique_ptr<NodeStateStore> openRocksDbNodeStateStore(const std::string& dataDir);
void resetStorageTiming();
StorageTimingSnapshot storageTimingSnapshot();

}  // namespace cpbitnode::db
