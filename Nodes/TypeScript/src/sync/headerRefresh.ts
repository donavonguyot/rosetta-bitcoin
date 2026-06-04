import type { ChainParams } from "../chain/params.js";
import type { Settings } from "../config/settings.js";
import type { NativeNodeState } from "../runtime/nodeState.js";
import {
  HEADER_SYNC_NEAR_PEER_TIP,
  localHeaderTipHeight,
  shouldSkipHeaderDownload,
} from "./headers.js";

export enum HeaderRefreshAction {
  SkipSyncSkipHeaders = "skip_sync_skip_headers",
  SkipNoHeaderRefresh = "skip_no_header_refresh",
  SkipLocalHeadersCoverTarget = "skip_local_headers_cover_target",
  SkipNearPeerTip = "skip_near_peer_tip",
  SkipAlignedDbAheadOfPeer = "skip_aligned_db_ahead_of_peer",
  NetworkSync = "network_sync",
}

export function dbHeadersAlignedWithSyncState(syncBestHeight: number, localTip: number): boolean {
  if (syncBestHeight <= 0) return false;
  return Math.abs(syncBestHeight - localTip) <= HEADER_SYNC_NEAR_PEER_TIP;
}

export function decideHeaderRefreshAction(
  settings: Settings,
  tracker: NativeNodeState,
  chain: ChainParams,
  options: { syncBestHeight: number; advertisedPeerHeight: number },
): HeaderRefreshAction {
  if (settings.syncSkipHeaders) {
    return HeaderRefreshAction.SkipSyncSkipHeaders;
  }
  if (settings.noHeaderRefresh) {
    return HeaderRefreshAction.SkipNoHeaderRefresh;
  }

  const blocksTarget = settings.blocksTargetHeight || 0;
  if (blocksTarget > 0 && tracker.maxHeaderHeight(chain.name) >= blocksTarget) {
    return HeaderRefreshAction.SkipLocalHeadersCoverTarget;
  }

  const localTip = localHeaderTipHeight(tracker, chain);
  if (
    options.advertisedPeerHeight >= 0 &&
    shouldSkipHeaderDownload(tracker, chain, options.advertisedPeerHeight)
  ) {
    return HeaderRefreshAction.SkipNearPeerTip;
  }

  const alignedDb = dbHeadersAlignedWithSyncState(options.syncBestHeight, localTip);
  if (alignedDb && options.advertisedPeerHeight > localTip + HEADER_SYNC_NEAR_PEER_TIP) {
    return HeaderRefreshAction.SkipAlignedDbAheadOfPeer;
  }

  return HeaderRefreshAction.NetworkSync;
}

export function headerRefreshLogMessage(action: HeaderRefreshAction): string {
  switch (action) {
    case HeaderRefreshAction.SkipSyncSkipHeaders:
      return "SYNC_SKIP_HEADERS=1: skipping networked header sync";
    case HeaderRefreshAction.SkipNoHeaderRefresh:
      return "header_refresh_skipped_no_header_refresh_flag";
    case HeaderRefreshAction.SkipLocalHeadersCoverTarget:
      return "header_refresh_skipped_local_headers_cover_target";
    default:
      return action;
  }
}
