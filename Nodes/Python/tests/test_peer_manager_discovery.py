from __future__ import annotations

from unittest.mock import AsyncMock

import pytest

from pybitnode.chain.params import TESTNET4
from pybitnode.config import Settings
from pybitnode.chainstate.tracker import ProjectTracker
from pybitnode.p2p.manager import PeerManager


@pytest.mark.asyncio
async def test_connect_peers_keeps_peer_when_discover_raises(tmp_path, monkeypatch):
    tracker = ProjectTracker(tmp_path / "discovery-chainstate")

    calls = []

    class FakePeer:
        def __init__(self, **kwargs) -> None:
            self.host = kwargs["host"]
            self.port = kwargs["port"]

        async def connect(self) -> None:
            calls.append("connect")

        async def discover_peers(self) -> None:
            calls.append("discover")
            raise ConnectionError("peer closed during getaddr")

    monkeypatch.setattr("pybitnode.p2p.manager.PeerConnection", FakePeer)

    mgr = PeerManager(TESTNET4, tracker, Settings(max_outbound_peers=3))
    await mgr.connect_peers([("203.0.113.1", 48333)], discover_peer_addresses=True)

    assert len(mgr.connections) == 1
    assert calls == ["connect", "discover"]
    tracker.close()


@pytest.mark.asyncio
async def test_bootstrap_runs_discover_even_with_manual_peer(tmp_path, monkeypatch):
    tracker = ProjectTracker(tmp_path / "manual-chainstate")
    monkeypatch.setattr(
        "pybitnode.p2p.manager.bootstrap_peer_targets",
        AsyncMock(return_value=[("203.0.113.2", 48333)]),
    )

    discover_calls = 0

    class FakePeer:
        def __init__(self, **kwargs) -> None:
            self.host = kwargs["host"]
            self.port = kwargs["port"]

        async def connect(self) -> None:
            return None

        async def discover_peers(self) -> None:
            nonlocal discover_calls
            discover_calls += 1

    monkeypatch.setattr("pybitnode.p2p.manager.PeerConnection", FakePeer)

    mgr = PeerManager(TESTNET4, tracker, Settings(skip_getaddr=False))
    await mgr.bootstrap([("203.0.113.99", 48333)])

    assert discover_calls == 1
    assert len(mgr.connections) == 1
    tracker.close()


@pytest.mark.asyncio
async def test_bootstrap_skips_discover_when_skip_getaddr(tmp_path, monkeypatch):
    tracker = ProjectTracker(tmp_path / "manual-chainstate")
    monkeypatch.setattr(
        "pybitnode.p2p.manager.bootstrap_peer_targets",
        AsyncMock(return_value=[("203.0.113.2", 48333)]),
    )

    discover_calls = 0

    class FakePeer:
        def __init__(self, **kwargs) -> None:
            self.host = kwargs["host"]
            self.port = kwargs["port"]

        async def connect(self) -> None:
            return None

        async def discover_peers(self) -> None:
            nonlocal discover_calls
            discover_calls += 1

    monkeypatch.setattr("pybitnode.p2p.manager.PeerConnection", FakePeer)

    mgr = PeerManager(TESTNET4, tracker, Settings(max_outbound_peers=3, skip_getaddr=True))
    await mgr.bootstrap([("203.0.113.99", 48333)])

    assert discover_calls == 0
    assert len(mgr.connections) == 1
    tracker.close()


@pytest.mark.asyncio
async def test_bootstrap_manual_peers_only_skips_bootstrap_peer_targets(tmp_path, monkeypatch):
    """With `--peers` / explicit manual list, targets come only from that list (no DNS/DB merge)."""
    tracker = ProjectTracker(tmp_path / "manual_only-chainstate")
    monkeypatch.setattr(
        "pybitnode.p2p.manager.bootstrap_peer_targets",
        AsyncMock(side_effect=AssertionError("bootstrap_peer_targets must not run with manual_peers")),
    )

    recorded: list[tuple[list[tuple[str, int]], bool]] = []

    async def fake_connect_peers(
        self,
        targets,
        *,
        start_height=0,
        discover_peer_addresses=True,
    ):
        recorded.append((list(targets), discover_peer_addresses))
        host, port = targets[0]
        peer = type("P", (), {"host": host, "port": port, "is_connected": True})()
        self.connections = [peer]

    monkeypatch.setattr(PeerManager, "connect_peers", fake_connect_peers)

    manual = [("203.0.113.99", 48333)]
    mgr = PeerManager(TESTNET4, tracker, Settings(skip_getaddr=False))
    await mgr.bootstrap(manual)

    assert recorded == [(manual, True)]
    tracker.close()
