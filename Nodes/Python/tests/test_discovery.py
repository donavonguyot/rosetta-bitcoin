"""Offline tests for DNS / candidate merge helpers in pybitnode.p2p.discovery."""

from __future__ import annotations

import socket
from unittest.mock import AsyncMock, patch

import pytest

from pybitnode.chain.params import ChainParams, TESTNET4
from pybitnode.config import Settings
from pybitnode.chainstate.tracker import ProjectTracker
from pybitnode.p2p.discovery import bootstrap_peer_targets, merge_peer_candidates, resolve_seed_peers


@pytest.mark.asyncio
async def test_resolve_seed_peers_dedups_same_host(monkeypatch):
    """Multiple DNS seeds resolving to the same address appear once."""

    merged_infos = [
        (
            socket.AF_INET,
            socket.SOCK_STREAM,
            0,
            "",
            ("203.0.113.5", TESTNET4.default_port),
        ),
    ]

    async def fake_to_thread(fn, /, *args, **kwargs):
        assert fn is socket.getaddrinfo
        return list(merged_infos)

    monkeypatch.setattr(
        "pybitnode.p2p.discovery.asyncio.to_thread",
        AsyncMock(side_effect=fake_to_thread),
    )

    chain = ChainParams(
        name="x",
        magic=TESTNET4.magic,
        default_port=TESTNET4.default_port,
        genesis_hash="00" * 32,
        dns_seeds=("seed.a.example.invalid", "seed.b.example.invalid"),
    )
    peers = await resolve_seed_peers(chain, count=10)
    assert peers == [("203.0.113.5", TESTNET4.default_port)]
    assert len(peers) == 1


@pytest.mark.asyncio
async def test_resolve_seed_peers_rotates_dns_order(monkeypatch):
    """Seeds are shuffled each call so ordering is not fixed to dns_seeds tuple order."""

    call_order: list[str] = []

    async def fake_to_thread(fn, /, *args, **kwargs):
        assert fn is socket.getaddrinfo
        host = args[0]
        call_order.append(host)
        return [
            (
                socket.AF_INET,
                socket.SOCK_STREAM,
                0,
                "",
                (f"203.0.113.{len(call_order)}", TESTNET4.default_port),
            )
        ]

    monkeypatch.setattr(
        "pybitnode.p2p.discovery.asyncio.to_thread",
        AsyncMock(side_effect=fake_to_thread),
    )

    chain = ChainParams(
        name="y",
        magic=TESTNET4.magic,
        default_port=TESTNET4.default_port,
        genesis_hash="00" * 32,
        dns_seeds=("aaa.seed", "bbb.seed", "ccc.seed"),
    )

    monkeypatch.setattr("pybitnode.p2p.discovery.random.shuffle", lambda seq: seq.reverse())

    peers = await resolve_seed_peers(chain, count=10)
    assert call_order == ["ccc.seed", "bbb.seed", "aaa.seed"]
    assert len(peers) == 3


def test_merge_peer_candidates_skips_malformed_endpoints():
    chain = TESTNET4
    merged = merge_peer_candidates(
        chain,
        manual=[("203.0.113.55", chain.default_port), ("::ffff:8849", chain.default_port)],
        stored=[("203.0.113.56", chain.default_port)],
        discovered=[],
        seeds=[],
    )
    assert merged == [
        ("203.0.113.55", chain.default_port),
        ("203.0.113.56", chain.default_port),
    ]


def test_merge_peer_candidates_dedups_orderPreserves_priority():
    """Later groups do not duplicate earlier (manual first)."""
    chain = TESTNET4
    manual = [("203.0.113.10", chain.default_port)]
    stored = [("203.0.113.10", chain.default_port), ("203.0.113.11", chain.default_port)]
    merged = merge_peer_candidates(
        chain,
        manual=manual,
        stored=stored,
        discovered=[],
        seeds=[],
    )
    assert merged == [
        ("203.0.113.10", chain.default_port),
        ("203.0.113.11", chain.default_port),
    ]


@pytest.mark.asyncio
async def test_bootstrap_manual_peer_exempt_when_over_ban_threshold(tmp_path):
    """Manual peers remain candidates even when ban score exceeds threshold."""
    tracker = ProjectTracker(tmp_path / "manual_exempt-chainstate")
    host, port = "203.0.113.60", TESTNET4.default_port
    tracker.record_peer_address(host, port, services=1, source="test")
    tracker.increment_peer_ban_score(host, port, 200)

    settings = Settings()
    settings.peer_ban_score_threshold = 100

    with patch("pybitnode.p2p.discovery.resolve_seed_peers", new_callable=AsyncMock, return_value=[]):
        out = await bootstrap_peer_targets(TESTNET4, tracker, settings, [(host, port)])

    assert (host, port) in out
    tracker.close()
