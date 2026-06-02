#pragma once

#include <utility>
#include <vector>

#include "cpbitnode/chain/params.hpp"
#include "cpbitnode/config/settings.hpp"
#include "cpbitnode/db/chainstate.hpp"
#include "cpbitnode/db/node_state.hpp"
#include "cpbitnode/p2p/peer.hpp"
#include "cpbitnode/storage/blocks.hpp"

namespace cpbitnode::sync {

std::pair<int, std::vector<std::vector<std::uint8_t>>> connectStoredBlocks(db::NodeStateStore& tracker,
                                                                           storage::BlockStore& blockStore,
                                                                           const chain::ChainParams& chain);
std::pair<int, std::vector<std::vector<std::uint8_t>>> connectStoredBlocks(db::NodeStateStore& tracker,
                                                                           db::ChainstateStore& chainstate,
                                                                           storage::BlockStore& blockStore,
                                                                           const chain::ChainParams& chain);
int rebuildValidatedChain(db::NodeStateStore& tracker, storage::BlockStore& blockStore,
                          const chain::ChainParams& chain);
int rebuildValidatedChain(db::NodeStateStore& tracker, db::ChainstateStore& chainstate,
                          storage::BlockStore& blockStore, const chain::ChainParams& chain);
int repairValidatedIfAhead(db::NodeStateStore& tracker, storage::BlockStore& blockStore,
                           const chain::ChainParams& chain);
int repairValidatedIfAhead(db::NodeStateStore& tracker, db::ChainstateStore& chainstate,
                           storage::BlockStore& blockStore, const chain::ChainParams& chain);

std::optional<std::pair<std::vector<std::uint8_t>, p2p::PeerConnection*>> requestBlockFromPeers(
    const std::vector<p2p::PeerConnection*>& peers, const std::vector<std::uint8_t>& blockHash);

std::optional<std::pair<std::vector<std::uint8_t>, p2p::PeerConnection*>> requestBlockFromPeersParallel(
    const std::vector<p2p::PeerConnection*>& peers, const std::vector<std::uint8_t>& blockHash);

int syncBlocksBatch(const std::vector<p2p::PeerConnection*>& peers, db::NodeStateStore& tracker,
                    const chain::ChainParams& chain, storage::BlockStore& blockStore, int batchSize, int maxBlocks,
                    int parallelDownloads = 0);
int syncBlocksBatch(const std::vector<p2p::PeerConnection*>& peers, db::NodeStateStore& tracker,
                    db::ChainstateStore& chainstate, const chain::ChainParams& chain, storage::BlockStore& blockStore,
                    int batchSize, int maxBlocks, int parallelDownloads = 0);

int syncBlocksToTip(const std::vector<p2p::PeerConnection*>& peers, db::NodeStateStore& tracker,
                    const chain::ChainParams& chain, storage::BlockStore& blockStore, const config::Settings& settings);
int syncBlocksToTip(const std::vector<p2p::PeerConnection*>& peers, db::NodeStateStore& tracker,
                    db::ChainstateStore& chainstate, const chain::ChainParams& chain,
                    storage::BlockStore& blockStore, const config::Settings& settings);

}  // namespace cpbitnode::sync
