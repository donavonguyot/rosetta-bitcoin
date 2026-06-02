from __future__ import annotations

import asyncio
import time
from unittest.mock import AsyncMock, MagicMock

import pytest

from pybitnode.chain.params import TESTNET4
from pybitnode.config import Settings
from pybitnode.chainstate.tracker import ProjectTracker
from pybitnode.messages.address import AddrMessage, GetAddrMessage
from pybitnode.messages.handshake import NODE_NETWORK, NetworkAddress
from pybitnode.p2p.discovery import merge_peer_candidates
from pybitnode.messages.compact_block import serialize_block_wire
from pybitnode.messages.headers import BlockHeader
from pybitnode.messages.inventory import InventoryVector
from pybitnode.messages.transaction import OutPoint, Transaction, TxIn, TxOut
from pybitnode.p2p.peer import PeerConnection
from pybitnode.sync.blocks import request_block_from_peers


def test_getaddr_message_is_empty():
    assert GetAddrMessage().serialize() == b""


def test_addr_message_roundtrip():
    address = NetworkAddress(services=NODE_NETWORK, ip="203.0.113.10", port=48333)
    message = AddrMessage(addresses=(address,))
    payload = message.serialize()
    restored = AddrMessage.deserialize(payload)
    assert len(restored.addresses) == 1
    assert restored.addresses[0].ip == "203.0.113.10"
    assert restored.addresses[0].port == 48333


def test_record_peer_address_and_list(tmp_path):
    tracker = ProjectTracker(tmp_path / "peers-chainstate")
    tracker.record_peer_address("203.0.113.10", 48333, services=1, source="getaddr")
    tracker.record_peer_address("198.51.100.4", 48333, source="addr")
    endpoints = tracker.list_peer_address_endpoints(limit=10)
    assert ("203.0.113.10", 48333) in endpoints
    assert ("198.51.100.4", 48333) in endpoints
    tracker.close()


def test_merge_peer_candidates_prefers_manual_and_deduplicates():
    merged = merge_peer_candidates(
        TESTNET4,
        manual=[("203.0.113.1", 48333)],
        stored=[("203.0.113.1", 48333), ("203.0.113.2", 48333)],
        discovered=[("127.0.0.1", 48333)],
        seeds=[("203.0.113.3", 48333)],
    )
    assert merged == [
        ("203.0.113.1", 48333),
        ("203.0.113.2", 48333),
        ("203.0.113.3", 48333),
    ]


async def test_keepalive_sends_ping_and_disconnects_stale(tmp_path):
    tracker = ProjectTracker(tmp_path / "keepalive-chainstate")
    peer = PeerConnection(
        host="127.0.0.1",
        port=48333,
        chain=TESTNET4,
        tracker=tracker,
        protocol_version=70016,
        user_agent="/pybitnode:0.1.0/",
        ping_interval=1.0,
        stale_timeout=2.0,
    )
    peer.send = AsyncMock()
    peer._last_activity = time.monotonic() - 3.0
    peer._last_ping = time.monotonic() - 3.0

    with pytest.raises(ConnectionError, match="Peer stale"):
        await peer._keepalive_tick()
    peer.send.assert_not_called()

    peer._last_activity = time.monotonic()
    peer._last_ping = time.monotonic() - 2.0
    await peer._keepalive_tick()
    peer.send.assert_called_once()
    assert peer.send.call_args[0][0] == "ping"
    tracker.close()


async def test_request_block_from_peers_falls_back():
    block_hash = b"\x01" * 32
    first = AsyncMock(spec=PeerConnection)
    first.is_connected = True
    first.request_block = AsyncMock(return_value=None)
    second = AsyncMock(spec=PeerConnection)
    second.is_connected = True
    second.request_block = AsyncMock(return_value=b"block-bytes")

    result = await request_block_from_peers([first, second], block_hash)
    assert result == (b"block-bytes", second)
    first.request_block.assert_awaited_once_with(block_hash)
    second.request_block.assert_awaited_once_with(block_hash)


@pytest.mark.parametrize("settings", [Settings(no_header_refresh=True), Settings(sync_skip_headers=True)])
def test_lightweight_outbound_handshake_true_for_skip_flags(tmp_path, settings):
    tracker = ProjectTracker(tmp_path / "lw-chainstate")
    peer = PeerConnection(
        host="127.0.0.1",
        port=48333,
        chain=TESTNET4,
        tracker=tracker,
        protocol_version=70016,
        user_agent="/pybitnode:test/",
        settings=settings,
    )
    assert peer._lightweight_outbound_handshake() is True
    tracker.close()


def test_lightweight_outbound_handshake_false_by_default(tmp_path):
    tracker = ProjectTracker(tmp_path / "lw2-chainstate")
    peer = PeerConnection(
        host="127.0.0.1",
        port=48333,
        chain=TESTNET4,
        tracker=tracker,
        protocol_version=70016,
        user_agent="/pybitnode:test/",
        settings=Settings(),
    )
    assert peer._lightweight_outbound_handshake() is False
    tracker.close()


@pytest.mark.asyncio
async def test_request_block_once_ignores_interleaved_getheaders(tmp_path):
    header = BlockHeader(
        version=536870912,
        prev_block=b"\x71" * 32,
        merkle_root=b"\x82" * 32,
        timestamp=1_700_000_000,
        bits=0x1D00FFFF,
        nonce=123,
    )
    coinbase = Transaction(
        version=2,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=b"\x00" * 32, index=0xFFFFFFFF),
                script_sig=b"\x02" * 5,
                sequence=0xFFFFFFFF,
            ),
        ),
        outputs=(TxOut(value=3_125_000_000, script_pubkey=b"\x51"),),
        lock_time=0,
    )
    block_payload = serialize_block_wire(header, (coinbase,))
    block_hash = header.block_hash()

    tracker = ProjectTracker(tmp_path / "blk-chainstate")
    peer = PeerConnection(
        host="127.0.0.1",
        port=48333,
        chain=TESTNET4,
        tracker=tracker,
        protocol_version=70016,
        user_agent="/pybitnode:test/",
        settings=Settings(),
    )
    peer._request_lock = asyncio.Lock()
    w = MagicMock()
    w.is_closing.return_value = False
    w.write = MagicMock()
    w.drain = AsyncMock()
    peer.writer = w

    messages = asyncio.Queue()
    await messages.put(("getheaders", b""))
    await messages.put(("block", block_payload))

    async def fake_read(timeout: float = 60.0):
        del timeout  # exercised by production code paths
        return await messages.get()

    peer.read_message = fake_read
    peer.send = AsyncMock()

    out = await peer._request_block_once(
        block_hash,
        InventoryVector.MSG_BLOCK,
        timeout=5.0,
    )
    assert out == block_payload
    tracker.close()


