from __future__ import annotations

from unittest.mock import AsyncMock

import pytest

from pybitnode.chain.params import TESTNET4
from pybitnode.config import Settings
from pybitnode.consensus.hash import hash160
from pybitnode.consensus.merkle import transaction_txid
from pybitnode.consensus.secp256k1 import _scalar_mult, Gx, Gy
from pybitnode.consensus.witness import transaction_wtxid
from pybitnode.chainstate.tracker import ProjectTracker
from pybitnode.mempool import Mempool, accept_transaction, transaction_meets_peer_feefilter
from pybitnode.mempool.mempool import estimate_tx_virtual_size_scaffold
from pybitnode.messages.block import GetDataMessage, NotFoundMessage
from pybitnode.messages.fee_filter import FeeFilterMessage
from pybitnode.messages.inventory import InvMessage, InventoryVector
from pybitnode.messages.transaction import OutPoint, Transaction, TxIn, TxOut
from pybitnode.p2p.manager import PeerManager
from pybitnode.p2p.peer import (
    PeerConnection,
    broadcast_witness_block_inv,
    reply_getdata_tx_inventory,
    tx_inventory_need_getdata,
)
from tests.script_helpers import make_signed_p2pkh_spend, p2pkh_script_pubkey


class _RelayPeerStub:
    def __init__(self) -> None:
        self.peer_fee_filter_sat_kvb = None
        self.send = AsyncMock()
        self._connected = True

    @property
    def is_connected(self) -> bool:
        return self._connected


def _sample_wire_tx() -> Transaction:
    return Transaction(
        version=2,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=b"\xde" * 32, index=1),
                script_sig=b"",
                sequence=0xFFFFFFFF,
            ),
        ),
        outputs=(TxOut(value=9876, script_pubkey=b"\x51"),),
        lock_time=0,
    )


def _fund_tracker_and_signed_wire_like_tx(*, tracker: ProjectTracker, private_key: int = 1) -> Transaction:
    """Minimal P2PKH spend shaped like `_sample_wire_tx` for mempool admission tests."""
    point = _scalar_mult(private_key, (Gx, Gy))
    assert point is not None
    pubkey = bytes([0x02 + (point[1] % 2)]) + point[0].to_bytes(32, "big")

    prev = b"\xde" * 32
    prev_vout = 1
    input_sat = 1_235_679
    tracker.add_utxo(
        prev,
        prev_vout,
        height=101,
        value=input_sat,
        script_pubkey=p2pkh_script_pubkey(hash160(pubkey)),
        coinbase=False,
    )
    signed, _ = make_signed_p2pkh_spend(
        private_key=private_key,
        prev_txid=prev,
        prev_vout=prev_vout,
        prev_amount=input_sat,
        pubkey=pubkey,
        output_value=9876,
    )
    return signed


def test_tx_inventory_need_getdata_empty_pool_returns_all_hashes():
    pool = Mempool()
    h = b"\x99" * 32
    items = [InventoryVector(type=InventoryVector.MSG_WITNESS_TX, hash=h)]
    missing = tx_inventory_need_getdata(items, pool)
    assert missing == items


def test_tx_inventory_need_getdata_skips_when_witness_hash_known():
    pool = Mempool()
    tx = Transaction(
        version=2,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=b"\x11" * 32, index=0),
                script_sig=b"",
                sequence=0xFFFFFFFF,
            ),
        ),
        outputs=(TxOut(value=1, script_pubkey=b"\x51"),),
        lock_time=0,
        witness=((b"\x01",),),
    )
    assert pool.add(tx) is True
    w = transaction_wtxid(tx)
    items = [InventoryVector(type=InventoryVector.MSG_WITNESS_TX, hash=w)]
    assert tx_inventory_need_getdata(items, pool) == []


@pytest.mark.asyncio
async def test_inv_handler_sends_getdata_for_missing_tx(tmp_path):
    tracker = ProjectTracker(tmp_path / "inv_tx-chainstate")
    pool = Mempool()
    peer = PeerConnection(
        host="127.0.0.1",
        port=48333,
        chain=TESTNET4,
        tracker=tracker,
        protocol_version=70016,
        user_agent="/pybitnode:test/",
        mempool=pool,
    )
    peer.send = AsyncMock()
    inv_hash = b"\x33" * 32
    inv = InvMessage(inventory=[InventoryVector(type=InventoryVector.MSG_WITNESS_TX, hash=inv_hash)])
    await peer._dispatch("inv", inv.serialize())

    peer.send.assert_awaited()
    last_cmd, payload = peer.send.call_args[0]
    assert last_cmd == GetDataMessage.COMMAND
    gd = GetDataMessage.deserialize(payload)
    assert len(gd.inventory) == 1
    assert gd.inventory[0].type == InventoryVector.MSG_WITNESS_TX
    assert gd.inventory[0].hash == inv_hash
    tracker.close()


@pytest.mark.asyncio
async def test_inv_handler_skips_getdata_when_tx_in_mempool(tmp_path):
    tracker = ProjectTracker(tmp_path / "inv_skip-chainstate")
    pool = Mempool()
    tx = _fund_tracker_and_signed_wire_like_tx(tracker=tracker)
    assert accept_transaction(tx, tracker, mempool_claimed_prevouts=pool.claimed_prevouts_frozen())
    assert pool.add(tx) is True
    w = transaction_wtxid(tx)

    peer = PeerConnection(
        host="127.0.0.1",
        port=48333,
        chain=TESTNET4,
        tracker=tracker,
        protocol_version=70016,
        user_agent="/pybitnode:test/",
        mempool=pool,
    )
    peer.send = AsyncMock()
    inv = InvMessage(inventory=[InventoryVector(type=InventoryVector.MSG_WITNESS_TX, hash=w)])
    await peer._dispatch("inv", inv.serialize())
    peer.send.assert_not_called()
    tracker.close()


@pytest.mark.asyncio
async def test_peer_manager_relay_skips_source_peer(tmp_path):
    tracker = ProjectTracker(tmp_path / "relay_mgr-chainstate")
    mgr = PeerManager(TESTNET4, tracker, Settings())
    source = _RelayPeerStub()
    sink = _RelayPeerStub()
    mgr.connections = [source, sink]

    tx = _sample_wire_tx()
    await mgr.relay_accepted_transaction(tx, source)

    source.send.assert_not_awaited()
    sink.send.assert_awaited_once()
    cmd, payload = sink.send.await_args.args
    assert cmd == InvMessage.COMMAND
    dec = InvMessage.deserialize(payload)
    assert len(dec.inventory) == 1
    assert dec.inventory[0].type == InventoryVector.MSG_WITNESS_TX
    assert dec.inventory[0].hash == transaction_wtxid(tx)

    tracker.close()


@pytest.mark.asyncio
async def test_peer_dispatches_accept_triggers_relays(tmp_path):
    tracker = ProjectTracker(tmp_path / "relay_dispatch-chainstate")
    pool = Mempool()
    relays: list[tuple[str, Transaction, PeerConnection]] = []

    async def capture(tx_arg: Transaction, peer_arg: PeerConnection) -> None:
        relays.append(("relay", tx_arg, peer_arg))

    peer_a = PeerConnection(
        host="127.0.0.10",
        port=1,
        chain=TESTNET4,
        tracker=tracker,
        protocol_version=70016,
        user_agent="/pybitnode:test/",
        mempool=pool,
        relay_tx_accepted=capture,
    )
    tx = _fund_tracker_and_signed_wire_like_tx(tracker=tracker)
    payload = tx.serialize(include_witness=True)

    await peer_a._dispatch("tx", payload)
    assert len(relays) == 1 and relays[0][0] == "relay" and relays[0][2] is peer_a

    relays.clear()
    await peer_a._dispatch("tx", payload)
    assert relays == []

    tracker.close()


@pytest.mark.asyncio
async def test_reply_getdata_serves_pool_tx(tmp_path):
    tracker = ProjectTracker(tmp_path / "getdata_srv-chainstate")
    pool = Mempool()
    tx = _sample_wire_tx()
    assert pool.add(tx)
    tid = transaction_txid(tx)
    peer = PeerConnection(
        host="127.0.0.1",
        port=1,
        chain=TESTNET4,
        tracker=tracker,
        protocol_version=70016,
        user_agent="/pybitnode:test/",
        mempool=pool,
    )
    peer.send = AsyncMock()
    await reply_getdata_tx_inventory(
        peer,
        pool,
        tracker,
        [InventoryVector(type=InventoryVector.MSG_TX, hash=tid)],
    )
    peer.send.assert_awaited_once()
    cmd, blob = peer.send.await_args.args
    assert cmd == "tx"
    got, n = Transaction.deserialize(blob)
    assert n == len(blob)
    assert got.serialize(include_witness=False) == tx.serialize(include_witness=False)

    cap = list(
        tracker.db["wire_capabilities"].rows_where("capability_id = ?", ["serve.getdata.txs"], limit=1)
    )
    assert cap and cap[0]["implemented"] == 1
    tracker.close()


@pytest.mark.asyncio
async def test_reply_getdata_missing_tx_emits_notfound(tmp_path):
    tracker = ProjectTracker(tmp_path / "getdata_nf-chainstate")
    peer = PeerConnection(
        host="127.0.0.2",
        port=2,
        chain=TESTNET4,
        tracker=tracker,
        protocol_version=70016,
        user_agent="/pybitnode:test/",
    )
    peer.send = AsyncMock()
    h = b"\x99" * 32
    await reply_getdata_tx_inventory(peer, Mempool(), tracker, [InventoryVector(type=InventoryVector.MSG_TX, hash=h)])
    peer.send.assert_awaited_once()
    cmd, nf_payload = peer.send.await_args.args
    assert cmd == NotFoundMessage.COMMAND
    nf = NotFoundMessage.deserialize(nf_payload)
    assert len(nf.inventory) == 1 and nf.inventory[0].hash == h
    tracker.close()


@pytest.mark.asyncio
async def test_broadcast_witness_block_inv_announces_tip(tmp_path):
    tracker = ProjectTracker(tmp_path / "inv_tip-chainstate")
    bh = b"\xaa" * 32
    a = _RelayPeerStub()
    b = _RelayPeerStub()
    await broadcast_witness_block_inv([a, b], bh, tracker)

    assert a.send.await_count == b.send.await_count == 1
    cmd_a, payload_a = a.send.await_args.args
    assert cmd_a == InvMessage.COMMAND
    inv_a = InvMessage.deserialize(payload_a)
    assert len(inv_a.inventory) == 1
    assert inv_a.inventory[0].type == InventoryVector.MSG_WITNESS_BLOCK
    assert inv_a.inventory[0].hash == bh

    cap = list(
        tracker.db["wire_capabilities"].rows_where("capability_id = ?", ["serve.inv.blocks"], limit=1)
    )
    assert cap and cap[0]["implemented"] == 1

    tracker.close()








@pytest.mark.asyncio
async def test_feefilter_dispatch_stores_peer_filter(tmp_path):
    tracker = ProjectTracker(tmp_path / "ff_dispatch-chainstate")
    peer = PeerConnection(
        host="127.0.0.21",
        port=21,
        chain=TESTNET4,
        tracker=tracker,
        protocol_version=70016,
        user_agent="/pybitnode:test/",
    )
    filt = FeeFilterMessage(feerate_sat_kvb=42_500)
    assert peer.peer_fee_filter_sat_kvb is None
    await peer._dispatch(FeeFilterMessage.COMMAND, filt.serialize())
    assert peer.peer_fee_filter_sat_kvb == 42_500
    tracker.close()


@pytest.mark.asyncio
async def test_feefilter_dispatch_updates_on_repeat(tmp_path):
    tracker = ProjectTracker(tmp_path / "ff_update-chainstate")
    peer = PeerConnection(
        host="127.0.0.22",
        port=22,
        chain=TESTNET4,
        tracker=tracker,
        protocol_version=70016,
        user_agent="/pybitnode:test/",
    )
    await peer._dispatch(FeeFilterMessage.COMMAND, FeeFilterMessage(feerate_sat_kvb=999_999).serialize())
    assert peer.peer_fee_filter_sat_kvb == 999_999
    await peer._dispatch(FeeFilterMessage.COMMAND, FeeFilterMessage(feerate_sat_kvb=12_345).serialize())
    assert peer.peer_fee_filter_sat_kvb == 12_345
    await peer._dispatch(FeeFilterMessage.COMMAND, FeeFilterMessage(feerate_sat_kvb=0).serialize())
    assert peer.peer_fee_filter_sat_kvb == 0
    tracker.close()


def _signed_p2pkh_with_prev(
    *,
    tracker: ProjectTracker,
    prev: bytes,
    input_value: int,
    output_value: int,
    private_key: int = 1,
) -> Transaction:
    point = _scalar_mult(private_key, (Gx, Gy))
    assert point is not None
    pubkey = bytes([0x02 + (point[1] % 2)]) + point[0].to_bytes(32, "big")
    tracker.add_utxo(
        prev,
        0,
        height=101,
        value=input_value,
        script_pubkey=p2pkh_script_pubkey(hash160(pubkey)),
        coinbase=False,
    )
    signed, _ = make_signed_p2pkh_spend(
        private_key=private_key,
        prev_txid=prev,
        prev_vout=0,
        prev_amount=input_value,
        pubkey=pubkey,
        output_value=output_value,
    )
    return signed


@pytest.mark.asyncio
async def test_peer_manager_relay_skips_when_below_peer_feefilter(tmp_path):
    tracker = ProjectTracker(tmp_path / "relay_ff_skip-chainstate")
    prev = b"\xce" * 32
    input_value = 700_000
    peer_filter_sat_kvb = 100 * 1000

    placeholder = _signed_p2pkh_with_prev(
        tracker=tracker, prev=prev, input_value=input_value, output_value=input_value // 2
    )
    vbytes = estimate_tx_virtual_size_scaffold(placeholder)
    stingy_fee = max(0, (peer_filter_sat_kvb * vbytes) // 1000 - 1)
    stingy_tx = _signed_p2pkh_with_prev(
        tracker=tracker,
        prev=b"\xcf" * 32,
        input_value=input_value,
        output_value=input_value - stingy_fee,
    )
    assert transaction_meets_peer_feefilter(stingy_tx, tracker, peer_filter_sat_kvb) is False

    mgr = PeerManager(TESTNET4, tracker, Settings())
    strict = _RelayPeerStub()
    strict.peer_fee_filter_sat_kvb = peer_filter_sat_kvb
    open_peer = _RelayPeerStub()
    mgr.connections = [strict, open_peer]

    await mgr.relay_accepted_transaction(stingy_tx, _RelayPeerStub())

    strict.send.assert_not_awaited()
    open_peer.send.assert_awaited_once()

    tracker.close()


@pytest.mark.asyncio
async def test_peer_manager_relay_after_feefilter_zero(tmp_path):
    tracker = ProjectTracker(tmp_path / "relay_ff_zero-chainstate")
    prev = b"\xd0" * 32
    input_value = 700_000
    peer_filter_sat_kvb = 100 * 1000

    placeholder = _signed_p2pkh_with_prev(
        tracker=tracker, prev=prev, input_value=input_value, output_value=input_value // 2
    )
    vbytes = estimate_tx_virtual_size_scaffold(placeholder)
    stingy_fee = max(0, (peer_filter_sat_kvb * vbytes) // 1000 - 1)
    stingy_tx = _signed_p2pkh_with_prev(
        tracker=tracker,
        prev=b"\xd1" * 32,
        input_value=input_value,
        output_value=input_value - stingy_fee,
    )

    sink = _RelayPeerStub()
    sink.peer_fee_filter_sat_kvb = peer_filter_sat_kvb
    mgr = PeerManager(TESTNET4, tracker, Settings())
    mgr.connections = [sink]
    source = _RelayPeerStub()

    await mgr.relay_accepted_transaction(stingy_tx, source)
    sink.send.assert_not_awaited()

    sink.peer_fee_filter_sat_kvb = 0
    await mgr.relay_accepted_transaction(stingy_tx, source)
    sink.send.assert_awaited_once()

    tracker.close()


@pytest.mark.asyncio
async def test_inv_handler_batches_getdata_for_many_tx_hashes(monkeypatch, tmp_path):
    monkeypatch.setattr("pybitnode.p2p.peer.MAX_GETDATA_TX_BATCH", 2)

    tracker = ProjectTracker(tmp_path / "inv_batch-chainstate")
    pool = Mempool()
    peer = PeerConnection(
        host="127.0.0.5",
        port=5,
        chain=TESTNET4,
        tracker=tracker,
        protocol_version=70016,
        user_agent="/pybitnode:test/",
        mempool=pool,
    )
    peer.send = AsyncMock()
    items = [
        InventoryVector(type=InventoryVector.MSG_WITNESS_TX, hash=(i.to_bytes(32, "big")))
        for i in range(1, 7)
    ]
    inv = InvMessage(inventory=items)
    await peer._dispatch("inv", inv.serialize())

    assert peer.send.await_count == 3
    chunks: list[list[InventoryVector]] = []
    for call in peer.send.call_args_list:
        assert call.args[0] == GetDataMessage.COMMAND
        chunks.append(GetDataMessage.deserialize(call.args[1]).inventory)
    flat = [iv.hash for part in chunks for iv in part]
    assert flat == [iv.hash for iv in items]

    tracker.close()
