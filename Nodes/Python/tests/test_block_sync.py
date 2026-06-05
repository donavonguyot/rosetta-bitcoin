from __future__ import annotations

import asyncio

import pytest
from unittest.mock import AsyncMock

from pybitnode.messages.block import GetDataMessage, NotFoundMessage
from pybitnode.messages.inventory import InvMessage, InventoryVector
from pybitnode.storage.blocks import BlockStore


def test_getdata_message_roundtrip():
    inv = InventoryVector(type=InventoryVector.MSG_WITNESS_BLOCK, hash=b"\xab" * 32)
    msg = GetDataMessage(inventory=[inv])
    payload = msg.serialize()
    restored = GetDataMessage.deserialize(payload)
    assert len(restored.inventory) == 1
    assert restored.inventory[0].type == InventoryVector.MSG_WITNESS_BLOCK
    assert restored.inventory[0].hash == b"\xab" * 32


def test_notfound_message_roundtrip():
    inv = InventoryVector(type=InventoryVector.MSG_WITNESS_BLOCK, hash=b"\xcd" * 32)
    payload = GetDataMessage(inventory=[inv]).serialize()
    missing = NotFoundMessage.deserialize(payload)
    assert missing.inventory[0].hash == b"\xcd" * 32


def test_block_store_write_and_read(tmp_path):
    magic = bytes.fromhex("1c163f28")
    store = BlockStore(tmp_path / "blocks", magic)
    block_bytes = b"\x01" * 120
    file_name, offset, size = store.write(block_bytes)
    assert size == 120
    assert store.read(file_name, offset, size) == block_bytes


def test_list_missing_block_heights(tmp_path):
    from pybitnode.chain.params import TESTNET4
    from pybitnode.chainstate.tracker import ProjectTracker
    from pybitnode.sync.headers import ensure_genesis

    tracker = ProjectTracker(tmp_path / "blocks-chainstate")
    ensure_genesis(tracker, TESTNET4)
    tracker.record_header(1, "hash1", TESTNET4.genesis_hash, 100)
    tracker.record_header(2, "hash2", "hash1", 200)
    missing = tracker.list_missing_block_heights(limit=10)
    assert missing == [1, 2]
    tracker.record_block(1, "hash1", "blk00000.dat", 0, 100)
    missing = tracker.list_missing_block_heights(limit=10)
    assert missing == [2]
    tracker.close()


@pytest.mark.asyncio
async def test_request_block_from_peers_parallel_returns_first_success():
    from pybitnode.sync.blocks import request_block_from_peers_parallel

    target = b"\x11" * 32

    class _Peer:
        def __init__(self, seq: float, payload):
            self.is_connected = True
            self._seq = seq
            self._payload = payload

        async def request_block(self, block_hash: bytes):  # noqa: ARG002
            await asyncio.sleep(self._seq)
            return self._payload

    fast_ok = _Peer(0.0, b"winner")
    slow_ok = _Peer(0.2, b"loser")
    out = await request_block_from_peers_parallel([slow_ok, fast_ok], target)
    assert out is not None
    payload, winner = out
    assert payload == b"winner"
    assert winner is fast_ok


@pytest.mark.asyncio
async def test_request_block_from_peers_parallel_none_when_all_miss():
    from pybitnode.sync.blocks import request_block_from_peers_parallel

    class _Dead:
        is_connected = True

        async def request_block(self, block_hash):  # noqa: ARG002
            return None

    assert await request_block_from_peers_parallel([_Dead(), _Dead()], b"\xaa" * 32) is None


@pytest.mark.asyncio
async def test_sync_blocks_batch_parallel_marks_capability_and_bounded_gather(tmp_path, monkeypatch):
    from pybitnode.chain.params import TESTNET4
    from pybitnode.chainstate.tracker import ProjectTracker
    from pybitnode.storage.blocks import BlockStore
    from pybitnode.sync.blocks import sync_blocks_batch
    from pybitnode.sync.headers import ensure_genesis

    monkeypatch.setattr(
        "pybitnode.sync.blocks.broadcast_witness_block_inv",
        AsyncMock(),
    )

    connect_order: list[int] = []

    def fake_connect_block(
        tracker,
        payload,
        *,
        height,
        expected_prev,
        expected_hash,
        chain_name,
        script_verify_runner=None,
        update_metrics=True,
    ):  # noqa: ARG001
        connect_order.append(height)

    monkeypatch.setattr(
        "pybitnode.sync.blocks.connect_block",
        fake_connect_block,
    )

    in_flight = 0
    peak_in_flight = {"n": 0}
    gate = asyncio.Event()

    class _Peer:
        is_connected = True

        async def request_block(self, block_hash: bytes):  # noqa: ARG002
            nonlocal in_flight
            in_flight += 1
            peak_in_flight["n"] = max(peak_in_flight["n"], in_flight)
            await gate.wait()
            in_flight -= 1
            return b"\xbb" * 80

    # One peer so each in-flight block maps to a single request_block (peak == 3 for 3 heights).
    peers = [_Peer()]

    tracker = ProjectTracker(tmp_path / "par-chainstate")
    ensure_genesis(tracker, TESTNET4)
    prev_hex = TESTNET4.genesis_hash
    for height in range(1, 4):
        block_hash_hex = f"{height:064x}"
        tracker.record_header(height, block_hash_hex, prev_hex, 100 + height)
        prev_hex = block_hash_hex

    store = BlockStore(tmp_path / "blk", TESTNET4.magic)

    task = asyncio.create_task(
        sync_blocks_batch(
            peers,
            tracker,
            TESTNET4,
            store,
            batch_size=16,
            max_blocks=0,
            parallel_downloads=4,
        )
    )
    for _ in range(200):
        if peak_in_flight["n"] >= 3:
            break
        await asyncio.sleep(0.01)
    assert peak_in_flight["n"] >= 3
    gate.set()
    n = await asyncio.wait_for(task, timeout=5.0)
    assert n == 3
    assert connect_order == [1, 2, 3]
    assert tracker.wire_capability_map().get("blocks.parallel") == 1
    tracker.close()
