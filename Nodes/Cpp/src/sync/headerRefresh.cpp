#include "cpbitnode/sync/headerRefresh.hpp"

#include "cpbitnode/sync/headers.hpp"

namespace cpbitnode::sync {

bool dbHeadersAlignedWithSyncState(int syncBestHeight, int localTip) {
    if (syncBestHeight <= 0) {
        return false;
    }
    return std::abs(syncBestHeight - localTip) <= kHeaderSyncNearPeerTip;
}

HeaderRefreshAction decideHeaderRefreshAction(const config::Settings& settings, const db::NodeStateStore& tracker,
                                              const chain::ChainParams& chain, int syncBestHeight,
                                              int advertisedPeerHeight) {
    if (settings.syncSkipHeaders) {
        return HeaderRefreshAction::SkipSyncSkipHeaders;
    }
    if (settings.noHeaderRefresh) {
        return HeaderRefreshAction::SkipNoHeaderRefresh;
    }

    const int blocksTarget = settings.blocksTargetHeight;
    if (blocksTarget > 0 && tracker.maxHeaderHeight() >= blocksTarget) {
        return HeaderRefreshAction::SkipLocalHeadersCoverTarget;
    }

    const int localTip = localHeaderTipHeight(tracker, chain);
    const bool localsCoverFollowup = localHeadersCoverBlockFollowup(tracker, chain, blocksTarget);
    if (advertisedPeerHeight >= 0 && localsCoverFollowup &&
        shouldSkipHeaderDownload(tracker, chain, advertisedPeerHeight)) {
        return HeaderRefreshAction::SkipNearPeerTip;
    }

    if (localsCoverFollowup && dbHeadersAlignedWithSyncState(syncBestHeight, localTip) &&
        advertisedPeerHeight > localTip + kHeaderSyncNearPeerTip) {
        return HeaderRefreshAction::SkipAlignedDbAheadOfPeer;
    }

    return HeaderRefreshAction::NetworkSync;
}

std::string headerRefreshLogMessage(HeaderRefreshAction action) {
    switch (action) {
        case HeaderRefreshAction::SkipSyncSkipHeaders:
            return "SYNC_SKIP_HEADERS=1: skipping networked header sync";
        case HeaderRefreshAction::SkipNoHeaderRefresh:
            return "header_refresh_skipped_no_header_refresh_flag";
        case HeaderRefreshAction::SkipLocalHeadersCoverTarget:
            return "header_refresh_skipped_local_headers_cover_target";
        case HeaderRefreshAction::SkipNearPeerTip:
            return "skip_near_peer_tip";
        case HeaderRefreshAction::SkipAlignedDbAheadOfPeer:
            return "skip_aligned_db_ahead_of_peer";
        case HeaderRefreshAction::NetworkSync:
            return "network_sync";
    }
    return "network_sync";
}

}  // namespace cpbitnode::sync
