from __future__ import annotations

from unittest.mock import AsyncMock, MagicMock

import pytest

from pybitnode.chain.params import TESTNET4
from pybitnode.consensus.block import Block
from pybitnode.db.tracker import ProjectTracker
from pybitnode.messages.compact_block import (
    BlockTxnMessage,
    CompactBlockMessage,
    GetBlockTxnMessage,
    PrefilledTransaction,
    bitcoin_short_transaction_id,
    complete_compact_with_block_transactions,
    mempool_short_id_transaction_map,
    missing_indexes_for_getblocktxn,
    reconstruct_compact_block_wire,
    reconstruct_compact_transactions,
    reconstructed_block,
    serialize_block_wire,
    try_reconstruct_compact_block,
)
from pybitnode.messages.headers import BlockHeader
from pybitnode.messages.transaction import OutPoint, Transaction, TxIn, TxOut
from pybitnode.p2p.peer import PeerConnection


def _minimal_coinbase() -> Transaction:
    return Transaction(
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


def _minimal_spend() -> Transaction:
    return Transaction(
        version=2,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=b"\xab" * 32, index=0),
                script_sig=b"",
                sequence=0xFFFFFFFF,
            ),
        ),
        outputs=(TxOut(value=1000, script_pubkey=b"\x00"),),
        lock_time=0,
    )


def _dummy_header() -> BlockHeader:
    return BlockHeader(
        version=536870912,
        prev_block=b"\x01" * 32,
        merkle_root=b"\x02" * 32,
        timestamp=1_700_000_000,
        bits=0x1D00FFFF,
        nonce=0,
    )


def _witness_spend_tx() -> Transaction:
    return Transaction(
        version=2,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=b"\xcd" * 32, index=3),
                script_sig=b"\x76",
                sequence=1,
            ),
        ),
        outputs=(TxOut(value=50_000, script_pubkey=b"\xac"),),
        lock_time=0,
        witness=((b"\xaa\x55",),),
    )


def test_cmpctblock_roundtrip_header_shortids_prefilled():
    header = _dummy_header()
    short_id_nonce = 0xAABBCCDD11223344
    shortids = (b"\x01" * 6, b"\x02" * 6)
    cb = _minimal_coinbase()
    spend = _minimal_spend()
    msg = CompactBlockMessage(
        header=header,
        short_id_nonce=short_id_nonce,
        shortids=shortids,
        prefilled=(
            PrefilledTransaction(index=0, tx=cb),
            PrefilledTransaction(index=2, tx=spend),
        ),
    )
    raw = msg.serialize()
    restored = CompactBlockMessage.deserialize(raw)
    assert restored.header == header
    assert restored.short_id_nonce == short_id_nonce
    assert restored.shortids == shortids
    assert len(restored.prefilled) == 2
    assert restored.prefilled[0].index == 0
    assert restored.prefilled[1].index == 2
    assert restored.prefilled[0].tx == cb
    assert restored.prefilled[1].tx == spend


def test_cmpctblock_fixture_bytes_zero_shortids_one_prefilled():
    """Hand-built payload: header (80) + nonce (8) + 0 shortids + one prefilled index 0."""
    header = _dummy_header()
    short_id_nonce = 0
    tx = _minimal_coinbase()
    msg = CompactBlockMessage(
        header=header,
        short_id_nonce=short_id_nonce,
        shortids=(),
        prefilled=(PrefilledTransaction(index=0, tx=tx),),
    )
    raw = msg.serialize()
    assert raw[:80] == header.serialize()
    assert raw[80:88] == short_id_nonce.to_bytes(8, "little")
    assert raw[88] == 0x00  # varint 0 shortids
    assert raw[89] == 0x01  # varint 1 prefilled
    parsed = CompactBlockMessage.deserialize(raw)
    assert parsed.prefilled[0].tx == tx


def test_cmpctblock_rejects_truncated_shortid_region():
    header = _dummy_header().serialize()
    payload = header + (1).to_bytes(8, "little") + bytes([1]) + b"\x01\x02\x03"  # expect 6 bytes, got 3
    with pytest.raises(ValueError, match="truncated"):
        CompactBlockMessage.deserialize(payload)


def test_cmpctblock_rejects_trailing_garbage():
    msg = CompactBlockMessage(
        header=_dummy_header(),
        short_id_nonce=0,
        shortids=(),
        prefilled=(PrefilledTransaction(index=0, tx=_minimal_coinbase()),),
    )
    raw = msg.serialize() + b"\xff"
    with pytest.raises(ValueError, match="trailing"):
        CompactBlockMessage.deserialize(raw)


def test_cmpctblock_serialize_rejects_bad_shortid_length():
    msg = CompactBlockMessage(
        header=_dummy_header(),
        short_id_nonce=0,
        shortids=(b"\x01" * 5,),
        prefilled=(PrefilledTransaction(index=0, tx=_minimal_coinbase()),),
    )
    with pytest.raises(ValueError, match="6 bytes"):
        msg.serialize()


@pytest.mark.asyncio
async def test_peer_dispatch_cmpctblock_marks_wire_capability(tmp_path):
    tracker = ProjectTracker(tmp_path / "cmpctblock.db")
    peer = PeerConnection(
        host="127.0.0.1",
        port=48333,
        chain=TESTNET4,
        tracker=tracker,
        protocol_version=70016,
        user_agent="/pybitnode:0.1.0/",
    )
    msg = CompactBlockMessage(
        header=_dummy_header(),
        short_id_nonce=123,
        shortids=(b"\xcc" * 6,),
        prefilled=(PrefilledTransaction(index=0, tx=_minimal_coinbase()),),
    )
    await peer._dispatch(CompactBlockMessage.COMMAND, msg.serialize())
    row = list(tracker.db["wire_capabilities"].rows_where("capability_id = ?", ["ext.cmpctblock"], limit=1))[0]
    assert row["implemented"] == 1
    assert "partial" in row["notes"] or "parsed inbound cmpctblock" in row["notes"].lower()
    tracker.close()


def test_try_reconstruct_compact_block_from_mempool_wtxids():
    header = _dummy_header()
    nonce = 55_991
    coinbase = _minimal_coinbase()
    spend = _minimal_spend()
    sid = bitcoin_short_transaction_id(header, nonce, spend)
    compact = CompactBlockMessage(
        header=header,
        short_id_nonce=nonce,
        shortids=(sid,),
        prefilled=(PrefilledTransaction(index=0, tx=coinbase),),
    )
    merged = try_reconstruct_compact_block(compact, iter([spend]))
    assert merged == (coinbase, spend)
    assert try_reconstruct_compact_block(compact, ()) is None


@pytest.mark.asyncio
async def test_peer_dispatch_cmpctblock_reconstructed_with_mock_mempool(tmp_path):
    tracker = ProjectTracker(tmp_path / "cmpctblock_mx.db")
    peer = PeerConnection(
        host="127.0.0.1",
        port=48333,
        chain=TESTNET4,
        tracker=tracker,
        protocol_version=70016,
        user_agent="/pybitnode:0.1.0/",
    )
    header = _dummy_header()
    nonce = 771_771
    coinbase = _minimal_coinbase()
    spend = _minimal_spend()
    sid = bitcoin_short_transaction_id(header, nonce, spend)
    msg = CompactBlockMessage(
        header=header,
        short_id_nonce=nonce,
        shortids=(sid,),
        prefilled=(PrefilledTransaction(index=0, tx=coinbase),),
    )
    mempool = MagicMock()
    mempool.iter_pooled_transactions.return_value = iter([spend])
    peer.mempool = mempool
    await peer._dispatch(CompactBlockMessage.COMMAND, msg.serialize())
    row = list(tracker.db["wire_capabilities"].rows_where("capability_id = ?", ["ext.cmpctblock"], limit=1))[0]
    assert row["implemented"] == 1
    assert "reconstructed" in row["notes"]
    mempool.iter_pooled_transactions.assert_called_once_with()
    tracker.close()


def test_getblocktxn_message_wire_roundtrip():
    h = b"\xcc" * 32
    msg = GetBlockTxnMessage(block_hash=h, txn_indexes=(0, 2, 5))
    assert GetBlockTxnMessage.deserialize(msg.serialize()) == msg


def test_blocktxn_message_wire_roundtrip():
    h = b"\xdd" * 32
    txs = (_minimal_coinbase(), _minimal_spend())
    msg = BlockTxnMessage(block_hash=h, transactions=txs)
    assert BlockTxnMessage.deserialize(msg.serialize()).transactions == txs


def test_missing_indexes_for_getblocktxn():
    header = _dummy_header()
    nonce = 90909
    coinbase = _minimal_coinbase()
    spend = _minimal_spend()
    sid = bitcoin_short_transaction_id(header, nonce, spend)
    compact = CompactBlockMessage(
        header=header,
        short_id_nonce=nonce,
        shortids=(sid,),
        prefilled=(PrefilledTransaction(index=0, tx=coinbase),),
    )
    pool_map_only_spend = mempool_short_id_transaction_map(compact, (spend,))
    assert missing_indexes_for_getblocktxn(compact, pool_map_only_spend) == ()
    assert missing_indexes_for_getblocktxn(compact, {}) == (1,)
    cb_only = mempool_short_id_transaction_map(compact, [coinbase])
    assert cb_only is not None
    assert missing_indexes_for_getblocktxn(compact, cb_only) == (1,)


def test_complete_compact_with_block_transactions_fills_sid_gap():
    header = _dummy_header()
    nonce = 71717
    coinbase = _minimal_coinbase()
    spend = _minimal_spend()
    sid = bitcoin_short_transaction_id(header, nonce, spend)
    compact = CompactBlockMessage(
        header=header,
        short_id_nonce=nonce,
        shortids=(sid,),
        prefilled=(PrefilledTransaction(index=0, tx=coinbase),),
    )
    merged = mempool_short_id_transaction_map(compact, [])
    assert merged is not None
    txs = complete_compact_with_block_transactions(compact, merged, (1,), (spend,))
    assert txs == (coinbase, spend)


@pytest.mark.asyncio
async def test_peer_cmpctblock_sends_getblocktxn_then_accept_blocktxn(tmp_path):
    tracker = ProjectTracker(tmp_path / "cmpctblock_gettxn.db")
    peer = PeerConnection(
        host="127.0.0.1",
        port=48333,
        chain=TESTNET4,
        tracker=tracker,
        protocol_version=70016,
        user_agent="/pybitnode:0.1.0/",
    )
    peer.send = AsyncMock()
    header = _dummy_header()
    nonce = 424242
    coinbase = _minimal_coinbase()
    spend = _minimal_spend()
    sid = bitcoin_short_transaction_id(header, nonce, spend)
    msg = CompactBlockMessage(
        header=header,
        short_id_nonce=nonce,
        shortids=(sid,),
        prefilled=(PrefilledTransaction(index=0, tx=coinbase),),
    )
    mempool = MagicMock()
    mempool.iter_pooled_transactions.return_value = iter(())
    peer.mempool = mempool
    await peer._dispatch(CompactBlockMessage.COMMAND, msg.serialize())

    peer.send.assert_awaited()
    gb_cmd, gb_payload = peer.send.await_args.args
    assert gb_cmd == GetBlockTxnMessage.COMMAND
    outbound = GetBlockTxnMessage.deserialize(gb_payload)
    assert outbound.txn_indexes == (1,)
    assert outbound.block_hash == header.block_hash()

    reply = BlockTxnMessage(block_hash=header.block_hash(), transactions=(spend,))
    await peer._dispatch(BlockTxnMessage.COMMAND, reply.serialize())

    notes = [
        row["notes"] for row in tracker.db["wire_capabilities"].rows_where("capability_id = ?", ["ext.cmpctblock"])
    ]
    assert any("blocktxn" in n.lower() for n in notes)
    getblocktxn_rows = list(
        tracker.db["wire_capabilities"].rows_where("capability_id = ?", ["ext.getblocktxn"], limit=5)
    )
    assert len(getblocktxn_rows) >= 1
    assert getblocktxn_rows[0]["implemented"] == 1
    mempool.iter_pooled_transactions.assert_called_once_with()
    tracker.close()


@pytest.mark.asyncio
async def test_peer_cmpctblock_partial_mempool_then_blocktxn_merges_shortids(tmp_path):
    """Mempool resolves one BIP152 gap; remainder requested via getblocktxn then merged."""
    tracker = ProjectTracker(tmp_path / "cmpctblock_partial_merge.db")
    peer = PeerConnection(
        host="127.0.0.1",
        port=48333,
        chain=TESTNET4,
        tracker=tracker,
        protocol_version=70016,
        user_agent="/pybitnode:0.1.0/",
    )
    peer.send = AsyncMock()
    header = _dummy_header()
    nonce = 908_017
    coinbase = _minimal_coinbase()
    spend_a = _minimal_spend()
    spend_b = Transaction(
        version=2,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=b"\x12" * 32, index=2),
                script_sig=b"\x51",
                sequence=2,
            ),
        ),
        outputs=(TxOut(value=20, script_pubkey=b"\x76"),),
        lock_time=1,
    )
    sid_a = bitcoin_short_transaction_id(header, nonce, spend_a)
    sid_b = bitcoin_short_transaction_id(header, nonce, spend_b)
    msg = CompactBlockMessage(
        header=header,
        short_id_nonce=nonce,
        shortids=(sid_a, sid_b),
        prefilled=(PrefilledTransaction(index=0, tx=coinbase),),
    )
    mempool = MagicMock()
    mempool.iter_pooled_transactions.return_value = iter([spend_a])
    peer.mempool = mempool
    await peer._dispatch(CompactBlockMessage.COMMAND, msg.serialize())

    peer.send.assert_awaited()
    gb_cmd, gb_payload = peer.send.await_args.args
    assert gb_cmd == GetBlockTxnMessage.COMMAND
    outbound = GetBlockTxnMessage.deserialize(gb_payload)
    assert outbound.txn_indexes == (2,)
    assert outbound.block_hash == header.block_hash()

    reply = BlockTxnMessage(block_hash=header.block_hash(), transactions=(spend_b,))
    await peer._dispatch(BlockTxnMessage.COMMAND, reply.serialize())

    notes = [
        row["notes"] for row in tracker.db["wire_capabilities"].rows_where("capability_id = ?", ["ext.cmpctblock"])
    ]
    assert any("getblocktxn + blocktxn" in n.lower() for n in notes)
    mempool.iter_pooled_transactions.assert_called_once_with()
    tracker.close()


def test_complete_compact_merges_partial_pool_map_with_blocktxn():
    """Non-empty pool_map from mempool must combine with blocktxn replies (BIP152 merge)."""
    header = _dummy_header()
    nonce = 606_606
    coinbase = _minimal_coinbase()
    spend_a = _minimal_spend()
    spend_b = Transaction(
        version=2,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=b"\x99" * 32, index=4),
                script_sig=b"\x03",
                sequence=0xFFFFFFFF,
            ),
        ),
        outputs=(TxOut(value=9, script_pubkey=b"\xaa"),),
        lock_time=0,
    )
    sid_a = bitcoin_short_transaction_id(header, nonce, spend_a)
    sid_b = bitcoin_short_transaction_id(header, nonce, spend_b)
    compact = CompactBlockMessage(
        header=header,
        short_id_nonce=nonce,
        shortids=(sid_a, sid_b),
        prefilled=(PrefilledTransaction(index=0, tx=coinbase),),
    )
    partial = mempool_short_id_transaction_map(compact, [spend_a])
    assert partial is not None
    merged = complete_compact_with_block_transactions(compact, partial, (2,), (spend_b,))
    assert merged == (coinbase, spend_a, spend_b)


def test_compact_block_reconstruction_coinbase_only_roundtrip():
    header = _dummy_header()
    nonce = 91_235_971
    coinbase = _minimal_coinbase()
    compact = CompactBlockMessage(
        header=header,
        short_id_nonce=nonce,
        shortids=(),
        prefilled=(PrefilledTransaction(index=0, tx=coinbase),),
    )
    wire = reconstruct_compact_block_wire(compact, {})
    block = Block.deserialize(wire)
    assert block.header == header
    assert block.transactions == (coinbase,)


def test_compact_block_reconstruction_multitx_using_bip152_shortids():
    header = _dummy_header()
    nonce = 4_218_837
    coinbase = _minimal_coinbase()
    spend_a = _minimal_spend()
    spend_b = Transaction(
        version=2,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=b"\x12" * 32, index=2),
                script_sig=b"\x51",
                sequence=2,
            ),
        ),
        outputs=(TxOut(value=20, script_pubkey=b"\x76"),),
        lock_time=1,
    )
    ids = (
        bitcoin_short_transaction_id(header, nonce, spend_a),
        bitcoin_short_transaction_id(header, nonce, spend_b),
    )
    compact = CompactBlockMessage(
        header=header,
        short_id_nonce=nonce,
        shortids=ids,
        prefilled=(PrefilledTransaction(index=0, tx=coinbase),),
    )
    by_sid = {ids[0]: spend_a, ids[1]: spend_b}
    assert reconstruct_compact_transactions(compact, by_sid) == (coinbase, spend_a, spend_b)
    rebuilt = reconstructed_block(compact, by_sid)
    assert rebuilt.transactions == (coinbase, spend_a, spend_b)


def test_compact_block_try_reconstruct_from_transaction_list():
    header = _dummy_header()
    nonce = 880_022
    coinbase = _minimal_coinbase()
    spend = _minimal_spend()
    sid = bitcoin_short_transaction_id(header, nonce, spend)
    compact = CompactBlockMessage(
        header=header,
        short_id_nonce=nonce,
        shortids=(sid,),
        prefilled=(PrefilledTransaction(index=0, tx=coinbase),),
    )
    assert try_reconstruct_compact_block(compact, [spend, coinbase]) == (coinbase, spend)
    assert try_reconstruct_compact_block(compact, iter([])) is None


def test_compact_block_reconstruction_hole_prefill_keeps_shortid_sequence():
    header = _dummy_header()
    nonce = 99
    cb = _minimal_coinbase()
    spend_mid = _minimal_spend()
    spend_last = Transaction(
        version=2,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=b"\x22" * 32, index=1),
                script_sig=b"\xaa",
                sequence=0,
            ),
        ),
        outputs=(TxOut(value=777, script_pubkey=b"\xbb"),),
        lock_time=0,
    )
    sid_mid = bitcoin_short_transaction_id(header, nonce, spend_mid)
    compact = CompactBlockMessage(
        header=header,
        short_id_nonce=nonce,
        shortids=(sid_mid,),
        prefilled=(
            PrefilledTransaction(index=0, tx=cb),
            PrefilledTransaction(index=2, tx=spend_last),
        ),
    )
    by_sid = {sid_mid: spend_mid}
    txs = reconstruct_compact_transactions(compact, by_sid)
    assert txs == (cb, spend_mid, spend_last)


def test_compact_block_reconstruction_raises_on_unknown_short():
    header = _dummy_header()
    coinbase = _minimal_coinbase()
    compact = CompactBlockMessage(
        header=header,
        short_id_nonce=1,
        shortids=(bitcoin_short_transaction_id(header, 1, _minimal_spend()),),
        prefilled=(PrefilledTransaction(index=0, tx=coinbase),),
    )
    with pytest.raises(KeyError, match="short ID"):
        reconstruct_compact_transactions(compact, {})


def test_compact_block_reconstruction_prefill_out_of_range():
    compact = CompactBlockMessage(
        header=_dummy_header(),
        short_id_nonce=0,
        shortids=(b"\x11" * 6,),
        prefilled=(
            PrefilledTransaction(index=3, tx=_minimal_coinbase()),
            PrefilledTransaction(index=4, tx=_minimal_spend()),
        ),
    )
    assert len(compact.prefilled) + len(compact.shortids) == 3
    with pytest.raises(ValueError, match="out of range"):
        reconstruct_compact_transactions(compact, {b"\x11" * 6: _minimal_spend()})


def test_compact_block_reconstruction_duplicate_prefilled_index_collapses():
    header = _dummy_header()
    spend = _minimal_spend()
    dup = CompactBlockMessage(
        header=header,
        short_id_nonce=123,
        shortids=(bitcoin_short_transaction_id(header, 123, spend),),
        prefilled=(
            PrefilledTransaction(index=0, tx=_minimal_coinbase()),
            PrefilledTransaction(index=0, tx=spend),
        ),
    )
    with pytest.raises(ValueError, match="duplicate prefilled"):
        reconstruct_compact_transactions(dup, {bitcoin_short_transaction_id(header, 123, spend): spend})


def test_compact_block_wire_serialize_matches_deserialize_with_witness():
    header = _dummy_header()
    txs = (_minimal_coinbase(), _witness_spend_tx())
    wire = serialize_block_wire(header, txs)
    assert Block.deserialize(wire).transactions == txs


def test_compact_witness_tx_short_id_and_wire_reconstruction_roundtrip():
    header = _dummy_header()
    nonce = 771_099
    coinbase = _minimal_coinbase()
    wtx = _witness_spend_tx()
    sid = bitcoin_short_transaction_id(header, nonce, wtx)
    compact = CompactBlockMessage(
        header=header,
        short_id_nonce=nonce,
        shortids=(sid,),
        prefilled=(PrefilledTransaction(index=0, tx=coinbase),),
    )
    blob = reconstruct_compact_block_wire(compact, {sid: wtx})
    restored = Block.deserialize(blob)
    assert restored.transactions == (coinbase, wtx)
