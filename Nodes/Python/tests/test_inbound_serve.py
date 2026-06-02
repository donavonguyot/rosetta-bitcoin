from __future__ import annotations

import asyncio
from unittest.mock import AsyncMock, MagicMock

import pytest

from pybitnode.chain.params import TESTNET4
from pybitnode.config import Settings
from pybitnode.consensus.witness import transaction_wtxid
from pybitnode.chainstate.tracker import ProjectTracker
from pybitnode.mempool import Mempool
from pybitnode.messages.block import BlockMessage, GetDataMessage, NotFoundMessage
from pybitnode.messages.compact_block import serialize_block_wire
from pybitnode.messages.headers import BlockHeader, HeadersMessage
from pybitnode.messages.inventory import GetHeadersMessage, InventoryVector
from pybitnode.messages.transaction import OutPoint, Transaction, TxIn, TxOut
from pybitnode.p2p.ban_policy import BAN_HANDSHAKE_FAIL
from pybitnode.p2p.peer import PeerConnection
from pybitnode.p2p.server import (
    dispatch_inbound_message,
    handle_inbound_getdata,
    serve_inbound_session,
)
from pybitnode.storage.blocks import BlockStore
from pybitnode.sync.headers import ensure_genesis


def _height1_block_wire(genesis_hdr: BlockHeader) -> tuple[bytes, BlockHeader]:
    h1 = BlockHeader(
        version=genesis_hdr.version,
        prev_block=genesis_hdr.block_hash(),
        merkle_root=b"\x12" * 32,
        timestamp=genesis_hdr.timestamp + 600,
        bits=genesis_hdr.bits,
        nonce=genesis_hdr.nonce + 1,
    )
    return serialize_block_wire(h1, ()), h1


def _peer_conn(tracker: ProjectTracker, **kwargs: object) -> PeerConnection:
    return PeerConnection(
        host="127.0.0.1",
        port=49200,
        chain=TESTNET4,
        tracker=tracker,
        protocol_version=70016,
        user_agent="/pybitnode:test/",
        **kwargs,
    )


@pytest.mark.asyncio
async def test_inbound_getdata_msg_block_reads_block_store(tmp_path):
    tracker = ProjectTracker(tmp_path / "gd_blk-chainstate")
    g = ensure_genesis(tracker, TESTNET4)
    payload, h1 = _height1_block_wire(g)

    local = BlockStore(tmp_path / "blocks", TESTNET4.magic)
    file_name, offset, size = local.write(payload)
    tracker.record_header(
        1,
        h1.block_hash_hex(),
        g.block_hash_hex(),
        h1.timestamp,
        header_serialized_hex=h1.serialize().hex(),
    )
    tracker.record_block(1, h1.block_hash_hex(), file_name, offset, size)

    peer = _peer_conn(tracker)
    peer.send = AsyncMock()

    gd = GetDataMessage(
        inventory=[
            InventoryVector(type=InventoryVector.MSG_BLOCK, hash=h1.block_hash()),
        ],
    )
    await handle_inbound_getdata(peer, tracker, local, gd.serialize(), mempool=None)

    peer.send.assert_awaited()
    assert any(c.args and c.args[0] == BlockMessage.COMMAND for c in peer.send.await_args_list)
    _, blob = next(c.args for c in peer.send.await_args_list if c.args[0] == BlockMessage.COMMAND)
    assert blob == payload
    nf_calls = [c.args for c in peer.send.await_args_list if c.args[0] == NotFoundMessage.COMMAND]
    assert nf_calls == []
    tracker.close()


@pytest.mark.asyncio
async def test_inbound_getdata_empty_inventory_no_peer_send(tmp_path):
    tracker = ProjectTracker(tmp_path / "gd_empty-chainstate")
    peer = _peer_conn(tracker)
    peer.send = AsyncMock()
    local = BlockStore(tmp_path / "eblk", TESTNET4.magic)
    await handle_inbound_getdata(peer, tracker, local, GetDataMessage(inventory=[]).serialize(), mempool=None)
    peer.send.assert_not_awaited()
    tracker.close()


@pytest.mark.asyncio
async def test_inbound_getdata_block_missing_from_index_notfound_only(tmp_path):
    tracker = ProjectTracker(tmp_path / "gd_nf-chainstate")
    peer = _peer_conn(tracker)
    peer.send = AsyncMock()
    local = BlockStore(tmp_path / "empty_blocks", TESTNET4.magic)
    want = InventoryVector(type=InventoryVector.MSG_WITNESS_BLOCK, hash=b"\xaa" * 32)
    await handle_inbound_getdata(peer, tracker, local, GetDataMessage(inventory=[want]).serialize(), mempool=None)

    peer.send.assert_awaited_once_with(NotFoundMessage.COMMAND, NotFoundMessage(inventory=[want]).serialize())
    tracker.close()


@pytest.mark.asyncio
async def test_inbound_getdata_row_present_read_raises_oserror_notfound(tmp_path, monkeypatch):
    tracker = ProjectTracker(tmp_path / "gd_ose-chainstate")
    g = ensure_genesis(tracker, TESTNET4)
    payload, h1 = _height1_block_wire(g)

    local = BlockStore(tmp_path / "blo", TESTNET4.magic)
    file_name, offset, size = local.write(payload)
    tracker.record_header(
        1,
        h1.block_hash_hex(),
        g.block_hash_hex(),
        h1.timestamp,
        header_serialized_hex=h1.serialize().hex(),
    )
    tracker.record_block(1, h1.block_hash_hex(), file_name, offset, size)

    peer = _peer_conn(tracker)
    peer.send = AsyncMock()

    def boom(*_a: object, **_k: object) -> bytes:
        raise OSError(999, "bad read")

    monkeypatch.setattr(BlockStore, "read", boom)

    iv = InventoryVector(type=InventoryVector.MSG_BLOCK, hash=h1.block_hash())
    await handle_inbound_getdata(peer, tracker, local, GetDataMessage(inventory=[iv]).serialize(), mempool=None)
    peer.send.assert_awaited_once_with(NotFoundMessage.COMMAND, NotFoundMessage(inventory=[iv]).serialize())
    tracker.close()


@pytest.mark.asyncio
async def test_inbound_getdata_block_hash_mismatch_notfound(tmp_path):
    tracker = ProjectTracker(tmp_path / "gd_mis-chainstate")
    g = ensure_genesis(tracker, TESTNET4)
    payload, h1 = _height1_block_wire(g)

    local = BlockStore(tmp_path / "blo2", TESTNET4.magic)
    file_name, offset, size = local.write(payload)
    tracker.record_header(
        1,
        h1.block_hash_hex(),
        g.block_hash_hex(),
        h1.timestamp,
        header_serialized_hex=h1.serialize().hex(),
    )
    tracker.record_block(1, h1.block_hash_hex(), file_name, offset, size)

    peer = _peer_conn(tracker)
    peer.send = AsyncMock()
    wrong_hash = b"\xfe" * 32
    iv = InventoryVector(type=InventoryVector.MSG_WITNESS_BLOCK, hash=wrong_hash)
    await handle_inbound_getdata(peer, tracker, local, GetDataMessage(inventory=[iv]).serialize(), mempool=None)
    peer.send.assert_awaited_once_with(NotFoundMessage.COMMAND, NotFoundMessage(inventory=[iv]).serialize())
    tracker.close()


@pytest.mark.asyncio
async def test_inbound_getdata_serves_first_block_then_notfound_second(tmp_path):
    tracker = ProjectTracker(tmp_path / "gd_mix-chainstate")
    g = ensure_genesis(tracker, TESTNET4)
    payload, h1 = _height1_block_wire(g)

    local = BlockStore(tmp_path / "blo3", TESTNET4.magic)
    file_name, offset, size = local.write(payload)
    tracker.record_header(
        1,
        h1.block_hash_hex(),
        g.block_hash_hex(),
        h1.timestamp,
        header_serialized_hex=h1.serialize().hex(),
    )
    tracker.record_block(1, h1.block_hash_hex(), file_name, offset, size)

    peer = _peer_conn(tracker)
    peer.send = AsyncMock()

    missing = InventoryVector(type=InventoryVector.MSG_BLOCK, hash=b"\xbb" * 32)
    good = InventoryVector(type=InventoryVector.MSG_BLOCK, hash=h1.block_hash())
    await handle_inbound_getdata(
        peer,
        tracker,
        local,
        GetDataMessage(inventory=[missing, good]).serialize(),
        mempool=None,
    )

    cmds = [(c.args[0], c.args[1] if len(c.args) > 1 else None) for c in peer.send.await_args_list]
    assert cmds[0] == (BlockMessage.COMMAND, payload)
    expected_nf = NotFoundMessage(inventory=[missing]).serialize()
    assert cmds[1] == (NotFoundMessage.COMMAND, expected_nf)
    tracker.close()


@pytest.mark.asyncio
async def test_inbound_getdata_msg_tx_no_mempool_sends_notfound(tmp_path):
    tracker = ProjectTracker(tmp_path / "gd_ntx-chainstate")
    peer = _peer_conn(tracker)
    peer.send = AsyncMock()
    local = BlockStore(tmp_path / "nblo", TESTNET4.magic)
    want = InventoryVector(type=InventoryVector.MSG_TX, hash=b"\xaa" * 32)
    await handle_inbound_getdata(peer, tracker, local, GetDataMessage(inventory=[want]).serialize(), mempool=None)
    peer.send.assert_awaited_once_with(NotFoundMessage.COMMAND, NotFoundMessage(inventory=[want]).serialize())
    tracker.close()


@pytest.mark.asyncio
async def test_inbound_getdata_forwards_non_tx_non_block_via_dispatch(tmp_path, monkeypatch):
    tracker = ProjectTracker(tmp_path / "gd_fwd-chainstate")
    peer = _peer_conn(tracker)
    peer.send = AsyncMock()
    disp = AsyncMock()
    monkeypatch.setattr(peer, "_dispatch", disp)

    odd = InventoryVector(type=4242, hash=b"\xcc" * 32)
    await handle_inbound_getdata(
        peer,
        tracker,
        BlockStore(tmp_path / "fwd", TESTNET4.magic),
        GetDataMessage(inventory=[odd]).serialize(),
        mempool=None,
    )

    disp.assert_awaited_once_with(GetDataMessage.COMMAND, GetDataMessage(inventory=[odd]).serialize())
    peer.send.assert_not_awaited()
    tracker.close()


@pytest.mark.asyncio
async def test_inbound_getdata_witness_tx_serializes_with_witness(tmp_path):
    tracker = ProjectTracker(tmp_path / "gd_wtx-chainstate")
    pool = Mempool()
    tx = Transaction(
        version=2,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=b"\xde" * 32, index=2),
                script_sig=b"",
                sequence=0xFFFFFFFF,
            ),
        ),
        outputs=(TxOut(value=4321, script_pubkey=b"\x51"),),
        lock_time=0,
        witness=((b"\xca\xfe",),),
    )
    assert pool.add(tx) is True
    wtid = transaction_wtxid(tx)

    peer = _peer_conn(tracker, mempool=pool)
    peer.send = AsyncMock()
    local = BlockStore(tmp_path / "no_blocks_wtx", TESTNET4.magic)
    want = InventoryVector(type=InventoryVector.MSG_WITNESS_TX, hash=wtid)
    await handle_inbound_getdata(peer, tracker, local, GetDataMessage(inventory=[want]).serialize(), mempool=pool)

    tx_calls = [c.args for c in peer.send.await_args_list if c.args[0] == "tx"]
    assert len(tx_calls) == 1
    _, wire = tx_calls[0]
    got, n = Transaction.deserialize(wire)
    assert n == len(wire)
    assert got.witness == ((b"\xca\xfe",),)
    tracker.close()


@pytest.mark.asyncio
async def test_dispatch_inbound_getheaders_sends_compact_headers_wire(tmp_path):
    tracker = ProjectTracker(tmp_path / "dhdr-chainstate")
    g = ensure_genesis(tracker, TESTNET4)
    bh1 = BlockHeader(
        version=g.version,
        prev_block=g.block_hash(),
        merkle_root=b"\x77" * 32,
        timestamp=g.timestamp + 600,
        bits=g.bits,
        nonce=g.nonce + 2,
    )
    tracker.record_header(
        1,
        bh1.block_hash_hex(),
        g.block_hash_hex(),
        bh1.timestamp,
        header_serialized_hex=bh1.serialize().hex(),
    )

    peer = _peer_conn(tracker)
    peer.send = AsyncMock()
    gh = GetHeadersMessage(
        version=70016,
        locator_hashes=[g.block_hash()],
        hash_stop=b"\x00" * 32,
    )
    settings = Settings()
    local = BlockStore(tmp_path / "dsbl", TESTNET4.magic)
    await dispatch_inbound_message(
        peer,
        tracker=tracker,
        chain=TESTNET4,
        settings=settings,
        block_store=local,
        mempool=None,
        command="getheaders",
        payload=gh.serialize(),
    )

    peer.send.assert_awaited_once()
    cmd, wire = peer.send.await_args.args[0], peer.send.await_args.args[1]
    assert cmd == HeadersMessage.COMMAND
    hm = HeadersMessage.deserialize(wire)
    assert len(hm.headers) == 1
    assert hm.headers[0].block_hash() == bh1.block_hash()

    caps = list([tracker.get_wire_capability("serve.getheaders")])
    assert caps and caps[0]["implemented"]
    tracker.close()


@pytest.mark.asyncio
async def test_serve_inbound_session_dispatches_mocked_getheaders(monkeypatch, tmp_path):
    tracker = ProjectTracker(tmp_path / "sess_ok-chainstate")
    g = ensure_genesis(tracker, TESTNET4)
    bh1 = BlockHeader(
        version=g.version,
        prev_block=g.block_hash(),
        merkle_root=b"\x99" * 32,
        timestamp=g.timestamp + 601,
        bits=g.bits,
        nonce=g.nonce + 3,
    )
    tracker.record_header(
        1,
        bh1.block_hash_hex(),
        g.block_hash_hex(),
        bh1.timestamp,
        header_serialized_hex=bh1.serialize().hex(),
    )

    mock_send = AsyncMock()

    async def stub_accept(_self: PeerConnection) -> None:
        return

    async def stub_consume(_self: PeerConnection, on_message) -> None:
        gh = GetHeadersMessage(
            version=70016,
            locator_hashes=[g.block_hash()],
            hash_stop=b"\x00" * 32,
        )
        await on_message("getheaders", gh.serialize())

    monkeypatch.setattr(PeerConnection, "accept_inbound", stub_accept)
    monkeypatch.setattr(PeerConnection, "consume_messages", stub_consume)
    monkeypatch.setattr(PeerConnection, "send", mock_send)

    mock_reader = MagicMock()
    mock_writer = MagicMock()
    mock_writer.get_extra_info.side_effect = lambda k: ("192.168.1.88", 50012) if k == "peername" else None
    mock_writer.is_closing.return_value = True

    await serve_inbound_session(
        mock_reader,
        mock_writer,
        chain=TESTNET4,
        tracker=tracker,
        settings=Settings(),
        block_store=BlockStore(tmp_path / "sbin", TESTNET4.magic),
        mempool=None,
    )

    mock_send.assert_awaited_once()
    args = mock_send.await_args.args
    assert args[0] == HeadersMessage.COMMAND
    decoded = HeadersMessage.deserialize(args[1])
    assert len(decoded.headers) == 1
    assert decoded.headers[0].block_hash() == bh1.block_hash()
    tracker.close()


@pytest.mark.asyncio
async def test_serve_inbound_session_handshake_fail_bans_known_endpoint(monkeypatch, tmp_path):
    tracker = ProjectTracker(tmp_path / "sess_ban-chainstate")
    spy_inc = MagicMock(wraps=tracker.increment_peer_ban_score)
    monkeypatch.setattr(tracker, "increment_peer_ban_score", spy_inc)

    async def boom(_self: PeerConnection) -> None:
        raise asyncio.IncompleteReadError(expected=8, partial=b"\x01")

    monkeypatch.setattr(PeerConnection, "accept_inbound", boom)

    mock_reader = MagicMock()
    mock_writer = MagicMock()
    mock_writer.get_extra_info.side_effect = lambda k: ("10.9.9.9", 8333) if k == "peername" else None
    mock_writer.is_closing.return_value = False
    mock_writer.close = MagicMock()
    mock_writer.wait_closed = AsyncMock()

    await serve_inbound_session(
        mock_reader,
        mock_writer,
        chain=TESTNET4,
        tracker=tracker,
        settings=Settings(),
        block_store=BlockStore(tmp_path / "sbin2", TESTNET4.magic),
        mempool=None,
    )

    spy_inc.assert_called_once()
    host, port, delta = spy_inc.call_args.args[0], spy_inc.call_args.args[1], spy_inc.call_args.args[2]
    assert (host, port, delta) == ("10.9.9.9", 8333, BAN_HANDSHAKE_FAIL)
    mock_writer.close.assert_called_once()
    tracker.close()


@pytest.mark.asyncio
async def test_serve_inbound_session_handshake_fail_unknown_peer_no_ban(monkeypatch, tmp_path):
    tracker = ProjectTracker(tmp_path / "sess_nob-chainstate")
    spy_inc = MagicMock(wraps=tracker.increment_peer_ban_score)
    monkeypatch.setattr(tracker, "increment_peer_ban_score", spy_inc)

    async def boom(_self: PeerConnection) -> None:
        raise TimeoutError()

    monkeypatch.setattr(PeerConnection, "accept_inbound", boom)

    mock_reader = MagicMock()
    mock_writer = MagicMock()
    mock_writer.get_extra_info.return_value = None
    mock_writer.is_closing.return_value = False
    mock_writer.close = MagicMock()
    mock_writer.wait_closed = AsyncMock()

    await serve_inbound_session(
        mock_reader,
        mock_writer,
        chain=TESTNET4,
        tracker=tracker,
        settings=Settings(),
        block_store=BlockStore(tmp_path / "sbin3", TESTNET4.magic),
        mempool=None,
    )

    spy_inc.assert_not_called()
    tracker.close()
