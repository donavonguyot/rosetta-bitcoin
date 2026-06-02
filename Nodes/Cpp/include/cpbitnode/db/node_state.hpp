#pragma once

#include <cstdint>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace cpbitnode::db {

struct StoredUtxo {
    std::string txid;
    int vout = 0;
    int height = 0;
    std::int64_t value = 0;
    std::vector<std::uint8_t> scriptPubkey;
    bool coinbase = false;
};

struct StoredBlockRow {
    int height = 0;
    std::string blockHash;
    std::string fileName;
    int fileOffset = 0;
    int size = 0;
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
    virtual void spendUtxo(const std::vector<std::uint8_t>& txid, int vout) = 0;
    virtual void replaceUtxoUndo(const std::string& chain, int height, const std::vector<StoredUtxo>& entries) = 0;
    virtual std::vector<StoredUtxo> takeUtxoUndo(const std::string& chain, int height) = 0;
    virtual void deleteUtxosCreatedAtHeight(int height) = 0;
    virtual void resetValidatedChain(const std::string& chain, const std::string& genesisHash) = 0;
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
};

std::unique_ptr<NodeStateStore> openRocksDbNodeStateStore(const std::string& dataDir);

}  // namespace cpbitnode::db
