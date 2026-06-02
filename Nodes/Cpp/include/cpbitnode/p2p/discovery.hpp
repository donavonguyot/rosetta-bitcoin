#pragma once

#include "cpbitnode/chain/params.hpp"
#include "cpbitnode/config/settings.hpp"
#include "cpbitnode/db/node_state.hpp"

#include <functional>
#include <string>
#include <utility>
#include <vector>

namespace cpbitnode::p2p {

using ResolveSeedPeersFn =
    std::function<std::vector<std::pair<std::string, int>>(const chain::ChainParams&, int count)>;

std::vector<std::pair<std::string, int>> resolveSeedPeers(const chain::ChainParams& chain, int count);
std::pair<std::string, int> resolveSeedFallback(const chain::ChainParams& chain);

std::vector<std::pair<std::string, int>> mergePeerCandidates(
    const chain::ChainParams& chain, const std::vector<std::pair<std::string, int>>& manual,
    const std::vector<std::pair<std::string, int>>& stored,
    const std::vector<std::pair<std::string, int>>& discovered,
    const std::vector<std::pair<std::string, int>>& seeds);

std::vector<std::pair<std::string, int>> bootstrapPeerTargets(db::NodeStateStore& tracker,
                                                              const chain::ChainParams& chain,
                                                              const config::Settings& settings,
                                                              const std::vector<std::pair<std::string, int>>& manualPeers,
                                                              ResolveSeedPeersFn resolveSeeds = resolveSeedPeers);

}  // namespace cpbitnode::p2p
