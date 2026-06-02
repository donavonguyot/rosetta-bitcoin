#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <set>
#include <span>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "cpbitnode/config/settings.hpp"
#include "cpbitnode/db/node_state.hpp"
#include "cpbitnode/messages/inventory.hpp"
#include "cpbitnode/messages/transaction.hpp"
#include "cpbitnode/mempool/orphan_pool.hpp"
#include "cpbitnode/mempool/prevout.hpp"

namespace cpbitnode::mempool {

struct UtxoOverlayRow {
    std::int64_t value = 0;
    std::vector<std::uint8_t> scriptPubkey;
};

struct AcceptTransactionOptions {
    const config::Settings* settings = nullptr;
    std::string peerHost;
    const std::set<PrevoutKey>* mempoolClaimedPrevouts = nullptr;
    const std::unordered_map<PrevoutKey, UtxoOverlayRow, PrevoutKeyHash>* mempoolUtxoOverlay = nullptr;
    OrphanPool* orphanPool = nullptr;
    bool deferOrphans = false;
};

struct MempoolOptions {
    std::size_t maxSizeBytes = 32 * 1024 * 1024;
    db::NodeStateStore* tracker = nullptr;
    OrphanPool* orphanPool = nullptr;
    std::optional<int> mempoolMaxCount;
    std::optional<int> mempoolMaxAgeSeconds;
    const config::Settings* settings = nullptr;
};

int estimateTxVirtualSizeScaffold(const messages::Transaction& tx);

std::optional<std::set<PrevoutKey>> collectMissingPrevouts(
    const messages::Transaction& tx, db::NodeStateStore& tracker,
    const std::unordered_map<PrevoutKey, UtxoOverlayRow, PrevoutKeyHash>* mempoolUtxoOverlay = nullptr,
    const std::set<PrevoutKey>* mempoolClaimedPrevouts = nullptr);

bool acceptTransaction(const messages::Transaction& tx, db::NodeStateStore& tracker,
                       const AcceptTransactionOptions& options = {});

bool transactionMeetsPeerFeefilter(const messages::Transaction& tx, db::NodeStateStore& tracker,
                                   std::optional<std::int64_t> peerFeeFilterSatKvb);

class Mempool {
public:
    explicit Mempool(const MempoolOptions& options = {});

    std::set<PrevoutKey> claimedPrevoutsFrozen() const;
    std::optional<double> entryAddedAt(const std::vector<std::uint8_t>& txid) const;

    std::size_t size() const { return txById_.size(); }
    std::size_t totalSizeBytes() const { return sizeBytes_; }

    std::optional<messages::Transaction> get(const std::vector<std::uint8_t>& txid) const;
    std::vector<messages::Transaction> iterPooledTransactions() const;
    std::optional<messages::Transaction> getForInv(std::uint32_t invType, std::span<const std::uint8_t> invHash) const;
    bool contains(const std::vector<std::uint8_t>& txid) const;

    bool acceptTransaction(const messages::Transaction& tx, const AcceptTransactionOptions& options = {});
    bool add(const messages::Transaction& tx);
    bool remove(const std::vector<std::uint8_t>& txid);

    int evictExpired(double nowSeconds);
    int evictOverCapacity();

private:
    struct MempoolEntry {
        messages::Transaction tx;
        std::vector<std::uint8_t> txid;
        double addedAt = 0.0;
    };

    std::unordered_map<PrevoutKey, UtxoOverlayRow, PrevoutKeyHash> mempoolUtxoOverlay() const;
    std::vector<std::vector<std::uint8_t>> clusterPostOrder(const std::vector<std::uint8_t>& root) const;
    bool removeSingle(const std::vector<std::uint8_t>& txid);
    int evictOldestCluster();
    void linkIncomingSpenders(const std::vector<std::uint8_t>& txid, const messages::Transaction& tx);
    void tryPromoteOrphansFor(const messages::Transaction& producer);
    void persistStats();
    std::size_t serializedLen(const messages::Transaction& tx) const;

    static std::string txidHexKey(const std::vector<std::uint8_t>& txid);

    std::size_t maxSizeBytes_;
    int maxTxCount_;
    int maxAgeSeconds_;
    db::NodeStateStore* tracker_;
    OrphanPool* orphanPool_;
    config::Settings policy_;

    std::unordered_map<std::string, MempoolEntry> txById_;
    std::unordered_map<std::string, messages::Transaction> byWtxid_;
    std::unordered_map<std::string, std::unordered_set<std::string>> spenders_;
    std::set<PrevoutKey> claimedPrevouts_;
    std::size_t sizeBytes_ = 0;
};

}  // namespace cpbitnode::mempool
