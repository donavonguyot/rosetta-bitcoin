from __future__ import annotations

from unittest.mock import AsyncMock, Mock

import pytest

from pybitnode.chain.params import TESTNET4
from pybitnode.config import Settings
from pybitnode.chainstate.tracker import ProjectTracker
from pybitnode.p2p.manager import PeerManager
from pybitnode.sync.sync_datadir_lock import ExclusiveDataDirSyncLock


def _seed_headers_after_genesis(tracker: ProjectTracker) -> None:
    """Minimal header chain rooted at testnet4 genesis."""
    tracker.record_header(1, "hash1", TESTNET4.genesis_hash, 601)
    tracker.record_header(2, "hash2", "hash1", 602)


def _patch_peer_manager_no_network(monkeypatch: pytest.MonkeyPatch, *, track_header_sync: list[int]) -> None:
    async def bootstrap(self: PeerManager, manual_peers: list[tuple[str, int]], *, start_height: int = 0) -> None:
        self._manual_sync_peers = set(manual_peers)
        fake = Mock()
        fake.is_connected = True
        fake.remote_version = Mock(start_height=500_000)
        fake.host = "127.0.0.1"
        fake.port = 48333
        fake.close = AsyncMock()
        self.connections.append(fake)

    async def sync_headers(self: PeerManager, **kwargs):  # type: ignore[no-untyped-def]
        track_header_sync.append(1)
        return 0

    async def sync_blocks_stub(self: PeerManager, block_store):  # type: ignore[no-untyped-def]
        return 0

    monkeypatch.setattr(PeerManager, "bootstrap", bootstrap)
    monkeypatch.setattr(PeerManager, "sync_headers", sync_headers)
    monkeypatch.setattr(PeerManager, "sync_blocks", sync_blocks_stub)


@pytest.fixture
def isolated_sync_env(monkeypatch: pytest.MonkeyPatch, tmp_path):
    monkeypatch.delenv("DATA_DIR", raising=False)
    monkeypatch.delenv("DB_PATH", raising=False)
    monkeypatch.delenv("PEERS", raising=False)


@pytest.mark.asyncio
async def test_sync_blocks_skips_networked_headers_with_no_header_refresh(
    monkeypatch: pytest.MonkeyPatch, isolated_sync_env, tmp_path
) -> None:
    from pybitnode.sync_runner import sync_blocks

    sync_header_calls: list[int] = []
    _patch_peer_manager_no_network(monkeypatch, track_header_sync=sync_header_calls)

    datadir = tmp_path / "node"
    db_path = datadir / "chainstate-rocksdb"
    datadir.mkdir(parents=True)

    tracker = ProjectTracker(db_path)
    from pybitnode.sync.headers import ensure_genesis, repair_sync_state

    ensure_genesis(tracker, TESTNET4)
    _seed_headers_after_genesis(tracker)
    repair_sync_state(tracker, TESTNET4)
    tracker.close()

    settings = Settings(
        chain="testnet4",
        data_dir=str(datadir),
        peers="127.0.0.1:48333",
        no_header_refresh=True,
        skip_getaddr=True,
    )
    assert await sync_blocks(settings) == 0
    assert sync_header_calls == []


def test_sync_runner_main_no_header_refresh_cli_skips_headers(
    monkeypatch: pytest.MonkeyPatch, isolated_sync_env, tmp_path
) -> None:
    from pybitnode import sync_runner

    sync_header_calls: list[int] = []
    _patch_peer_manager_no_network(monkeypatch, track_header_sync=sync_header_calls)

    datadir = tmp_path / "node"
    db_path = datadir / "chainstate-rocksdb"
    datadir.mkdir(parents=True)

    tracker = ProjectTracker(db_path)
    from pybitnode.sync.headers import ensure_genesis, repair_sync_state

    ensure_genesis(tracker, TESTNET4)
    _seed_headers_after_genesis(tracker)
    repair_sync_state(tracker, TESTNET4)
    tracker.close()

    argv = [
        "--datadir",
        str(datadir),
        "--peers",
        "127.0.0.1:48333",
        "--no-header-refresh",
        "--log-level",
        "critical",
    ]
    try:
        sync_runner.main(argv)
    except SystemExit as exc:
        assert exc.code == 0
    assert sync_header_calls == []


def test_sync_runner_main_exits_when_datadir_lock_held(monkeypatch: pytest.MonkeyPatch, isolated_sync_env, tmp_path):
    from pybitnode import sync_runner

    monkeypatch.delenv("NO_HEADER_REFRESH", raising=False)

    datadir = tmp_path / "locked"
    datadir.mkdir()
    argv = ["--datadir", str(datadir), "--log-level", "critical"]

    with ExclusiveDataDirSyncLock(datadir):
        with pytest.raises(SystemExit) as exc:
            sync_runner.main(argv)
        assert exc.value.code == 2
