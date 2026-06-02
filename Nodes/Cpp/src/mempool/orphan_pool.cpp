#include "cpbitnode/mempool/orphan_pool.hpp"

#include "cpbitnode/consensus/merkle.hpp"

#include <sstream>
#include <stdexcept>

namespace cpbitnode::mempool {

OrphanPool::OrphanPool(int maxTransactions, std::size_t maxSizeBytes)
    : maxTransactions_(maxTransactions), maxSizeBytes_(maxSizeBytes) {
    if (maxTransactions_ < 1) {
        throw std::invalid_argument("maxTransactions must be positive");
    }
    if (maxSizeBytes_ < 1) {
        throw std::invalid_argument("maxSizeBytes must be positive");
    }
}

std::string OrphanPool::txidHexKey(const std::vector<std::uint8_t>& txid) {
    std::ostringstream out;
    for (const auto b : txid) {
        static const char* hex = "0123456789abcdef";
        out << hex[b >> 4] << hex[b & 0x0f];
    }
    return out.str();
}

std::size_t OrphanPool::txSerializedWeightBytes(const messages::Transaction& tx) {
    return tx.serialize(true).size();
}

bool OrphanPool::contains(const std::vector<std::uint8_t>& txid) const {
    return orphans_.find(txidHexKey(txid)) != orphans_.end();
}

std::optional<messages::Transaction> OrphanPool::get(const std::vector<std::uint8_t>& txid) const {
    const auto it = orphans_.find(txidHexKey(txid));
    if (it == orphans_.end()) {
        return std::nullopt;
    }
    return it->second.tx;
}

void OrphanPool::purgePrevoutRefs(const std::string& txidKey, const std::set<PrevoutKey>& prevouts) {
    for (const auto& key : prevouts) {
        const auto it = pendingByPrevout_.find(key);
        if (it == pendingByPrevout_.end()) {
            continue;
        }
        it->second.erase(txidKey);
        if (it->second.empty()) {
            pendingByPrevout_.erase(it);
        }
    }
}

bool OrphanPool::remove(const std::vector<std::uint8_t>& txid) {
    const auto key = txidHexKey(txid);
    const auto it = orphans_.find(key);
    if (it == orphans_.end()) {
        return false;
    }
    const auto unresolved = it->second.unresolved;
    const auto slotSize = it->second.sizeBytes;
    orphans_.erase(it);
    purgePrevoutRefs(key, unresolved);
    sizeBytes_ -= slotSize;
    return true;
}

bool OrphanPool::tryAdd(const messages::Transaction& tx, const std::set<PrevoutKey>& missingPrevouts) {
    if (missingPrevouts.empty()) {
        return false;
    }
    const auto txid = consensus::transactionTxid(tx);
    const auto txKey = txidHexKey(txid);
    const auto size = txSerializedWeightBytes(tx);

    if (orphans_.contains(txKey)) {
        remove(txid);
    }
    if (static_cast<int>(orphans_.size()) >= maxTransactions_) {
        return false;
    }
    if (sizeBytes_ + size > maxSizeBytes_) {
        return false;
    }

    OrphanSlot slot;
    slot.tx = tx;
    slot.unresolved = missingPrevouts;
    slot.sizeBytes = size;
    orphans_.emplace(txKey, std::move(slot));
    sizeBytes_ += size;
    for (const auto& key : missingPrevouts) {
        pendingByPrevout_[key].insert(txKey);
    }
    return true;
}

std::vector<messages::Transaction> OrphanPool::takeReadyTransactionsForPrevout(const PrevoutKey& prevout) {
    const auto it = pendingByPrevout_.find(prevout);
    if (it == pendingByPrevout_.end()) {
        return {};
    }
    const auto txids = std::vector<std::string>(it->second.begin(), it->second.end());
    pendingByPrevout_.erase(it);

    std::vector<messages::Transaction> detached;
    for (const auto& orphanKey : txids) {
        const auto slotIt = orphans_.find(orphanKey);
        if (slotIt == orphans_.end()) {
            continue;
        }
        const auto depsBefore = slotIt->second.unresolved;
        slotIt->second.unresolved.erase(prevout);
        if (!slotIt->second.unresolved.empty()) {
            continue;
        }
        const auto size = slotIt->second.sizeBytes;
        detached.push_back(slotIt->second.tx);
        orphans_.erase(slotIt);
        purgePrevoutRefs(orphanKey, depsBefore);
        sizeBytes_ -= size;
    }
    return detached;
}

std::optional<std::set<PrevoutKey>> OrphanPool::unresolvedPrevoutsSnapshot(
    const std::vector<std::uint8_t>& txid) const {
    const auto it = orphans_.find(txidHexKey(txid));
    if (it == orphans_.end()) {
        return std::nullopt;
    }
    return it->second.unresolved;
}

void OrphanPool::clear() {
    orphans_.clear();
    pendingByPrevout_.clear();
    sizeBytes_ = 0;
}

}  // namespace cpbitnode::mempool
