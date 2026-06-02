#pragma once

#include <span>
#include <string>
#include <vector>

#include "cpbitnode/config/settings.hpp"
#include "cpbitnode/db/node_state.hpp"
#include "cpbitnode/messages/inventory.hpp"
#include "cpbitnode/mempool/mempool.hpp"
#include "cpbitnode/p2p/peer.hpp"

namespace cpbitnode::mempool {

/** Deserialize inbound tx wire payload, run admission policy, and pool when accepted. */
bool handleInboundTxMessage(Mempool& pool, db::NodeStateStore& tracker, const config::Settings& settings,
                            std::span<const std::uint8_t> payload, const std::string& peerHost);

/** Filter inv/getdata tx vectors to hashes not already present in the mempool. */
std::vector<messages::InventoryVector> txInventoryNeedGetdata(std::span<const messages::InventoryVector> items,
                                                                const Mempool* pool);

struct GetdataTxServeResult {
    std::vector<messages::Transaction> served;
    std::vector<messages::InventoryVector> notFound;
};

/** Resolve mempool transactions for getdata tx inventory (future inbound server hook). */
GetdataTxServeResult resolveGetdataTxInventory(const Mempool& pool,
                                               std::span<const messages::InventoryVector> inventory);

/** Serve mempool transactions for inbound/outbound getdata tx inventory. */
void replyGetdataTxInventory(p2p::PeerConnection& peer, const Mempool* pool, db::NodeStateStore& tracker,
                             std::span<const messages::InventoryVector> inventory);

}  // namespace cpbitnode::mempool
