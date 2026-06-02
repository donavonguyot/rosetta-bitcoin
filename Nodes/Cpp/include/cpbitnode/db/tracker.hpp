#pragma once

#include "cpbitnode/db/node_state.hpp"

struct sqlite3;

namespace cpbitnode::db {

class ProjectTracker final : public NodeStateStore {
public:
    explicit ProjectTracker(const std::string& dbPath);
    ~ProjectTracker() override;

    ProjectTracker(const ProjectTracker&) = delete;
    ProjectTracker& operator=(const ProjectTracker&) = delete;

    NodeStateMetadata nodeStateMetadata() const override;

    void setMeta(const std::string& key, const std::string& value) override;
    std::optional<std::string> getMeta(const std::string& key) const override;

    void updatePhase(const std::string& phase, const std::optional<std::string>& status = std::nullopt,
                     const std::optional<std::string>& notes = std::nullopt) override;
    std::vector<std::map<std::string, std::string>> listPhases() const override;

    void logEvent(const std::string& category, const std::string& message, const std::string& level = "info",
                  const std::string& detailsJson = "{}") override;

    void upsertSyncState(const std::string& chain, std::optional<int> bestHeight = std::nullopt,
                         const std::optional<std::string>& bestHash = std::nullopt,
                         std::optional<int> headerCount = std::nullopt,
                         const std::optional<std::string>& syncStatus = std::nullopt) override;
    std::optional<std::map<std::string, std::string>> getSyncState(const std::string& chain) const override;

    int recordPeerConnected(const std::string& host, int port, const std::string& userAgent = "",
                            const std::string& direction = "outbound") override;
    void recordPeerDisconnected(int peerId) override;
    void touchPeer(int peerId) override;
    void recordPeerAddress(const std::string& host, int port, std::uint64_t services = 0,
                           const std::string& source = "addr") override;
    int getPeerEndpointBanScore(const std::string& host, int port) const override;
    int incrementPeerBanScore(const std::string& host, int port, int delta, int peerId = 0) override;
    void decayPeerBanScore(const std::string& host, int port, int amount, int peerId = 0) override;
    std::vector<std::pair<std::string, int>> listPeerAddressEndpoints(int limit = 32) const override;

    void recordHeader(int height, const std::string& blockHash, const std::string& prevHash, int timestamp,
                      const std::string& headerSerializedHex = "") override;
    std::optional<int> lookupHeaderHeight(const std::string& blockHashHex) const override;
    std::optional<std::string> getHeaderSerializedHex(int height) const override;
    std::optional<StoredBlockRow> getStoredBlockForHashHex(const std::string& blockHashHex) const override;
    int headerCount() const override;
    int blockCount() const override;
    int utxoCount() const override;
    int getValidatedHeight(const std::string& chain) const override;
    std::string getValidatedHash(const std::string& chain) const override;
    int maxHeaderHeight() const override;

    void setValidatedTip(int height, const std::string& blockHashHex, const std::string& chain = "testnet4") override;
    void recordBlock(int height, const std::string& blockHash, const std::string& fileName, int fileOffset,
                     int size) override;
    void addUtxo(const std::vector<std::uint8_t>& txid, int vout, int height, std::int64_t value,
                 const std::vector<std::uint8_t>& scriptPubkey, bool coinbase) override;
    std::optional<StoredUtxo> getUtxo(const std::vector<std::uint8_t>& txid, int vout) const override;
    void spendUtxo(const std::vector<std::uint8_t>& txid, int vout) override;
    void replaceUtxoUndo(const std::string& chain, int height, const std::vector<StoredUtxo>& entries) override;
    std::vector<StoredUtxo> takeUtxoUndo(const std::string& chain, int height) override;
    void deleteUtxosCreatedAtHeight(int height) override;
    void resetValidatedChain(const std::string& chain, const std::string& genesisHash) override;
    std::optional<std::string> getHeaderHash(int height) const override;
    std::optional<StoredBlockRow> getBlock(int height) const override;
    int maxStoredBlockHeight() const override;
    std::vector<int> listMissingBlockHeights(int limit = 32) const override;

    std::vector<std::map<std::string, std::string>> listWireCapabilities() const override;
    std::string wireProgressJson() const override;

    void markWireCapability(const std::string& capabilityId, bool implemented, const std::string& verifiedBy = "live",
                            const std::string& notes = "") override;
    std::map<std::string, int> wireCapabilityMap() const override;
    std::map<std::string, std::string> wireProgressSummary() const override;
    std::map<std::string, std::map<std::string, std::string>> wireProgressCheckpoints() const override;

    std::vector<std::map<std::string, std::string>> recentEvents(int limit = 20) const override;
    std::string summaryJson(const std::string& chain) const override;

    sqlite3* handle() const { return db_; }

private:
    sqlite3* db_ = nullptr;
    std::string dbPath_;
};

}  // namespace cpbitnode::db
