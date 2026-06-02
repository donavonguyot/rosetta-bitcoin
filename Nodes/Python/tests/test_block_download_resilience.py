"""Offline mocks for stall / notfound / connection loss during block download."""

from __future__ import annotations

from unittest.mock import AsyncMock

import pytest

from pybitnode.chain.params import TESTNET4
from pybitnode.db.tracker import ProjectTracker
from pybitnode.p2p.ban_policy import BAN_DISCONNECT
from pybitnode.p2p.peer import PeerConnection
from pybitnode.storage.blocks import BlockStore
from pybitnode.sync.blocks import request_block_from_peers, sync_blocks_batch
from pybitnode.sync.headers import ensure_genesis


@pytest.mark.asyncio
async def test_request_block_from_peers_returns_none_when_peers_miss_notfound():
    """Peers replying ``notfound`` yield ``None`` payloads; aggregator returns None."""
    h = b"\xde" * 32
    a = AsyncMock(spec=PeerConnection)
    a.is_connected = True
    a.request_block = AsyncMock(return_value=None)
    b = AsyncMock(spec=PeerConnection)
    b.is_connected = True
    b.request_block = AsyncMock(return_value=None)

    assert await request_block_from_peers([a, b], h) is None
    a.request_block.assert_awaited_once_with(h)
    b.request_block.assert_awaited_once_with(h)


@pytest.mark.asyncio
async def test_request_block_from_peers_tries_next_peer_after_notfound():
    first_miss = AsyncMock(spec=PeerConnection)
    first_miss.is_connected = True
    first_miss.request_block = AsyncMock(return_value=None)
    second_ok = AsyncMock(spec=PeerConnection)
    second_ok.is_connected = True
    second_ok.request_block = AsyncMock(return_value=b"block-payload")

    h = b"\xfa" * 32
    out = await request_block_from_peers([first_miss, second_ok], h)
    assert out == (b"block-payload", second_ok)
    first_miss.request_block.assert_awaited_once_with(h)
    second_ok.request_block.assert_awaited_once_with(h)


@pytest.mark.asyncio
async def test_request_block_from_peers_retries_after_connection_error_from_read_path():
    bad = AsyncMock(spec=PeerConnection)
    bad.is_connected = True
    bad.request_block = AsyncMock(side_effect=ConnectionError("peer reset"))
    ok = AsyncMock(spec=PeerConnection)
    ok.is_connected = True
    ok.request_block = AsyncMock(return_value=b"recovered")

    h = b"\xbb" * 32
    out = await request_block_from_peers([bad, ok], h)
    assert out == (b"recovered", ok)
    bad.request_block.assert_awaited_once_with(h)
    ok.request_block.assert_awaited_once_with(h)


@pytest.mark.asyncio
async def test_sync_blocks_batch_stops_sequential_batch_on_unavailable_block(tmp_path, monkeypatch):
    monkeypatch.setattr(
        "pybitnode.sync.blocks.broadcast_witness_block_inv",
        AsyncMock(),
    )
    monkeypatch.setattr(
        "pybitnode.sync.blocks.connect_block",
        AsyncMock(),
    )

    hashes_queried: list[bytes] = []

    async def fake_request(peers: list, block_hash: bytes) -> None:  # noqa: ARG001
        hashes_queried.append(block_hash)
        return None

    monkeypatch.setattr(
        "pybitnode.sync.blocks.request_block_from_peers",
        fake_request,
    )

    tracker = ProjectTracker(tmp_path / "stall.db")
    ensure_genesis(tracker, TESTNET4)
    prev_hex = TESTNET4.genesis_hash
    for height in (1, 2):
        block_hash_hex = f"{height:064x}"
        tracker.record_header(height, block_hash_hex, prev_hex, 100 + height)
        prev_hex = block_hash_hex

    store = BlockStore(tmp_path / "blocks", TESTNET4.magic)
    n = await sync_blocks_batch(
        [AsyncMock(spec=PeerConnection, is_connected=True)],
        tracker,
        TESTNET4,
        store,
        batch_size=8,
        max_blocks=0,
        parallel_downloads=0,
    )
    assert n == 0
    assert len(hashes_queried) == 1
    assert tracker.list_missing_block_heights(limit=10) == [1, 2]
    tracker.close()


@pytest.mark.asyncio
async def test_read_message_raises_connection_error_on_peer_close(tmp_path):
    tracker = ProjectTracker(tmp_path / "reader.db")
    peer = PeerConnection(
        host="203.0.113.61",
        port=48333,
        chain=TESTNET4,
        tracker=tracker,
        protocol_version=70016,
        user_agent="/pybitnode:test/",
    )
    peer.reader = AsyncMock()
    peer.reader.read = AsyncMock(return_value=b"")

    with pytest.raises(ConnectionError, match="Peer closed connection"):
        await peer.read_message(timeout=2.0)
    tracker.close()


@pytest.mark.asyncio
async def test_consume_messages_handles_connection_error_from_read_message(tmp_path):
    tracker = ProjectTracker(tmp_path / "consume_read.db")
    peer = PeerConnection(
        host="203.0.113.62",
        port=48333,
        chain=TESTNET4,
        tracker=tracker,
        protocol_version=70016,
        user_agent="/pybitnode:test/",
    )
    peer.peer_id = 42
    peer.reader = AsyncMock()
    peer.reader.read = AsyncMock(return_value=b"")

    await peer.consume_messages(peer._dispatch)
    assert tracker.get_peer_endpoint_ban_score("203.0.113.62", 48333) == BAN_DISCONNECT
    tracker.close()
