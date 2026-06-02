from __future__ import annotations

from unittest.mock import AsyncMock, MagicMock

import pytest

from pybitnode.chain.params import TESTNET4
from pybitnode.config import Settings
from pybitnode.db.tracker import ProjectTracker
from pybitnode.p2p.manager import PeerManager
from pybitnode.sync.headers import HEADER_SYNC_NEAR_PEER_TIP, ensure_genesis, should_skip_header_download


def test_should_skip_header_download_near_peer_tip(tmp_path):
    tracker = ProjectTracker(tmp_path / "near.db")
    ensure_genesis(tracker, TESTNET4)
    h = 10_000
    tracker.upsert_sync_state(TESTNET4.name, best_height=h - HEADER_SYNC_NEAR_PEER_TIP, sync_status="headers_syncing")
    assert should_skip_header_download(tracker, TESTNET4, peer_tip_height=h)

    tracker.upsert_sync_state(TESTNET4.name, best_height=h - HEADER_SYNC_NEAR_PEER_TIP - 1, sync_status="headers_syncing")
    assert not should_skip_header_download(tracker, TESTNET4, peer_tip_height=h)


def test_should_skip_unknown_peer_tip_never_skips(tmp_path):
    tracker = ProjectTracker(tmp_path / "unk.db")
    ensure_genesis(tracker, TESTNET4)
    tracker.upsert_sync_state(TESTNET4.name, best_height=999_999, sync_status="headers_current")
    assert not should_skip_header_download(tracker, TESTNET4, peer_tip_height=-1)


@pytest.mark.asyncio
async def test_ordered_header_peers_prefers_manual():
    tracker = MagicMock()
    tracker.get_peer_endpoint_ban_score = MagicMock(return_value=0)
    mgr = PeerManager(TESTNET4, tracker, Settings())
    mgr._manual_sync_peers = {("manual.example", 8333)}
    rv_low = MagicMock(start_height=100)
    rv_high = MagicMock(start_height=900_000)
    p_manual = MagicMock(spec=["host", "port", "is_connected", "remote_version"])
    p_manual.host, p_manual.port = "manual.example", 8333
    p_manual.is_connected = True
    p_manual.remote_version = rv_low

    p_auto = MagicMock(spec=["host", "port", "is_connected", "remote_version"])
    p_auto.host, p_auto.port = "seed.example", 48333
    p_auto.is_connected = True
    p_auto.remote_version = rv_high

    mgr.connections = [p_auto, p_manual]
    ordered = mgr._ordered_sync_peers()
    assert ordered[0] is p_manual
    assert ordered[1] is p_auto


@pytest.mark.asyncio
async def test_sync_headers_tries_next_peer_on_connection_error():
    tracker = MagicMock()
    manager = PeerManager(TESTNET4, tracker, Settings())
    rv = MagicMock(start_height=10_000)
    p_bad = MagicMock(spec=["host", "port", "is_connected", "remote_version"])
    p_bad.host, p_bad.port = "dead", 8333
    p_bad.is_connected = True
    p_bad.remote_version = rv
    p_bad.sync_headers = AsyncMock(side_effect=ConnectionError("closed mid-headers"))

    p_ok = MagicMock(spec=["host", "port", "is_connected", "remote_version"])
    p_ok.host, p_ok.port = "ok", 8333
    p_ok.is_connected = True
    p_ok.remote_version = rv
    p_ok.sync_headers = AsyncMock(return_value=3)

    manager.connections = [p_bad, p_ok]

    stored = await manager.sync_headers()

    assert stored == 3
    assert p_bad.sync_headers.await_count == 1
    assert p_ok.sync_headers.await_count == 1


@pytest.mark.asyncio
async def test_sync_headers_best_effort_when_locals_cover(monkeypatch, tmp_path):
    tracker = ProjectTracker(tmp_path / "bff.db")
    ensure_genesis(tracker, TESTNET4)
    for height in range(1, 4):
        prev = tracker.get_header_hash(height - 1) or TESTNET4.genesis_hash
        tracker.record_header(height, f"{height:064x}", prev, 1_692_012_345 + height)

    settings = Settings(blocks_target_height=2)

    mgr = PeerManager(TESTNET4, tracker, settings)
    p1 = MagicMock(spec=["host", "port", "is_connected", "remote_version"])
    p1.host, p1.port = "dead", 8333
    p1.is_connected = True
    p1.remote_version = MagicMock(start_height=999_999)
    p1.sync_headers = AsyncMock(side_effect=ConnectionError("boom"))

    p2 = MagicMock(spec=["host", "port", "is_connected", "remote_version"])
    p2.host, p2.port = "gone", 8333
    p2.is_connected = True
    p2.remote_version = MagicMock(start_height=999_999)
    p2.sync_headers = AsyncMock(side_effect=ConnectionError("boom"))

    mgr.connections = [p1, p2]

    out = await mgr.sync_headers(best_effort_if_headers_cover_followup_blocks=True)
    assert out == 0
    tracker.close()


@pytest.mark.asyncio
async def test_sync_headers_still_raises_when_best_effort_not_covered(monkeypatch, tmp_path):
    tracker = ProjectTracker(tmp_path / "narrow.db")
    ensure_genesis(tracker, TESTNET4)
    # Only genesis: cannot satisfy follow-up validation range needing height 5000+
    tracker.upsert_sync_state(TESTNET4.name, best_height=0, best_hash=TESTNET4.genesis_hash)
    settings = Settings(blocks_target_height=5000)

    mgr = PeerManager(TESTNET4, tracker, settings)
    p_bad = MagicMock(spec=["host", "port", "is_connected", "remote_version"])
    p_bad.host, p_bad.port = "dead", 8333
    p_bad.is_connected = True
    p_bad.remote_version = MagicMock(start_height=9_999_999)
    p_bad.sync_headers = AsyncMock(side_effect=ConnectionError("boom"))
    mgr.connections = [p_bad]

    with pytest.raises(ConnectionError):
        await mgr.sync_headers(best_effort_if_headers_cover_followup_blocks=True)

    tracker.close()
