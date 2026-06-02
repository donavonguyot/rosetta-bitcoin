#include "cpbitnode/mempool/mempool.hpp"

#include "cpbitnode/consensus/merkle.hpp"
#include "cpbitnode/consensus/script/verify.hpp"
#include "cpbitnode/consensus/witness.hpp"

#include <algorithm>
#include <chrono>
#include <functional>
#include <sstream>
#include <stdexcept>

namespace cpbitnode::mempool {
namespace {

std::string bytesToHex(std::span<const std::uint8_t> bytes) {
    std::ostringstream out;
    for (const auto b : bytes) {
        static const char* hex = "0123456789abcdef";
        out << hex[b >> 4] << hex[b & 0x0f];
    }
    return out.str();
}

std::optional<db::StoredUtxo> effectiveUtxoRow(
    db::NodeStateStore& tracker,
    const std::unordered_map<PrevoutKey, UtxoOverlayRow, PrevoutKeyHash>* overlay, const messages::TxIn& input) {
    if (const auto row = tracker.getUtxo(input.previousOutput.hash, static_cast<int>(input.previousOutput.index))) {
        return row;
    }
    if (overlay == nullptr) {
        return std::nullopt;
    }
    const auto key = inputPrevoutKey(input);
    const auto it = overlay->find(key);
    if (it == overlay->end()) {
        return std::nullopt;
    }
    db::StoredUtxo synthetic;
    synthetic.txid = bytesToHex(key.first);
    synthetic.vout = key.second;
    synthetic.value = it->second.value;
    synthetic.scriptPubkey = it->second.scriptPubkey;
    synthetic.coinbase = false;
    return synthetic;
}

std::optional<std::int64_t> transactionFeeKnownPrevouts(const messages::Transaction& tx,
                                                          db::NodeStateStore& tracker) {
    if (tx.isCoinbase()) {
        return std::nullopt;
    }
    std::int64_t spent = 0;
    for (const auto& input : tx.inputs) {
        const auto row = tracker.getUtxo(input.previousOutput.hash, static_cast<int>(input.previousOutput.index));
        if (!row) {
            return std::nullopt;
        }
        spent += row->value;
    }
    std::int64_t outSum = 0;
    for (const auto& output : tx.outputs) {
        outSum += output.value;
    }
    return spent - outSum;
}

double nowSeconds() {
    using Clock = std::chrono::system_clock;
    return std::chrono::duration<double>(Clock::now().time_since_epoch()).count();
}

}  // namespace

int estimateTxVirtualSizeScaffold(const messages::Transaction& tx) {
    return static_cast<int>(std::max<std::size_t>(1, tx.serialize(false).size()));
}

std::optional<std::set<PrevoutKey>> collectMissingPrevouts(
    const messages::Transaction& tx, db::NodeStateStore& tracker,
    const std::unordered_map<PrevoutKey, UtxoOverlayRow, PrevoutKeyHash>* mempoolUtxoOverlay,
    const std::set<PrevoutKey>* mempoolClaimedPrevouts) {
    if (tx.isCoinbase()) {
        return std::set<PrevoutKey>{};
    }
    if (tx.inputs.empty() || tx.outputs.empty()) {
        return std::set<PrevoutKey>{};
    }

    std::set<PrevoutKey> seenPrevouts;
    std::set<PrevoutKey> missing;
    for (const auto& input : tx.inputs) {
        const auto key = inputPrevoutKey(input);
        if (seenPrevouts.contains(key)) {
            return std::nullopt;
        }
        seenPrevouts.insert(key);
        if (mempoolClaimedPrevouts != nullptr && mempoolClaimedPrevouts->contains(key)) {
            return std::nullopt;
        }
        if (!effectiveUtxoRow(tracker, mempoolUtxoOverlay, input)) {
            missing.insert(key);
        }
    }
    return missing;
}

bool acceptTransaction(const messages::Transaction& tx, db::NodeStateStore& tracker,
                       const AcceptTransactionOptions& options) {
    const config::Settings resolved = options.settings != nullptr ? *options.settings : config::Settings::fromEnv();
    const int minFeerate = resolved.minRelayFeerateSatVb;
    const bool allowOrphanEnqueue =
        options.orphanPool != nullptr && options.deferOrphans && resolved.enableOrphanPool;

    if (tx.isCoinbase()) {
        tracker.logEvent("mempool", "Rejected coinbase relay", "warning",
                         "{\"peer\":\"" + options.peerHost + "\"}");
        return false;
    }
    if (tx.inputs.empty()) {
        tracker.logEvent("mempool", "Rejected tx: no inputs", "warning",
                         "{\"peer\":\"" + options.peerHost + "\"}");
        return false;
    }
    if (tx.outputs.empty()) {
        tracker.logEvent("mempool", "Rejected tx: no outputs", "warning",
                         "{\"peer\":\"" + options.peerHost + "\"}");
        return false;
    }

    std::set<PrevoutKey> seenPrevouts;
    std::set<PrevoutKey> missingPrevouts;
    std::int64_t inputTotalSat = 0;
    std::vector<std::optional<db::StoredUtxo>> rowsForInputs(tx.inputs.size());

    for (std::size_t inputIndex = 0; inputIndex < tx.inputs.size(); ++inputIndex) {
        const auto& input = tx.inputs[inputIndex];
        const auto key = inputPrevoutKey(input);
        if (seenPrevouts.contains(key)) {
            tracker.logEvent("mempool", "Rejected tx: duplicate prevout spends in single transaction", "warning",
                             "{\"peer\":\"" + options.peerHost + "\"}");
            return false;
        }
        seenPrevouts.insert(key);
        if (options.mempoolClaimedPrevouts != nullptr && options.mempoolClaimedPrevouts->contains(key)) {
            tracker.logEvent("mempool", "Rejected tx: mempool already spends this prevout", "warning",
                             "{\"peer\":\"" + options.peerHost + "\"}");
            return false;
        }
        const auto row = effectiveUtxoRow(tracker, options.mempoolUtxoOverlay, input);
        if (!row) {
            missingPrevouts.insert(key);
            continue;
        }
        rowsForInputs[inputIndex] = row;
    }

    if (!missingPrevouts.empty()) {
        if (allowOrphanEnqueue) {
            if (options.orphanPool->tryAdd(tx, missingPrevouts)) {
                tracker.logEvent("mempool", "Deferred tx: queued in orphan pool (missing prevouts)", "warning",
                                 "{\"peer\":\"" + options.peerHost + "\"}");
                return false;
            }
            tracker.logEvent("mempool", "Rejected tx: orphan pool capacity exhausted", "warning",
                             "{\"peer\":\"" + options.peerHost + "\"}");
            return false;
        }
        tracker.logEvent("mempool", "Rejected tx: unknown prevouts (not in effective UTXO view)", "warning",
                         "{\"peer\":\"" + options.peerHost + "\"}");
        return false;
    }

    std::vector<std::pair<std::int64_t, std::vector<std::uint8_t>>> spentPrevouts;
    spentPrevouts.reserve(rowsForInputs.size());
    for (const auto& row : rowsForInputs) {
        spentPrevouts.emplace_back(row->value, row->scriptPubkey);
    }

    for (std::size_t inputIndex = 0; inputIndex < tx.inputs.size(); ++inputIndex) {
        const auto& row = *rowsForInputs[inputIndex];
        try {
            consensus::script::verifyTransactionInput(tx, inputIndex, row.scriptPubkey, row.value, &spentPrevouts);
        } catch (const consensus::script::ScriptVerifyError& exc) {
            tracker.logEvent("mempool", std::string("Rejected tx: script/input verification failed: ") + exc.what(),
                             "warning", "{\"peer\":\"" + options.peerHost + "\"}");
            return false;
        }
        inputTotalSat += row.value;
    }

    std::int64_t outputTotalSat = 0;
    for (const auto& output : tx.outputs) {
        outputTotalSat += output.value;
    }
    if (outputTotalSat > inputTotalSat) {
        tracker.logEvent("mempool", "Rejected tx: outputs exceed inputs (negative fee)", "warning",
                         "{\"peer\":\"" + options.peerHost + "\"}");
        return false;
    }

    const std::int64_t fee = inputTotalSat - outputTotalSat;
    if (minFeerate > 0) {
        const int vsize = estimateTxVirtualSizeScaffold(tx);
        if (vsize <= 0) {
            return false;
        }
        const std::int64_t required = static_cast<std::int64_t>(minFeerate) * vsize;
        if (fee < required) {
            tracker.logEvent("mempool", "Rejected tx: fee rate below min relay", "warning",
                             "{\"peer\":\"" + options.peerHost + "\"}");
            return false;
        }
    }
    return true;
}

bool transactionMeetsPeerFeefilter(const messages::Transaction& tx, db::NodeStateStore& tracker,
                                   std::optional<std::int64_t> peerFeeFilterSatKvb) {
    if (!peerFeeFilterSatKvb.has_value() || *peerFeeFilterSatKvb <= 0) {
        return true;
    }
    const int vsize = estimateTxVirtualSizeScaffold(tx);
    if (vsize <= 0) {
        return false;
    }
    const auto fee = transactionFeeKnownPrevouts(tx, tracker);
    if (!fee.has_value() || *fee < 0) {
        return true;
    }
    return *fee * 1000 >= *peerFeeFilterSatKvb * vsize;
}

Mempool::Mempool(const MempoolOptions& options)
    : maxSizeBytes_(options.maxSizeBytes),
      maxTxCount_(options.mempoolMaxCount.has_value()
                      ? *options.mempoolMaxCount
                      : (options.settings != nullptr ? options.settings->mempoolMaxCount : config::Settings::fromEnv().mempoolMaxCount)),
      maxAgeSeconds_(options.mempoolMaxAgeSeconds.has_value()
                         ? *options.mempoolMaxAgeSeconds
                         : (options.settings != nullptr ? options.settings->mempoolMaxAgeSeconds
                                                        : config::Settings::fromEnv().mempoolMaxAgeSeconds)),
      tracker_(options.tracker),
      orphanPool_(options.orphanPool),
      policy_(options.settings != nullptr ? *options.settings : config::Settings::fromEnv()) {
    if (maxSizeBytes_ < 1) {
        throw std::invalid_argument("max_size_bytes must be positive");
    }
    if (maxTxCount_ < 0) {
        throw std::invalid_argument("mempool_max_count must be >= 0 (0 means unlimited)");
    }
    if (maxAgeSeconds_ < 0) {
        throw std::invalid_argument("mempool_max_age_seconds must be >= 0 (0 disables age eviction)");
    }
    persistStats();
}

std::string Mempool::txidHexKey(const std::vector<std::uint8_t>& txid) {
    return bytesToHex(txid);
}

std::unordered_map<PrevoutKey, UtxoOverlayRow, PrevoutKeyHash> Mempool::mempoolUtxoOverlay() const {
    std::unordered_map<PrevoutKey, UtxoOverlayRow, PrevoutKeyHash> rows;
    for (const auto& [_, entry] : txById_) {
        const auto prodTxid = consensus::transactionTxid(entry.tx);
        for (std::size_t voutIdx = 0; voutIdx < entry.tx.outputs.size(); ++voutIdx) {
            const auto& output = entry.tx.outputs[voutIdx];
            rows[{prodTxid, static_cast<int>(voutIdx)}] = UtxoOverlayRow{output.value, output.scriptPubkey};
        }
    }
    return rows;
}

std::vector<std::vector<std::uint8_t>> Mempool::clusterPostOrder(const std::vector<std::uint8_t>& root) const {
    const auto rootKey = txidHexKey(root);
    std::vector<std::vector<std::uint8_t>> order;
    std::unordered_set<std::string> visiting;

    const std::function<void(const std::string&)> dfs = [&](const std::string& tidKey) {
        if (!txById_.contains(tidKey) || visiting.contains(tidKey)) {
            return;
        }
        visiting.insert(tidKey);
        const auto spendersIt = spenders_.find(tidKey);
        if (spendersIt != spenders_.end()) {
            for (const auto& childKey : spendersIt->second) {
                dfs(childKey);
            }
        }
        visiting.erase(tidKey);
        order.push_back(txById_.at(tidKey).txid);
    };

    dfs(rootKey);
    return order;
}

bool Mempool::removeSingle(const std::vector<std::uint8_t>& txid) {
    const auto key = txidHexKey(txid);
    const auto it = txById_.find(key);
    if (it == txById_.end()) {
        return false;
    }
    const auto tx = it->second.tx;
    const auto wtxid = consensus::transactionWtxid(tx);
    byWtxid_.erase(bytesToHex(wtxid));
    for (const auto& input : tx.inputs) {
        claimedPrevouts_.erase(inputPrevoutKey(input));
        const auto parentKey = txidHexKey(input.previousOutput.hash);
        const auto spendersIt = spenders_.find(parentKey);
        if (spendersIt != spenders_.end()) {
            spendersIt->second.erase(key);
            if (spendersIt->second.empty()) {
                spenders_.erase(spendersIt);
            }
        }
    }
    spenders_.erase(key);
    sizeBytes_ -= serializedLen(tx);
    txById_.erase(it);
    return true;
}

int Mempool::evictOldestCluster() {
    if (txById_.empty()) {
        return 0;
    }
    const auto oldest = std::min_element(txById_.begin(), txById_.end(),
                                         [](const auto& a, const auto& b) { return a.second.addedAt < b.second.addedAt; });
    const auto txid = consensus::transactionTxid(oldest->second.tx);
    int removed = 0;
    for (const auto& tid : clusterPostOrder(txid)) {
        if (contains(tid) && removeSingle(tid)) {
            ++removed;
        }
    }
    return removed;
}

void Mempool::linkIncomingSpenders(const std::vector<std::uint8_t>& txid, const messages::Transaction& tx) {
    const auto childKey = txidHexKey(txid);
    for (const auto& input : tx.inputs) {
        const auto parentKey = txidHexKey(input.previousOutput.hash);
        if (txById_.contains(parentKey)) {
            spenders_[parentKey].insert(childKey);
        }
    }
}

void Mempool::tryPromoteOrphansFor(const messages::Transaction& producer) {
    if (orphanPool_ == nullptr || tracker_ == nullptr) {
        return;
    }
    const auto prodTxid = consensus::transactionTxid(producer);
    for (std::size_t voutIdx = 0; voutIdx < producer.outputs.size(); ++voutIdx) {
        const auto ready = orphanPool_->takeReadyTransactionsForPrevout({prodTxid, static_cast<int>(voutIdx)});
        for (const auto& candidate : ready) {
            const auto overlay = mempoolUtxoOverlay();
            config::Settings promoteSettings = policy_;
            promoteSettings.enableOrphanPool = true;
            AcceptTransactionOptions acceptOpts;
            acceptOpts.settings = &promoteSettings;
            acceptOpts.mempoolClaimedPrevouts = &claimedPrevouts_;
            acceptOpts.mempoolUtxoOverlay = &overlay;
            acceptOpts.orphanPool = orphanPool_;
            acceptOpts.deferOrphans = true;
            if (mempool::acceptTransaction(candidate, *tracker_, acceptOpts) && add(candidate)) {
                continue;
            }
            const auto requeue = collectMissingPrevouts(candidate, *tracker_, &overlay, &claimedPrevouts_);
            if (requeue.has_value() && !requeue->empty()) {
                orphanPool_->tryAdd(candidate, *requeue);
            }
        }
    }
}

std::set<PrevoutKey> Mempool::claimedPrevoutsFrozen() const {
    return claimedPrevouts_;
}

std::optional<double> Mempool::entryAddedAt(const std::vector<std::uint8_t>& txid) const {
    const auto it = txById_.find(txidHexKey(txid));
    if (it == txById_.end()) {
        return std::nullopt;
    }
    return it->second.addedAt;
}

void Mempool::persistStats() {
    if (tracker_ == nullptr) {
        return;
    }
    tracker_->setMeta("mempool_tx_count", std::to_string(txById_.size()));
    tracker_->setMeta("mempool_size_bytes", std::to_string(sizeBytes_));
}

std::optional<messages::Transaction> Mempool::get(const std::vector<std::uint8_t>& txid) const {
    const auto it = txById_.find(txidHexKey(txid));
    if (it == txById_.end()) {
        return std::nullopt;
    }
    return it->second.tx;
}

std::vector<messages::Transaction> Mempool::iterPooledTransactions() const {
    std::vector<messages::Transaction> out;
    out.reserve(txById_.size());
    for (const auto& [_, entry] : txById_) {
        out.push_back(entry.tx);
    }
    return out;
}

std::optional<messages::Transaction> Mempool::getForInv(std::uint32_t invType,
                                                        std::span<const std::uint8_t> invHash) const {
    const std::vector<std::uint8_t> hash(invHash.begin(), invHash.end());
    if (invType == messages::MSG_WITNESS_TX) {
        const auto it = byWtxid_.find(bytesToHex(hash));
        if (it == byWtxid_.end()) {
            return std::nullopt;
        }
        return it->second;
    }
    if (invType == messages::MSG_TX) {
        return get(hash);
    }
    return std::nullopt;
}

bool Mempool::contains(const std::vector<std::uint8_t>& txid) const {
    return txById_.contains(txidHexKey(txid));
}

std::size_t Mempool::serializedLen(const messages::Transaction& tx) const {
    return tx.serialize(true).size();
}

bool Mempool::acceptTransaction(const messages::Transaction& tx, const AcceptTransactionOptions& options) {
    if (tracker_ == nullptr) {
        throw std::runtime_error("Mempool.acceptTransaction requires a tracker");
    }
    AcceptTransactionOptions merged = options;
    if (merged.mempoolClaimedPrevouts == nullptr) {
        merged.mempoolClaimedPrevouts = &claimedPrevouts_;
    }
    if (!mempool::acceptTransaction(tx, *tracker_, merged)) {
        return false;
    }
    return add(tx);
}

bool Mempool::add(const messages::Transaction& tx) {
    const auto txid = consensus::transactionTxid(tx);
    const auto key = txidHexKey(txid);
    if (txById_.contains(key)) {
        return false;
    }
    const double now = nowSeconds();
    evictExpired(now);
    const auto size = serializedLen(tx);
    while (maxTxCount_ > 0 && static_cast<int>(txById_.size()) >= maxTxCount_) {
        if (evictOldestCluster() == 0) {
            break;
        }
    }
    while (sizeBytes_ + size > maxSizeBytes_) {
        if (evictOldestCluster() == 0) {
            break;
        }
    }
    if (sizeBytes_ + size > maxSizeBytes_) {
        return false;
    }
    if (maxTxCount_ > 0 && static_cast<int>(txById_.size()) >= maxTxCount_) {
        return false;
    }
    const auto wtxid = consensus::transactionWtxid(tx);
    txById_[key] = MempoolEntry{tx, txid, now};
    byWtxid_[bytesToHex(wtxid)] = tx;
    linkIncomingSpenders(txid, tx);
    for (const auto& input : tx.inputs) {
        claimedPrevouts_.insert(inputPrevoutKey(input));
    }
    sizeBytes_ += size;
    persistStats();
    tryPromoteOrphansFor(tx);
    return true;
}

bool Mempool::remove(const std::vector<std::uint8_t>& txid) {
    if (!removeSingle(txid)) {
        return false;
    }
    persistStats();
    return true;
}

int Mempool::evictExpired(double nowSecondsValue) {
    if (maxAgeSeconds_ <= 0) {
        return 0;
    }
    int removed = 0;
    while (true) {
        std::vector<std::vector<std::uint8_t>> expired;
        for (const auto& [key, entry] : txById_) {
            if (nowSecondsValue - entry.addedAt > maxAgeSeconds_) {
                expired.push_back(entry.txid);
            }
        }
        if (expired.empty()) {
            persistStats();
            return removed;
        }
        const auto oldest = *std::min_element(expired.begin(), expired.end(), [&](const auto& a, const auto& b) {
            return txById_.at(txidHexKey(a)).addedAt < txById_.at(txidHexKey(b)).addedAt;
        });
        for (const auto& tid : clusterPostOrder(oldest)) {
            if (contains(tid) && removeSingle(tid)) {
                ++removed;
            }
        }
    }
}

int Mempool::evictOverCapacity() {
    int removed = 0;
    while (!txById_.empty()) {
        const bool overCount = maxTxCount_ > 0 && static_cast<int>(txById_.size()) > maxTxCount_;
        const bool overBytes = sizeBytes_ > maxSizeBytes_;
        if (!overCount && !overBytes) {
            break;
        }
        const int n = evictOldestCluster();
        if (n == 0) {
            break;
        }
        removed += n;
    }
    persistStats();
    return removed;
}

}  // namespace cpbitnode::mempool
