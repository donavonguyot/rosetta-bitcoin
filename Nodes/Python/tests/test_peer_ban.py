"""Peer ban score / bootstrap filtering (Phase 5 lite)."""

from __future__ import annotations

from unittest.mock import AsyncMock, patch

import pybitnode.p2p.peer as peer_mod

import pytest

from pybitnode.chain.params import TESTNET4
from pybitnode.config import Settings
from pybitnode.db.tracker import ProjectTracker
from pybitnode.p2p.ban_policy import BAN_DISCONNECT, BAN_PROTOCOL_VIOLATION
from pybitnode.p2p.discovery import bootstrap_peer_targets
from pybitnode.p2p.peer import PeerConnection


@pytest.mark.asyncio
async def test_bootstrap_peer_targets_respects_ban_threshold(tmp_path):
    tracker = ProjectTracker(tmp_path / "bootstrap_ban.db")
    host = "203.0.113.50"
    port = TESTNET4.default_port
    tracker.record_peer_address(host, port, services=1, source="test")

    settings = Settings()
    settings.peer_ban_score_threshold = 100

    async def fake_seeds(chain, count):
        return []

    with patch("pybitnode.p2p.discovery.resolve_seed_peers", new_callable=AsyncMock, side_effect=fake_seeds):
        tracker.increment_peer_ban_score(host, port, 50)
        low = await bootstrap_peer_targets(TESTNET4, tracker, settings, [])
        assert (host, port) in low

        tracker.increment_peer_ban_score(host, port, 55)
        assert tracker.get_peer_endpoint_ban_score(host, port) == 105

        high = await bootstrap_peer_targets(TESTNET4, tracker, settings, [])
        assert (host, port) not in high

    tracker.close()


@pytest.mark.asyncio
async def test_consume_messages_ban_disconnect(tmp_path):
    tracker = ProjectTracker(tmp_path / "consume.db")
    peer = PeerConnection(
        host="203.0.113.71",
        port=48333,
        chain=TESTNET4,
        tracker=tracker,
        protocol_version=70016,
        user_agent="/x/",
    )
    peer.peer_id = 1
    peer.reader = AsyncMock()
    peer.reader.read = AsyncMock(return_value=b"")

    await peer.consume_messages(peer._dispatch)
    assert tracker.get_peer_endpoint_ban_score("203.0.113.71", 48333) == BAN_DISCONNECT

    tracker.close()


@pytest.mark.asyncio
async def test_consume_messages_ban_protocol_violation(tmp_path):
    tracker = ProjectTracker(tmp_path / "consume2.db")
    peer = PeerConnection(
        host="203.0.113.72",
        port=48333,
        chain=TESTNET4,
        tracker=tracker,
        protocol_version=70016,
        user_agent="/y/",
    )
    peer.peer_id = 2

    peer.read_message = AsyncMock(side_effect=ValueError("bad frame"))

    await peer.consume_messages(peer._dispatch)
    assert tracker.get_peer_endpoint_ban_score("203.0.113.72", 48333) == BAN_PROTOCOL_VIOLATION

    tracker.close()


def test_increment_peer_ban_updates_aggregate_and_peer_row(tmp_path):
    tracker = ProjectTracker(tmp_path / "agg.db")
    pid = tracker.record_peer_connected("203.0.113.81", 48333)
    delta = 12
    tracker.increment_peer_ban_score("203.0.113.81", 48333, delta, peer_id=pid)
    prow = list(tracker.db["peers"].rows_where("id = ?", [pid], limit=1))[0]

    assert tracker.get_peer_endpoint_ban_score("203.0.113.81", 48333) == delta
    assert int(prow["ban_score"]) == delta

    tracker.close()


def test_decay_reduces_aggregate(tmp_path):
    tracker = ProjectTracker(tmp_path / "decay.db")
    tracker.increment_peer_ban_score("203.0.113.91", 48333, 40)
    tracker.decay_peer_ban_score("203.0.113.91", 48333, 15)
    assert tracker.get_peer_endpoint_ban_score("203.0.113.91", 48333) == 25

    tracker.close()


def test_decay_peer_ban_score_floors_at_zero(tmp_path):
    tracker = ProjectTracker(tmp_path / "floor.db")
    tracker.increment_peer_ban_score("203.0.113.92", 48333, 10)
    tracker.decay_peer_ban_score("203.0.113.92", 48333, 100)
    assert tracker.get_peer_endpoint_ban_score("203.0.113.92", 48333) == 0

    tracker.close()


def test_maybe_decay_requires_uptime_and_runs_once(tmp_path):
    """Long-uptime decay uses Settings and applies at most once per connection."""
    tracker = ProjectTracker(tmp_path / "uptime_decay.db")
    host, port = "203.0.113.93", TESTNET4.default_port
    tracker.increment_peer_ban_score(host, port, 100)

    peer = PeerConnection(
        host=host,
        port=port,
        chain=TESTNET4,
        tracker=tracker,
        protocol_version=70016,
        user_agent="/z/",
        settings=Settings(
            peer_ban_decay_uptime_seconds=50.0,
            peer_ban_decay_amount=30,
        ),
    )
    peer.peer_id = 1
    peer._connected_monotonic = 1000.0

    with patch.object(peer_mod.time, "monotonic", return_value=1049.9):
        peer._maybe_decay_ban_after_long_uptime()
    assert tracker.get_peer_endpoint_ban_score(host, port) == 100

    with patch.object(peer_mod.time, "monotonic", return_value=1050.0):
        peer._maybe_decay_ban_after_long_uptime()
    assert tracker.get_peer_endpoint_ban_score(host, port) == 70

    with patch.object(peer_mod.time, "monotonic", return_value=99999.0):
        peer._maybe_decay_ban_after_long_uptime()
    assert tracker.get_peer_endpoint_ban_score(host, port) == 70

    tracker.close()
