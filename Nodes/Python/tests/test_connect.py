from __future__ import annotations

import json

import pytest

from pybitnode.chain.genesis import TESTNET4_GENESIS
from pybitnode.chain.params import TESTNET4
from pybitnode.consensus.coinbase import decode_bip34_height
from pybitnode.consensus.connect import ConnectBlockError, connect_block, disconnect_block
from pybitnode.consensus.merkle import transaction_txid
from pybitnode.consensus.subsidy import block_subsidy
from pybitnode.consensus.witness import validate_witness_commitment
from pybitnode.db.tracker import ProjectTracker
from pybitnode.storage.blocks import BlockStore
from pybitnode.sync.blocks import connect_stored_blocks, rebuild_validated_chain
from pybitnode.sync.headers import ensure_genesis

from tests.blocks_fixture import FIXTURE_BLOCKS_DIR


@pytest.fixture
def block1_payload() -> bytes:
    return BlockStore(FIXTURE_BLOCKS_DIR, TESTNET4.magic).read("blk00000.dat", 0, 258)


def test_block_subsidy_at_height_one():
    assert block_subsidy(1) == 50 * 100_000_000


def test_decode_bip34_height_from_block1(block1_payload: bytes):
    from pybitnode.consensus.block import Block

    block = Block.deserialize(block1_payload)
    assert decode_bip34_height(block.transactions[0].inputs[0].script_sig) == 1


def test_witness_commitment_block1(block1_payload: bytes):
    from pybitnode.consensus.block import Block

    block = Block.deserialize(block1_payload)
    validate_witness_commitment(block.transactions[0], list(block.transactions))


def test_connect_block1_adds_utxo(tmp_path, block1_payload: bytes):
    tracker = ProjectTracker(tmp_path / "connect.db")
    ensure_genesis(tracker, TESTNET4)
    tracker.record_header(
        1,
        "0000000012982b6d5f621229286b880e909984df669c2afabb102ce311b13f28",
        TESTNET4.genesis_hash,
        1714777861,
    )

    block = connect_block(
        tracker,
        block1_payload,
        height=1,
        expected_prev=TESTNET4_GENESIS.block_hash(),
        expected_hash=bytes.fromhex("0000000012982b6d5f621229286b880e909984df669c2afabb102ce311b13f28")[::-1],
    )

    assert tracker.get_validated_height("testnet4") == 1
    assert tracker.utxo_count() == 1
    coinbase_txid = transaction_txid(block.transactions[0])
    utxo = tracker.get_utxo(coinbase_txid, 0)
    assert utxo is not None
    assert int(utxo["value"]) == 50 * 100_000_000
    assert utxo["coinbase"] == 1
    tracker.close()


def test_connect_block_requires_sequential_height(tmp_path, block1_payload: bytes):
    tracker = ProjectTracker(tmp_path / "order.db")
    ensure_genesis(tracker, TESTNET4)
    tracker.record_header(
        1,
        "0000000012982b6d5f621229286b880e909984df669c2afabb102ce311b13f28",
        TESTNET4.genesis_hash,
        1714777861,
    )
    with pytest.raises(ConnectBlockError, match="cannot connect height 2"):
        connect_block(
            tracker,
            block1_payload,
            height=2,
            expected_prev=b"\x00" * 32,
        )
    tracker.close()


def test_connect_block_rejects_immature_coinbase_spend(tmp_path, block1_payload: bytes):
    from pybitnode.consensus.block import Block
    from pybitnode.consensus.connect import ConnectBlockError, _BlockUtxoView, _validate_non_coinbase_inputs
    from pybitnode.messages.transaction import OutPoint, Transaction, TxIn, TxOut

    tracker = ProjectTracker(tmp_path / "immature.db")
    ensure_genesis(tracker, TESTNET4)
    tracker.record_header(
        1,
        "0000000012982b6d5f621229286b880e909984df669c2afabb102ce311b13f28",
        TESTNET4.genesis_hash,
        1714777861,
    )
    connect_block(
        tracker,
        block1_payload,
        height=1,
        expected_prev=TESTNET4_GENESIS.block_hash(),
        expected_hash=bytes.fromhex("0000000012982b6d5f621229286b880e909984df669c2afabb102ce311b13f28")[::-1],
    )

    block = Block.deserialize(block1_payload)
    coinbase_txid = transaction_txid(block.transactions[0])
    spend = Transaction(
        version=1,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=coinbase_txid, index=0),
                script_sig=b"\x00",
                sequence=0xFFFFFFFF,
            ),
        ),
        outputs=(TxOut(value=1, script_pubkey=b"\x51"),),
        lock_time=0,
    )

    view = _BlockUtxoView(tracker, height=2)
    with pytest.raises(ConnectBlockError, match="coinbase output not mature"):
        _validate_non_coinbase_inputs(view, spend)
    assert tracker.utxo_count() == 1
    tracker.close()


def test_disconnect_and_reconnect_block2(tmp_path):
    """Connect height 2, disconnect rewinds tip and UTXO set, reconnect restores state."""
    tracker = ProjectTracker(tmp_path / "reorg.db")
    ensure_genesis(tracker, TESTNET4)
    store = BlockStore(FIXTURE_BLOCKS_DIR, TESTNET4.magic)

    hashes = (
        "0000000012982b6d5f621229286b880e909984df669c2afabb102ce311b13f28",
        "000000001fed1a914651afc36574003c5300cac5df738c3976f28d54f7096253",
    )
    block1_payload = store.read("blk00000.dat", 0, 258)
    block2_payload = store.read("blk00000.dat", 266, 258)

    prev = TESTNET4.genesis_hash
    for height, hash_hex in enumerate(hashes, start=1):
        tracker.record_header(height, hash_hex, prev, 1714777861 + height)
        prev = hash_hex

    block_one = connect_block(
        tracker,
        block1_payload,
        height=1,
        expected_prev=TESTNET4_GENESIS.block_hash(),
        expected_hash=bytes.fromhex(hashes[0])[::-1],
    )
    cb1_txid = transaction_txid(block_one.transactions[0])

    utxos_after_1 = {
        (r["txid"], int(r["vout"]), int(r["height"]), int(r["value"]))
        for r in tracker.db["utxos"].rows
    }

    connect_block(
        tracker,
        block2_payload,
        height=2,
        expected_prev=bytes.fromhex(hashes[0])[::-1],
        expected_hash=bytes.fromhex(hashes[1])[::-1],
    )
    snapshot_after_two = {
        (r["txid"], int(r["vout"]), int(r["height"]), int(r["value"])) for r in tracker.db["utxos"].rows
    }

    # utxo_undo (entries_json): coinbase-only blocks → no external prevout spends to record
    for h in (1, 2):
        rows_undo = list(
            tracker.db["utxo_undo"].rows_where("chain = ? AND height = ?", ["testnet4", h], limit=1)
        )
        assert len(rows_undo) == 1
        assert "entries_json" in rows_undo[0]
        assert json.loads(rows_undo[0]["entries_json"]) == []

    assert tracker.get_validated_height("testnet4") == 2
    disconnect_block(tracker, 2, TESTNET4)

    assert tracker.get_validated_height("testnet4") == 1
    assert tracker.get_validated_hash("testnet4") == hashes[0]
    assert not list(tracker.db["utxo_undo"].rows_where("chain = ? AND height = ?", ["testnet4", 2]))
    assert len(list(tracker.db["utxo_undo"].rows_where("chain = ? AND height = ?", ["testnet4", 1]))) == 1
    assert {(r["txid"], int(r["vout"]), int(r["height"]), int(r["value"])) for r in tracker.db["utxos"].rows} == utxos_after_1

    reconnect = connect_block(
        tracker,
        block2_payload,
        height=2,
        expected_prev=bytes.fromhex(hashes[0])[::-1],
        expected_hash=bytes.fromhex(hashes[1])[::-1],
    )
    assert tracker.get_validated_height("testnet4") == 2
    assert {
        (r["txid"], int(r["vout"]), int(r["height"]), int(r["value"])) for r in tracker.db["utxos"].rows
    } == snapshot_after_two
    assert reconnect.transactions and tracker.get_utxo(cb1_txid, 0) is not None
    tracker.close()


def test_utxo_undo_external_spend_entry_shape(tmp_path):
    """Non-empty undo journal entries match the dict shape disconnect_block replays into add_utxo."""
    from pybitnode.consensus.connect import _BlockUtxoView, _external_spend_undo_entries
    from pybitnode.messages.transaction import OutPoint

    tracker = ProjectTracker(tmp_path / "undo_shape.db")
    ensure_genesis(tracker, TESTNET4)
    txid = b"\xab" * 32
    spk = b"\x76\xa9\x14" + b"\x00" * 20 + b"\x88\xac"
    tracker.add_utxo(txid, 0, height=1, value=12_345, script_pubkey=spk, coinbase=False)
    view = _BlockUtxoView(tracker, height=2)
    view.spend(OutPoint(hash=txid, index=0))
    entries = _external_spend_undo_entries(view)
    assert entries == [
        {
            "txid": txid[::-1].hex(),
            "vout": 0,
            "height": 1,
            "value": 12_345,
            "script_pubkey": spk.hex(),
            "coinbase": 0,
        }
    ]
    tracker.replace_utxo_undo("testnet4", 9, entries)
    loaded = json.loads(
        list(tracker.db["utxo_undo"].rows_where("chain = ? AND height = ?", ["testnet4", 9], limit=1))[0][
            "entries_json"
        ]
    )
    assert loaded == entries
    assert tracker.take_utxo_undo("testnet4", 9) == entries
    tracker.close()


def test_block_utxo_view_caches_external_reads(tmp_path, monkeypatch):
    from pybitnode.consensus.connect import _BlockUtxoView
    from pybitnode.messages.transaction import OutPoint

    tracker = ProjectTracker(tmp_path / "cache.db")
    ensure_genesis(tracker, TESTNET4)
    txid = b"\xcd" * 32
    tracker.add_utxo(txid, 0, height=1, value=5000, script_pubkey=b"\x51", coinbase=False)
    original_get_utxo = tracker.get_utxo
    calls = {"count": 0}

    def counted_get_utxo(txid_arg: bytes, vout_arg: int):
        calls["count"] += 1
        return original_get_utxo(txid_arg, vout_arg)

    monkeypatch.setattr(tracker, "get_utxo", counted_get_utxo)
    view = _BlockUtxoView(tracker, height=2, timings={})
    outpoint = OutPoint(hash=txid, index=0)

    assert view.get(outpoint) is not None
    assert view.get(outpoint) is not None
    assert calls["count"] == 1
    assert view.timings and view.timings["utxo_load"] >= 0
    tracker.close()


def test_block_utxo_view_does_not_persist_same_block_spent_outputs(tmp_path):
    from pybitnode.consensus.connect import _BlockUtxoView
    from pybitnode.messages.transaction import OutPoint

    tracker = ProjectTracker(tmp_path / "same_block.db")
    ensure_genesis(tracker, TESTNET4)
    txid = b"\x12" * 32
    view = _BlockUtxoView(tracker, height=2)

    view.create(txid, 0, value=5000, script_pubkey=b"\x51", coinbase=False)
    view.spend(OutPoint(hash=txid, index=0))
    view.apply()

    assert tracker.get_utxo(txid, 0) is None
    assert tracker.utxo_count() == 0
    tracker.close()


def test_block_utxo_view_rejects_duplicate_persisted_output(tmp_path):
    from pybitnode.consensus.connect import _BlockUtxoView

    tracker = ProjectTracker(tmp_path / "duplicate.db")
    ensure_genesis(tracker, TESTNET4)
    txid = b"\x34" * 32
    tracker.add_utxo(txid, 0, height=1, value=5000, script_pubkey=b"\x51", coinbase=False)
    view = _BlockUtxoView(tracker, height=2)

    with pytest.raises(ConnectBlockError, match="duplicate UTXO"):
        view.create(txid, 0, value=4000, script_pubkey=b"\x51", coinbase=False)

    assert tracker.get_utxo(txid, 0) is not None
    tracker.close()


def test_connect_block_timing_event_when_enabled(tmp_path, block1_payload: bytes, monkeypatch):
    monkeypatch.setenv("SYNC_TIMING", "1")
    tracker = ProjectTracker(tmp_path / "timing.db")
    ensure_genesis(tracker, TESTNET4)
    tracker.record_header(
        1,
        "0000000012982b6d5f621229286b880e909984df669c2afabb102ce311b13f28",
        TESTNET4.genesis_hash,
        1714777861,
    )

    connect_block(
        tracker,
        block1_payload,
        height=1,
        expected_prev=TESTNET4_GENESIS.block_hash(),
        expected_hash=bytes.fromhex("0000000012982b6d5f621229286b880e909984df669c2afabb102ce311b13f28")[::-1],
    )

    rows = list(tracker.db["events"].rows_where("category = ?", ["timing"], limit=1))
    assert len(rows) == 1
    details = json.loads(rows[0]["details_json"])
    assert details["height"] == 1
    assert {"utxo_load", "script_verify", "utxo_apply", "commit", "block_connect_store_commit"} <= set(
        details["stages_ms"]
    )
    tracker.close()


def test_disconnect_block_requires_tip(tmp_path):
    tracker = ProjectTracker(tmp_path / "tip.db")
    ensure_genesis(tracker, TESTNET4)
    with pytest.raises(ConnectBlockError, match="validated tip"):
        disconnect_block(tracker, 1, TESTNET4)
    tracker.close()


def test_connect_block_does_not_mutate_utxo_set_on_failure(tmp_path, block1_payload: bytes):
    from pybitnode.consensus.connect import _BlockUtxoView, _validate_non_coinbase_inputs
    from pybitnode.messages.transaction import OutPoint, Transaction, TxIn, TxOut

    tracker = ProjectTracker(tmp_path / "atomic.db")
    ensure_genesis(tracker, TESTNET4)
    tracker.record_header(
        1,
        "0000000012982b6d5f621229286b880e909984df669c2afabb102ce311b13f28",
        TESTNET4.genesis_hash,
        1714777861,
    )
    connect_block(
        tracker,
        block1_payload,
        height=1,
        expected_prev=TESTNET4_GENESIS.block_hash(),
        expected_hash=bytes.fromhex("0000000012982b6d5f621229286b880e909984df669c2afabb102ce311b13f28")[::-1],
    )
    before = tracker.utxo_count()
    bad_spend = Transaction(
        version=1,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=b"\x01" * 32, index=0),
                script_sig=b"\x00",
                sequence=0xFFFFFFFF,
            ),
        ),
        outputs=(TxOut(value=1, script_pubkey=b"\x51"),),
        lock_time=0,
    )
    view = _BlockUtxoView(tracker, height=2)
    with pytest.raises(ConnectBlockError, match="missing UTXO"):
        _validate_non_coinbase_inputs(view, bad_spend)
    assert tracker.utxo_count() == before
    tracker.close()


def test_validate_inputs_spends_only_after_script_verify_success(tmp_path, monkeypatch):
    import pybitnode.consensus.connect as connect_mod
    from pybitnode.consensus.connect import _BlockUtxoView, _validate_non_coinbase_inputs
    from pybitnode.consensus.script.script_verify_runner import ScriptVerifyBatchError
    from pybitnode.messages.transaction import OutPoint, Transaction, TxIn, TxOut

    tracker = ProjectTracker(tmp_path / "verify_failure.db")
    ensure_genesis(tracker, TESTNET4)
    txid = b"\xef" * 32
    tracker.add_utxo(txid, 0, height=1, value=5000, script_pubkey=b"\x51", coinbase=False)

    spend = Transaction(
        version=1,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=txid, index=0),
                script_sig=b"",
                sequence=0xFFFFFFFF,
            ),
        ),
        outputs=(TxOut(value=1, script_pubkey=b"\x51"),),
        lock_time=0,
    )

    def fail_verify(_tx, _spent_prevouts, _tasks):
        raise ScriptVerifyBatchError("script failed", elapsed_seconds=0.0)

    monkeypatch.setattr(connect_mod, "verify_inputs", fail_verify)
    view = _BlockUtxoView(tracker, height=2)

    with pytest.raises(ConnectBlockError, match="script failed"):
        _validate_non_coinbase_inputs(view, spend)

    assert not view.spent
    assert tracker.get_utxo(txid, 0) is not None
    tracker.close()


def test_connect_stored_blocks_1_through_5(tmp_path):
    tracker = ProjectTracker(tmp_path / "chain.db")
    ensure_genesis(tracker, TESTNET4)
    store = BlockStore(FIXTURE_BLOCKS_DIR, TESTNET4.magic)
    local_store = BlockStore(tmp_path / "blocks", TESTNET4.magic)

    offsets = [0, 266, 532, 798, 1064]
    hashes = [
        "0000000012982b6d5f621229286b880e909984df669c2afabb102ce311b13f28",
        "000000001fed1a914651afc36574003c5300cac5df738c3976f28d54f7096253",
        "000000008ddb4258595f9d8079a0b83fdc2816c9e3511acc739c16f5bce14e56",
        "000000008f5794caa45c418a0184303e848e9d6756e4d77234c9aada983b4265",
        "00000000ccefd2182ad4bb311c866233d32aae0a85f9568588ffd8e0432b7355",
    ]
    prev_hash = TESTNET4.genesis_hash
    for height, (offset, hash_hex) in enumerate(zip(offsets, hashes, strict=True), start=1):
        payload = store.read("blk00000.dat", offset, 258)
        file_name, file_offset, size = local_store.write(payload)
        tracker.record_header(height, hash_hex, prev_hash, 1714777860 + height)
        tracker.record_block(height, hash_hex, file_name, file_offset, size)
        prev_hash = hash_hex

    connected, _ = connect_stored_blocks(tracker, local_store, TESTNET4)
    assert connected == 5
    assert tracker.get_validated_height("testnet4") == 5
    assert tracker.utxo_count() == 5
    tracker.close()


def test_rebuild_validated_chain_restores_utxo_set(tmp_path):
    tracker = ProjectTracker(tmp_path / "chain.db")
    ensure_genesis(tracker, TESTNET4)
    store = BlockStore(FIXTURE_BLOCKS_DIR, TESTNET4.magic)
    local_store = BlockStore(tmp_path / "blocks", TESTNET4.magic)

    offsets = [0, 266, 532, 798, 1064]
    hashes = [
        "0000000012982b6d5f621229286b880e909984df669c2afabb102ce311b13f28",
        "000000001fed1a914651afc36574003c5300cac5df738c3976f28d54f7096253",
        "000000008ddb4258595f9d8079a0b83fdc2816c9e3511acc739c16f5bce14e56",
        "000000008f5794caa45c418a0184303e848e9d6756e4d77234c9aada983b4265",
        "00000000ccefd2182ad4bb311c866233d32aae0a85f9568588ffd8e0432b7355",
    ]
    prev_hash = TESTNET4.genesis_hash
    for height, (offset, hash_hex) in enumerate(zip(offsets, hashes, strict=True), start=1):
        payload = store.read("blk00000.dat", offset, 258)
        file_name, file_offset, size = local_store.write(payload)
        tracker.record_header(height, hash_hex, prev_hash, 1714777860 + height)
        tracker.record_block(height, hash_hex, file_name, file_offset, size)
        prev_hash = hash_hex

    rebuild_validated_chain(tracker, local_store, TESTNET4)
    assert tracker.get_validated_height("testnet4") == 5
    assert tracker.utxo_count() == 5

    tracker.db["utxos"].delete(list(tracker.db["utxos"].rows)[0]["id"])
    assert tracker.utxo_count() == 4

    rebuilt = rebuild_validated_chain(tracker, local_store, TESTNET4)
    assert rebuilt == 5
    assert tracker.utxo_count() == 5
    tracker.close()
