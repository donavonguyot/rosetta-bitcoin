#pragma once

#include "cpbitnode/chain/params.hpp"
#include "cpbitnode/config/settings.hpp"
#include "cpbitnode/db/node_state.hpp"

#include <string>

namespace cpbitnode::sync {

enum class HeaderRefreshAction {
    SkipSyncSkipHeaders,
    SkipNoHeaderRefresh,
    SkipLocalHeadersCoverTarget,
    SkipNearPeerTip,
    SkipAlignedDbAheadOfPeer,
    NetworkSync,
};

bool dbHeadersAlignedWithSyncState(int syncBestHeight, int localTip);

HeaderRefreshAction decideHeaderRefreshAction(const config::Settings& settings, const db::NodeStateStore& tracker,
                                              const chain::ChainParams& chain, int syncBestHeight,
                                              int advertisedPeerHeight);

std::string headerRefreshLogMessage(HeaderRefreshAction action);

}  // namespace cpbitnode::sync
