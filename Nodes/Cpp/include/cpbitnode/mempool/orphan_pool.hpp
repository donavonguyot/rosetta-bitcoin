#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <optional>
#include <set>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "cpbitnode/messages/transaction.hpp"
#include "cpbitnode/mempool/prevout.hpp"

namespace cpbitnode::mempool {

class OrphanPool {
public:
    OrphanPool(int maxTransactions = 1000, std::size_t maxSizeBytes = 512 * 1024);

    int maxTransactions() const { return maxTransactions_; }
    std::size_t maxSizeBytes() const { return maxSizeBytes_; }

    std::size_t size() const { return orphans_.size(); }
    std::size_t totalSizeBytes() const { return sizeBytes_; }

    bool contains(const std::vector<std::uint8_t>& txid) const;
    std::optional<messages::Transaction> get(const std::vector<std::uint8_t>& txid) const;
    bool remove(const std::vector<std::uint8_t>& txid);
    bool tryAdd(const messages::Transaction& tx, const std::set<PrevoutKey>& missingPrevouts);
    std::vector<messages::Transaction> takeReadyTransactionsForPrevout(const PrevoutKey& prevout);
    std::optional<std::set<PrevoutKey>> unresolvedPrevoutsSnapshot(const std::vector<std::uint8_t>& txid) const;
    void clear();

private:
    struct OrphanSlot {
        messages::Transaction tx;
        std::set<PrevoutKey> unresolved;
        std::size_t sizeBytes = 0;
    };

    static std::string txidHexKey(const std::vector<std::uint8_t>& txid);
    static std::size_t txSerializedWeightBytes(const messages::Transaction& tx);
    void purgePrevoutRefs(const std::string& txidKey, const std::set<PrevoutKey>& prevouts);

    int maxTransactions_;
    std::size_t maxSizeBytes_;
    std::unordered_map<std::string, OrphanSlot> orphans_;
    std::unordered_map<PrevoutKey, std::unordered_set<std::string>, PrevoutKeyHash> pendingByPrevout_;
    std::size_t sizeBytes_ = 0;
};

}  // namespace cpbitnode::mempool
