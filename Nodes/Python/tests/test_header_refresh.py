"""Tests for pybitnode.sync.header_refresh decision logic."""

from __future__ import annotations

import pytest

from pybitnode.chain.params import TESTNET4
from pybitnode.config import Settings
from pybitnode.chainstate.tracker import ProjectTracker
from pybitnode.sync.header_refresh import (
    HeaderRefreshAction,
    decide_header_refresh_action,
    header_refresh_log_message,
)
from pybitnode.sync.headers import HEADER_SYNC_NEAR_PEER_TIP, ensure_genesis


def _seed_headers_through(tracker: ProjectTracker, through: int) -> None:
    ensure_genesis(tracker, TESTNET4)
    for height in range(1, through + 1):
        prev = tracker.get_header_hash(height - 1) or TESTNET4.genesis_hash
        tracker.record_header(height, f"{height:064x}", prev, 1_692_012_345 + height)
    tracker.upsert_sync_state(
        TESTNET4.name,
        best_height=through,
        best_hash=tracker.get_header_hash(through) or TESTNET4.genesis_hash,
        sync_status="headers_syncing",
    )


def test_skip_when_no_header_refresh_flag(tmp_path):
    tracker = ProjectTracker(tmp_path / "nhr-chainstate")
    _seed_headers_through(tracker, 3)
    action = decide_header_refresh_action(
        Settings(no_header_refresh=True),
        tracker,
        TESTNET4,
        sync_best_height=3,
        advertised_peer_height=999_999,
    )
    assert action is HeaderRefreshAction.SKIP_NO_HEADER_REFRESH
    assert header_refresh_log_message(action) == "header_refresh_skipped_no_header_refresh_flag"
    tracker.close()


def test_skip_when_sync_skip_headers_flag(tmp_path):
    tracker = ProjectTracker(tmp_path / "ssh-chainstate")
    _seed_headers_through(tracker, 3)
    action = decide_header_refresh_action(
        Settings(sync_skip_headers=True),
        tracker,
        TESTNET4,
        sync_best_height=3,
        advertised_peer_height=999_999,
    )
    assert action is HeaderRefreshAction.SKIP_SYNC_SKIP_HEADERS
    assert (
        header_refresh_log_message(action)
        == "SYNC_SKIP_HEADERS=1: skipping networked header sync"
    )
    tracker.close()


def test_skip_aligned_db_ahead_of_peer(tmp_path):
    """DB/sync_state agree on tip but peer start_height is far ahead — avoid getheaders churn."""
    tracker = ProjectTracker(tmp_path / "align-chainstate")
    tip = 100
    _seed_headers_through(tracker, tip)
    action = decide_header_refresh_action(
        Settings(blocks_target_height=0),
        tracker,
        TESTNET4,
        sync_best_height=tip,
        advertised_peer_height=tip + 10,
    )
    assert action is HeaderRefreshAction.SKIP_ALIGNED_DB_AHEAD_OF_PEER
    assert header_refresh_log_message(action) == "skip_aligned_db_ahead_of_peer"
    tracker.close()


def test_skip_when_max_header_covers_blocks_target(tmp_path):
    tracker = ProjectTracker(tmp_path / "cover-chainstate")
    _seed_headers_through(tracker, 50)
    tracker.set_validated_tip(10, "0" * 64)
    action = decide_header_refresh_action(
        Settings(blocks_target_height=40),
        tracker,
        TESTNET4,
        sync_best_height=50,
        advertised_peer_height=100,
    )
    assert action is HeaderRefreshAction.SKIP_LOCAL_HEADERS_COVER_TARGET
    assert (
        header_refresh_log_message(action)
        == "header_refresh_skipped_local_headers_cover_target"
    )
    tracker.close()


def test_network_sync_when_headers_do_not_cover_target(tmp_path):
    tracker = ProjectTracker(tmp_path / "need-chainstate")
    ensure_genesis(tracker, TESTNET4)
    tracker.upsert_sync_state(TESTNET4.name, best_height=0, best_hash=TESTNET4.genesis_hash)
    action = decide_header_refresh_action(
        Settings(blocks_target_height=5000),
        tracker,
        TESTNET4,
        sync_best_height=0,
        advertised_peer_height=900_000,
    )
    assert action is HeaderRefreshAction.NETWORK_SYNC
    tracker.close()


def test_skip_near_peer_tip(tmp_path):
    tracker = ProjectTracker(tmp_path / "near-chainstate")
    tip = 10_000
    _seed_headers_through(tracker, tip - HEADER_SYNC_NEAR_PEER_TIP)
    action = decide_header_refresh_action(
        Settings(blocks_target_height=0),
        tracker,
        TESTNET4,
        sync_best_height=tip - HEADER_SYNC_NEAR_PEER_TIP,
        advertised_peer_height=tip,
    )
    assert action is HeaderRefreshAction.SKIP_NEAR_PEER_TIP
    tracker.close()


@pytest.mark.asyncio
async def test_sync_blocks_skips_network_header_refresh_when_target_covered(
    tmp_path, monkeypatch
):
    from pybitnode.sync_runner import sync_blocks

    state_path = tmp_path / "run-chainstate"
    tracker = ProjectTracker(state_path)
    _seed_headers_through(tracker, 100)
    tracker.set_validated_tip(5, "0" * 64)
    tracker.close()

    sync_headers_calls: list[dict] = []

    async def fake_bootstrap(self, manual_peers, *, start_height=0):
        peer = type("P", (), {})()
        peer.host, peer.port = "manual", 48333
        peer.is_connected = True
        peer.remote_version = type("RV", (), {"start_height": 50})()
        self.connections = [peer]

    async def fake_sync_headers(self, **kwargs):
        sync_headers_calls.append(kwargs)
        return 0

    async def fake_sync_blocks(self, block_store):
        return 0

    async def fake_close(self):
        return None

    monkeypatch.setattr("pybitnode.p2p.manager.PeerManager.bootstrap", fake_bootstrap)
    monkeypatch.setattr("pybitnode.p2p.manager.PeerManager.sync_headers", fake_sync_headers)
    monkeypatch.setattr("pybitnode.p2p.manager.PeerManager.sync_blocks", fake_sync_blocks)
    monkeypatch.setattr("pybitnode.p2p.manager.PeerManager.close", fake_close)
    monkeypatch.setattr(
        "pybitnode.sync_runner.connect_stored_blocks",
        lambda *a, **k: (0, []),
    )
    monkeypatch.setattr("pybitnode.sync_runner.repair_validated_if_ahead", lambda *a, **k: None)

    settings = Settings(
        data_dir=str(tmp_path / "data"),
        state_path=str(state_path),
        blocks_target_height=80,
        peers="manual:48333",
    )
    (tmp_path / "data" / "blocks").mkdir(parents=True)

    await sync_blocks(settings)
    assert sync_headers_calls == []
