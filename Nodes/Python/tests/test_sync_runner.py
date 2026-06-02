from __future__ import annotations

from unittest.mock import Mock

import pytest

from pybitnode.chain.params import TESTNET4
from pybitnode.config import Settings
from pybitnode.db.tracker import ProjectTracker
from pybitnode.p2p.manager import PeerManager
from pybitnode.storage.blocks import BlockStore
from pybitnode.sync.headers import ensure_genesis


def test_settings_blocks_target_height_from_env(monkeypatch):
    monkeypatch.setenv("BLOCKS_TARGET_HEIGHT", "101")
    settings = Settings.from_env()
    assert settings.blocks_target_height == 101


def test_settings_sync_timing_from_env(monkeypatch):
    monkeypatch.setenv("SYNC_TIMING", "1")
    settings = Settings.from_env()
    assert settings.sync_timing is True


@pytest.mark.asyncio
async def test_peer_manager_passes_parallel_block_downloads_from_settings(tmp_path, monkeypatch):
    captured: dict = {}

    async def fake_sync_blocks_to_tip(*_args, **kwargs) -> int:
        captured.update(kwargs)
        return 0

    monkeypatch.setattr("pybitnode.p2p.manager.sync_blocks_to_tip", fake_sync_blocks_to_tip)

    tracker = ProjectTracker(tmp_path / "parallel.db")
    ensure_genesis(tracker, TESTNET4)
    settings = Settings(parallel_block_downloads=5)
    mgr = PeerManager(TESTNET4, tracker, settings)
    store = BlockStore(tmp_path / "blocks", TESTNET4.magic)
    await mgr.sync_blocks(store)
    assert captured.get("parallel_downloads") == 5
    tracker.close()


@pytest.mark.asyncio
async def test_sync_blocks_to_tip_stops_at_target_height(tmp_path, monkeypatch):
    from pybitnode.p2p.peer import PeerConnection
    from pybitnode.sync.blocks import sync_blocks_to_tip

    tracker = ProjectTracker(tmp_path / "target.db")
    ensure_genesis(tracker, TESTNET4)
    for height in range(1, 4):
        tracker.record_header(height, f"hash{height}", TESTNET4.genesis_hash if height == 1 else f"hash{height-1}", 100 + height)

    calls = {"count": 0}

    async def fake_batch(*args, **kwargs):
        calls["count"] += 1
        height = tracker.get_validated_height("testnet4") + 1
        if height > 3:
            return 0
        tracker.set_validated_tip(height, f"hash{height}")
        tracker.record_block(height, f"hash{height}", "blk00000.dat", 0, 100)
        return 1

    monkeypatch.setattr("pybitnode.sync.blocks.sync_blocks_batch", fake_batch)
    store = BlockStore(tmp_path / "blocks", TESTNET4.magic)
    total = await sync_blocks_to_tip(
        [Mock(spec=PeerConnection)],
        tracker,
        TESTNET4,
        store,
        batch_size=8,
        max_blocks=0,
        target_height=2,
    )
    assert total == 2
    assert tracker.get_validated_height("testnet4") == 2
    tracker.close()
