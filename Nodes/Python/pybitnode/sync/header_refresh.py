"""Decide whether pybitnode-sync should run networked header refresh before block download."""

from __future__ import annotations

from enum import Enum

from pybitnode.chain.params import ChainParams
from pybitnode.config import Settings
from pybitnode.db.tracker import ProjectTracker
from pybitnode.sync.headers import (
    HEADER_SYNC_NEAR_PEER_TIP,
    local_header_tip_height,
    should_skip_header_download,
)


class HeaderRefreshAction(str, Enum):
    SKIP_SYNC_SKIP_HEADERS = "skip_sync_skip_headers"
    SKIP_NO_HEADER_REFRESH = "skip_no_header_refresh"
    SKIP_LOCAL_HEADERS_COVER_TARGET = "skip_local_headers_cover_target"
    SKIP_NEAR_PEER_TIP = "skip_near_peer_tip"
    SKIP_ALIGNED_DB_AHEAD_OF_PEER = "skip_aligned_db_ahead_of_peer"
    NETWORK_SYNC = "network_sync"


def db_headers_aligned_with_sync_state(*, sync_best_height: int, local_tip: int) -> bool:
    if sync_best_height <= 0:
        return False
    return abs(sync_best_height - local_tip) <= HEADER_SYNC_NEAR_PEER_TIP


def decide_header_refresh_action(
    settings: Settings,
    tracker: ProjectTracker,
    chain: ChainParams,
    *,
    sync_best_height: int,
    advertised_peer_height: int,
) -> HeaderRefreshAction:
    """Return how sync_blocks should treat networked header refresh."""
    if settings.sync_skip_headers:
        return HeaderRefreshAction.SKIP_SYNC_SKIP_HEADERS
    if settings.no_header_refresh:
        return HeaderRefreshAction.SKIP_NO_HEADER_REFRESH

    blocks_target = settings.blocks_target_height or 0
    if blocks_target > 0 and tracker.max_header_height() >= blocks_target:
        return HeaderRefreshAction.SKIP_LOCAL_HEADERS_COVER_TARGET

    local_tip = local_header_tip_height(tracker, chain)
    if advertised_peer_height >= 0 and should_skip_header_download(
        tracker,
        chain,
        peer_tip_height=advertised_peer_height,
    ):
        return HeaderRefreshAction.SKIP_NEAR_PEER_TIP

    aligned_db = db_headers_aligned_with_sync_state(
        sync_best_height=sync_best_height,
        local_tip=local_tip,
    )
    if aligned_db and advertised_peer_height > local_tip + HEADER_SYNC_NEAR_PEER_TIP:
        return HeaderRefreshAction.SKIP_ALIGNED_DB_AHEAD_OF_PEER

    return HeaderRefreshAction.NETWORK_SYNC


def header_refresh_log_message(action: HeaderRefreshAction) -> str:
    if action is HeaderRefreshAction.SKIP_SYNC_SKIP_HEADERS:
        return "SYNC_SKIP_HEADERS=1: skipping networked header sync"
    if action is HeaderRefreshAction.SKIP_NO_HEADER_REFRESH:
        return "header_refresh_skipped_no_header_refresh_flag"
    if action is HeaderRefreshAction.SKIP_LOCAL_HEADERS_COVER_TARGET:
        return "header_refresh_skipped_local_headers_cover_target"
    return action.value
