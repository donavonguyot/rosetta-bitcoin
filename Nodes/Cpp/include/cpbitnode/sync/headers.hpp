#pragma once

#include "cpbitnode/chain/params.hpp"
#include "cpbitnode/config/settings.hpp"
#include "cpbitnode/db/node_state.hpp"
#include "cpbitnode/messages/block_header.hpp"
#include "cpbitnode/messages/headers.hpp"

#include <optional>
#include <string>
#include <tuple>
#include <vector>

namespace cpbitnode::p2p {
class PeerConnection;
}

namespace cpbitnode::sync {

inline constexpr int kHeaderSyncNearPeerTip = 2;

messages::BlockHeader ensureGenesis(db::NodeStateStore& state, const chain::ChainParams& chain);
void repairSyncState(db::NodeStateStore& state, const chain::ChainParams& chain);

std::vector<int> locatorHeights(int tip);
std::vector<std::vector<std::uint8_t>> nextLocator(db::NodeStateStore& state, const chain::ChainParams& chain);

std::tuple<int, std::string, int> persistHeaders(db::NodeStateStore& state, const chain::ChainParams& chain,
                                                 const messages::HeadersMessage& message);

bool headersSyncDone(int bestHeight, int peerHeight, int batchCount);
int localHeaderTipHeight(const db::NodeStateStore& state, const chain::ChainParams& chain);
int requiredHeaderTipForBlockFollowup(const db::NodeStateStore& state, const chain::ChainParams& chain,
                                      int blocksTargetHeight);
bool localHeadersCoverBlockFollowup(const db::NodeStateStore& state, const chain::ChainParams& chain,
                                    int blocksTargetHeight);
bool shouldSkipHeaderDownload(const db::NodeStateStore& state, const chain::ChainParams& chain, int peerTipHeight);
void markHeadersCurrent(db::NodeStateStore& state, const chain::ChainParams& chain);
int resolveBootstrapStartHeight(const db::NodeStateStore& state, const chain::ChainParams& chain,
                                const config::Settings& settings);

int syncHeadersToTip(p2p::PeerConnection& connection, std::optional<int> peerHeight = std::nullopt);

}  // namespace cpbitnode::sync
