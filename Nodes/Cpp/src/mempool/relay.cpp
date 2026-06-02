#include "cpbitnode/mempool/relay.hpp"

#include "cpbitnode/consensus/merkle.hpp"
#include "cpbitnode/messages/transaction.hpp"

namespace cpbitnode::mempool {

bool handleInboundTxMessage(Mempool& pool, db::NodeStateStore& tracker, const config::Settings& settings,
                            std::span<const std::uint8_t> payload, const std::string& peerHost) {
    messages::Transaction tx;
    try {
        std::tie(tx, std::ignore) = messages::deserializeTransaction(payload);
    } catch (const std::exception& exc) {
        tracker.logEvent("p2p", std::string("Malformed tx message: ") + exc.what(), "warning",
                         "{\"host\":\"" + peerHost + "\"}");
        return false;
    }
    tracker.markWireCapability("tx.tx.recv", true, "live", "deserialized inbound tx");
    AcceptTransactionOptions options;
    options.settings = &settings;
    options.peerHost = peerHost;
    if (pool.acceptTransaction(tx, options)) {
        tracker.logEvent("mempool", "Accepted incoming transaction", "info", "{\"peer\":\"" + peerHost + "\"}");
        return true;
    }
    tracker.logEvent("mempool", "Transaction not pooled (duplicate or capacity)", "debug",
                     "{\"peer\":\"" + peerHost + "\"}");
    return false;
}

std::vector<messages::InventoryVector> txInventoryNeedGetdata(std::span<const messages::InventoryVector> items,
                                                                const Mempool* pool) {
    std::vector<messages::InventoryVector> out;
    if (pool == nullptr) {
        out.assign(items.begin(), items.end());
        return out;
    }
    for (const auto& item : items) {
        if (!pool->getForInv(item.type, item.hash)) {
            out.push_back(item);
        }
    }
    return out;
}

GetdataTxServeResult resolveGetdataTxInventory(const Mempool& pool,
                                               std::span<const messages::InventoryVector> inventory) {
    GetdataTxServeResult result;
    for (const auto& item : inventory) {
        if (item.type != messages::MSG_TX && item.type != messages::MSG_WITNESS_TX) {
            continue;
        }
        const auto tx = pool.getForInv(item.type, item.hash);
        if (!tx) {
            result.notFound.push_back(item);
            continue;
        }
        result.served.push_back(*tx);
    }
    return result;
}

void replyGetdataTxInventory(p2p::PeerConnection& peer, const Mempool* pool, db::NodeStateStore& tracker,
                             std::span<const messages::InventoryVector> inventory) {
    if (inventory.empty()) {
        return;
    }
    std::vector<messages::InventoryVector> notFound;
    bool served = false;
    for (const auto& item : inventory) {
        if (item.type != messages::MSG_TX && item.type != messages::MSG_WITNESS_TX) {
            continue;
        }
        if (pool == nullptr) {
            notFound.push_back(item);
            continue;
        }
        const auto tx = pool->getForInv(item.type, item.hash);
        if (!tx) {
            notFound.push_back(item);
            continue;
        }
        const bool includeWitness = item.type == messages::MSG_WITNESS_TX;
        const auto wire = tx->serialize(includeWitness);
        peer.send(std::string(messages::Transaction::kCommand), wire);
        served = true;
    }
    if (served) {
        tracker.markWireCapability("serve.getdata.txs", true, "live",
                                   "served mempool tx over getdata (MSG_TX or MSG_WITNESS_TX)");
    }
    if (!notFound.empty()) {
        messages::NotFoundMessage nf;
        nf.inventory = std::move(notFound);
        peer.send(messages::NotFoundMessage::kCommand, nf.serialize());
    }
}

}  // namespace cpbitnode::mempool
