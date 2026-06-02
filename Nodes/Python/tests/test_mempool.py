from __future__ import annotations

from dataclasses import replace
from unittest.mock import patch

import pytest

from pybitnode.config import Settings
from pybitnode.consensus.hash import hash160
from pybitnode.consensus.merkle import transaction_txid
from pybitnode.consensus.script.interpreter import _taproot_tweak_pubkey_xonly
from pybitnode.consensus.script.sighash import tapleaf_hash
from pybitnode.consensus.secp256k1 import N, _scalar_mult, Gx, Gy
from pybitnode.consensus.witness import transaction_wtxid
from pybitnode.db.tracker import ProjectTracker
from pybitnode.mempool import Mempool, accept_transaction, transaction_meets_peer_feefilter, OrphanPool
from pybitnode.mempool.mempool import collect_missing_prevouts, estimate_tx_virtual_size_scaffold
from pybitnode.messages.compact_block import (
    CompactBlockMessage,
    PrefilledTransaction,
    bitcoin_short_transaction_id,
    mempool_short_id_transaction_map,
    missing_indexes_for_getblocktxn,
)
from pybitnode.messages.headers import BlockHeader
from pybitnode.messages.inventory import InventoryVector
from pybitnode.messages.transaction import OutPoint, Transaction, TxIn, TxOut
from tests.script_helpers import make_signed_p2pkh_spend, p2pkh_script_pubkey


def _signed_parent_child_chain(
    *,
    prev_coin: bytes,
    coin_amt: int,
    parent_to_child_value: int,
    child_remainder_value: int,
    private_key: int,
    pubkey: bytes,
    parent_fee: int = 5000,
    child_fee: int = 5000,
) -> tuple[Transaction, Transaction]:
    """Parent spends chain UTXO to p2pkh (same key); child spends parent with matching script."""
    redeem = p2pkh_script_pubkey(hash160(pubkey))
    parent_signed, _ = make_signed_p2pkh_spend(
        private_key=private_key,
        prev_txid=prev_coin,
        prev_vout=0,
        prev_amount=coin_amt,
        pubkey=pubkey,
        output_value=parent_to_child_value,
        output_script_pubkey=redeem,
    )
    parent_actual_fee = coin_amt - parent_to_child_value
    assert parent_actual_fee >= parent_fee
    pid = transaction_txid(parent_signed)
    child_signed, _ = make_signed_p2pkh_spend(
        private_key=private_key,
        prev_txid=pid,
        prev_vout=0,
        prev_amount=parent_to_child_value,
        pubkey=pubkey,
        output_value=child_remainder_value,
        output_script_pubkey=b"\x51",
    )
    child_actual_fee = parent_to_child_value - child_remainder_value
    assert child_actual_fee >= child_fee
    return parent_signed, child_signed




def _test_pubkey_sec1(private_key: int = 1) -> bytes:
    point = _scalar_mult(private_key, (Gx, Gy))
    assert point is not None
    return bytes([0x02 + (point[1] % 2)]) + point[0].to_bytes(32, "big")


def _fund_p2pkh_utxo(*, tracker: ProjectTracker, prevout: bytes, pubkey: bytes, value: int) -> None:
    spk = p2pkh_script_pubkey(hash160(pubkey))
    tracker.add_utxo(prevout, 0, height=12, value=value, script_pubkey=spk, coinbase=False)


def _signed_p2pkh_roundtrip(private_key: int, prev_txid: bytes, input_value: int, output_value: int) -> Transaction:
    pubkey = _test_pubkey_sec1(private_key)
    signed, _script_pubkey_unused = make_signed_p2pkh_spend(
        private_key=private_key,
        prev_txid=prev_txid,
        prev_vout=0,
        prev_amount=input_value,
        pubkey=pubkey,
        output_value=output_value,
    )
    return signed


def _sample_tx(prev: bytes | None = None) -> Transaction:
    h = prev if prev is not None else b"\xab" * 32
    return Transaction(
        version=2,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=h, index=0),
                script_sig=b"",
                sequence=0xFFFFFFFF,
            ),
        ),
        outputs=(TxOut(value=1234, script_pubkey=b"\x51"),),
        lock_time=0,
    )


def _internal_xonly_bip340_normalized(private_key: int) -> bytes:
    pt = _scalar_mult(private_key, (Gx, Gy))
    assert pt is not None
    x_cc, y_cc = pt
    if y_cc % 2 != 0:
        pt = _scalar_mult((N - private_key) % N, (Gx, Gy))
        assert pt is not None
        x_cc = pt[0]
    return x_cc.to_bytes(32, "big")


def test_mempool_accept_taproot_script_path_spend(tmp_path):
    db = tmp_path / "tr_script_sp.db"
    tracker = ProjectTracker(str(db))
    prev = bytes.fromhex("44" * 32)
    input_value = 2_250_000
    internal_x = _internal_xonly_bip340_normalized(99)
    tapscript = bytes([0x51])  # tapscript OP_1
    merkle = tapleaf_hash(0xC0, tapscript)
    parity_q, out_xonly = _taproot_tweak_pubkey_xonly(internal_x, merkle)
    p2tr_spk = bytes([0x51, 0x20]) + out_xonly
    control_block = bytes([0xC0 | (parity_q & 1)]) + internal_x

    tracker.add_utxo(prev, 0, height=20, value=input_value, script_pubkey=p2tr_spk, coinbase=False)

    spend_tx = Transaction(
        version=2,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=prev, index=0),
                script_sig=b"",
                sequence=0xFFFFFFFD,
            ),
        ),
        outputs=(TxOut(value=2_236_250, script_pubkey=b"\x51"),),
        lock_time=0,
        witness=((tapscript, control_block),),
    )
    overlay_settings = Settings(min_relay_feerate_sat_vb=0)
    assert accept_transaction(spend_tx, tracker, settings=overlay_settings)

    pool = Mempool(max_size_bytes=512 * 1024, tracker=tracker, settings=overlay_settings)
    assert pool.add(spend_tx)

    tracker.close()


def test_mempool_add_remove_roundtrip(tmp_path):
    db = tmp_path / "t.db"
    tracker = ProjectTracker(str(db))
    pool = Mempool(max_size_bytes=256 * 1024)

    prev = b"\xaa" * 32
    input_value = 2_500_000
    pubkey = _test_pubkey_sec1()
    _fund_p2pkh_utxo(tracker=tracker, prevout=prev, pubkey=pubkey, value=input_value)

    signed = _signed_p2pkh_roundtrip(private_key=1, prev_txid=prev, input_value=input_value, output_value=100_000)
    tid = transaction_txid(signed)

    assert accept_transaction(signed, tracker)
    assert pool.add(signed) is True
    assert pool.get(tid) is signed
    assert pool.total_size_bytes() > 0
    assert pool.remove(tid) is True
    assert pool.get(tid) is None
    assert pool.total_size_bytes() == 0
    tracker.close()


def test_mempool_rejects_duplicate():
    pool = Mempool()
    tx = _sample_tx()
    assert pool.add(tx) is True
    assert pool.add(tx) is False


def test_mempool_respects_capacity():
    tx_small = Transaction(
        version=1,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=b"\x01" * 32, index=0),
                script_sig=b"",
                sequence=0xFFFFFFFF,
            ),
        ),
        outputs=(TxOut(value=1, script_pubkey=b""),),
        lock_time=0,
    )
    tx_other = Transaction(
        version=1,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=b"\x02" * 32, index=0),
                script_sig=b"",
                sequence=0xFFFFFFFF,
            ),
        ),
        outputs=(TxOut(value=1, script_pubkey=b""),),
        lock_time=0,
    )
    one_size = len(tx_small.serialize(include_witness=True))
    pool = Mempool(max_size_bytes=one_size)
    tid_small = transaction_txid(tx_small)
    tid_other = transaction_txid(tx_other)
    assert pool.add(tx_small) is True
    # Fresh tx won't fit beside the incumbent; eviction drops the oldest entry first (tx_small).
    assert pool.add(tx_other) is True
    assert pool.get(tid_small) is None
    assert pool.get(tid_other) is tx_other
    assert pool.total_size_bytes() <= one_size


def test_mempool_get_for_inv_witness_vs_tx_hash():
    pool = Mempool()
    tx = Transaction(
        version=2,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=b"\x11" * 32, index=3),
                script_sig=b"",
                sequence=0xFFFFFFFF,
            ),
        ),
        outputs=(TxOut(value=555, script_pubkey=b"\x51"),),
        lock_time=0,
        witness=((b"\xaa\xbb",),),
    )
    assert pool.add(tx) is True
    tid = transaction_txid(tx)
    wid = transaction_wtxid(tx)
    assert tid != wid
    assert pool.get_for_inv(inv_type=InventoryVector.MSG_TX, inv_hash=tid) is tx
    assert pool.get_for_inv(inv_type=InventoryVector.MSG_WITNESS_TX, inv_hash=wid) is tx


@pytest.mark.parametrize(
    "tx_factory",
    [
        pytest.param(
            lambda: Transaction(
                version=2,
                inputs=(
                    TxIn(
                        previous_output=OutPoint(hash=b"\x00" * 32, index=0xFFFFFFFF),
                        script_sig=b"\x03",
                        sequence=0xFFFFFFFF,
                    ),
                ),
                outputs=(TxOut(value=1234, script_pubkey=b"\x51"),),
                lock_time=0,
            ),
            id="coinbase",
        ),
        pytest.param(
            lambda: Transaction(
                version=1,
                inputs=(),
                outputs=(TxOut(value=1, script_pubkey=b"\x51"),),
                lock_time=0,
            ),
            id="no_inputs",
        ),
        pytest.param(
            lambda: Transaction(
                version=1,
                inputs=(
                    TxIn(
                        previous_output=OutPoint(hash=b"\x01" * 32, index=0),
                        script_sig=b"",
                        sequence=0xFFFFFFFF,
                    ),
                ),
                outputs=(),
                lock_time=0,
            ),
            id="no_outputs",
        ),
    ],
)
def test_accept_transaction_rejects_when_structure_invalid(tmp_path, tx_factory: object) -> None:
    tracker = ProjectTracker(str(tmp_path / "structure.db"))
    tx = tx_factory()
    assert accept_transaction(tx, tracker) is False
    tracker.close()


def test_accept_transaction_accepts_valid_p2pkh_spend(tmp_path) -> None:
    tracker = ProjectTracker(str(tmp_path / "good_p2pkh.db"))
    prev = b"\x12" * 32
    input_value = 1_234_568
    pubkey = _test_pubkey_sec1()
    _fund_p2pkh_utxo(tracker=tracker, prevout=prev, pubkey=pubkey, value=input_value)

    signed = _signed_p2pkh_roundtrip(
        private_key=1,
        prev_txid=prev,
        input_value=input_value,
        output_value=50_000,
    )
    assert accept_transaction(signed, tracker)
    tracker.close()


def _fund_utxo(*, tracker: ProjectTracker, prevout: bytes, value: int) -> None:
    tracker.add_utxo(prevout, 0, height=12, value=value, script_pubkey=b"\x51", coinbase=False)


def _spend_prev(prevout: bytes, output_value: int) -> Transaction:
    return Transaction(
        version=2,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=prevout, index=0),
                script_sig=b"",
                sequence=0xFFFFFFFF,
            ),
        ),
        outputs=(TxOut(value=output_value, script_pubkey=b"\x51"),),
        lock_time=0,
    )


def test_accept_transaction_min_relay_rejects_unknown_prevouts(tmp_path):
    tracker = ProjectTracker(str(tmp_path / "relay_prev.db"))
    tx = _spend_prev(b"\xbb" * 32, output_value=1)
    policies = Settings(min_relay_feerate_sat_vb=1)
    assert accept_transaction(tx, tracker, settings=policies) is False
    tracker.close()


def test_accept_transaction_min_relay_rejects_below_threshold(tmp_path):
    tracker = ProjectTracker(str(tmp_path / "relay_below.db"))
    prev = b"\xcc" * 32
    input_value = 500_000
    pubkey = _test_pubkey_sec1()
    _fund_p2pkh_utxo(tracker=tracker, prevout=prev, pubkey=pubkey, value=input_value)

    min_rate = 50
    policies = Settings(min_relay_feerate_sat_vb=min_rate)

    placeholder = _signed_p2pkh_roundtrip(1, prev, input_value=input_value, output_value=input_value // 2)
    vbytes = estimate_tx_virtual_size_scaffold(placeholder)
    required_fee = min_rate * vbytes
    assert required_fee >= 1
    stingy_fee = required_fee - 1
    assert stingy_fee >= 0

    stingy_tx = _signed_p2pkh_roundtrip(
        private_key=1,
        prev_txid=prev,
        input_value=input_value,
        output_value=input_value - stingy_fee,
    )
    assert estimate_tx_virtual_size_scaffold(stingy_tx) == vbytes
    assert accept_transaction(stingy_tx, tracker, settings=policies) is False
    tracker.close()


def test_accept_transaction_negative_fee_checked_after_verification_stub(tmp_path):
    tracker = ProjectTracker(str(tmp_path / "negative_fee.db"))
    prev = b"\xcf" * 32
    _fund_utxo(tracker=tracker, prevout=prev, value=10_000)
    bogus = Transaction(
        version=1,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=prev, index=0),
                script_sig=b"\x42",
                sequence=0xFFFFFFFF,
            ),
        ),
        outputs=(TxOut(value=10_501, script_pubkey=b"\x51"),),
        lock_time=0,
    )
    with patch(
        "pybitnode.mempool.mempool.verify_transaction_input",
        lambda *a, **k: None,
    ):
        assert accept_transaction(bogus, tracker) is False

    sane = replace(bogus, outputs=(TxOut(value=9_000, script_pubkey=b"\x51"),))
    with patch(
        "pybitnode.mempool.mempool.verify_transaction_input",
        lambda *a, **k: None,
    ):
        assert accept_transaction(sane, tracker) is True
    tracker.close()


def test_accept_transaction_rejects_duplicate_prevouts_within_same_tx(tmp_path):
    tracker = ProjectTracker(str(tmp_path / "dup_prev.db"))
    prev = b"\xda" * 32
    input_value = 90_000
    pubkey = _test_pubkey_sec1()
    _fund_p2pkh_utxo(tracker=tracker, prevout=prev, pubkey=pubkey, value=input_value)

    signed = _signed_p2pkh_roundtrip(1, prev, input_value=input_value, output_value=50_000)
    i0 = signed.inputs[0]
    dup_inputs = (
        TxIn(
            previous_output=i0.previous_output,
            script_sig=i0.script_sig,
            sequence=i0.sequence,
        ),
        TxIn(
            previous_output=i0.previous_output,
            script_sig=i0.script_sig,
            sequence=i0.sequence,
        ),
    )
    dup_tx = Transaction(
        version=signed.version,
        inputs=dup_inputs,
        outputs=signed.outputs,
        lock_time=signed.lock_time,
    )
    assert accept_transaction(dup_tx, tracker) is False
    tracker.close()


def test_accept_transaction_second_spend_conflict_when_mempool_claims_prevout(tmp_path):
    tracker = ProjectTracker(str(tmp_path / "mempool_ds.db"))
    prev = b"\xdb" * 32
    input_value = 400_000
    pubkey = _test_pubkey_sec1()
    _fund_p2pkh_utxo(tracker=tracker, prevout=prev, pubkey=pubkey, value=input_value)

    tx_a = _signed_p2pkh_roundtrip(1, prev, input_value=input_value, output_value=300_000)
    tx_b = _signed_p2pkh_roundtrip(1, prev, input_value=input_value, output_value=250_000)
    assert tx_a != tx_b

    pool = Mempool(tracker=None)
    assert accept_transaction(tx_a, tracker, mempool_claimed_prevouts=None)
    pool.add(tx_a)

    claimed = pool.claimed_prevouts_frozen()
    assert accept_transaction(tx_b, tracker, mempool_claimed_prevouts=claimed) is False

    tracker.close()


def test_mempool_claimed_prevouts_roundtrip_when_add_then_remove(tmp_path):
    tracker = ProjectTracker(str(tmp_path / "claim_round.db"))
    pool = Mempool(tracker=None)
    prev = b"\xdc" * 32
    input_value = 800_000
    pubkey = _test_pubkey_sec1()
    _fund_p2pkh_utxo(tracker=tracker, prevout=prev, pubkey=pubkey, value=input_value)

    tx = _signed_p2pkh_roundtrip(1, prev, input_value=input_value, output_value=750_000)
    assert pool.add(tx)
    assert (prev, 0) in pool.claimed_prevouts_frozen()
    assert pool.remove(transaction_txid(tx))
    assert (prev, 0) not in pool.claimed_prevouts_frozen()
    tracker.close()


def test_transaction_meets_peer_feefilter_passes_until_peer_announces(tmp_path):
    tracker = ProjectTracker(str(tmp_path / "ff_utxo.db"))
    prev = b"\xee" * 32
    _fund_utxo(tracker=tracker, prevout=prev, value=600_000)
    tx = _spend_prev(prev, output_value=599_990)
    assert transaction_meets_peer_feefilter(tx, tracker, None) is True
    assert transaction_meets_peer_feefilter(tx, tracker, 0) is True
    tracker.close()


def test_transaction_meets_peer_feefilter_below_peer_minimum(tmp_path):
    tracker = ProjectTracker(str(tmp_path / "ff_below.db"))
    prev = b"\xff" * 32
    input_value = 700_000
    _fund_utxo(tracker=tracker, prevout=prev, value=input_value)

    placeholder = _spend_prev(prev, output_value=input_value // 2)
    vbytes = estimate_tx_virtual_size_scaffold(placeholder)

    peer_filter_sat_kvb = 100 * 1000  # 100 sat/vB
    stingy_fee = (peer_filter_sat_kvb * vbytes) // 1000 - 1
    assert stingy_fee >= 0
    stingy_tx = _spend_prev(prev, output_value=input_value - stingy_fee)
    assert transaction_meets_peer_feefilter(stingy_tx, tracker, peer_filter_sat_kvb) is False

    tight_fee = (peer_filter_sat_kvb * vbytes + 999) // 1000  # ceil in fee space
    ok_tx = _spend_prev(prev, output_value=input_value - tight_fee)
    assert transaction_meets_peer_feefilter(ok_tx, tracker, peer_filter_sat_kvb) is True
    tracker.close()


def test_accept_transaction_min_relay_accepts_exact_threshold(tmp_path):
    tracker = ProjectTracker(str(tmp_path / "relay_ok.db"))
    prev = b"\xdd" * 32
    input_value = 800_000
    pubkey = _test_pubkey_sec1()
    _fund_p2pkh_utxo(tracker=tracker, prevout=prev, pubkey=pubkey, value=input_value)

    min_rate = 50
    policies = Settings(min_relay_feerate_sat_vb=min_rate)

    placeholder = _signed_p2pkh_roundtrip(1, prev, input_value=input_value, output_value=input_value // 2)
    vbytes = estimate_tx_virtual_size_scaffold(placeholder)
    fee = min_rate * vbytes
    ok_tx = _signed_p2pkh_roundtrip(
        private_key=1,
        prev_txid=prev,
        input_value=input_value,
        output_value=input_value - fee,
    )
    assert estimate_tx_virtual_size_scaffold(ok_tx) == vbytes

    assert accept_transaction(ok_tx, tracker, settings=policies) is True

    mempool = Mempool(tracker=tracker)
    assert mempool.add(ok_tx)
    assert int(tracker.get_meta("mempool_tx_count") or "0") == 1

    tracker.close()


def test_mempool_invalid_capacity():
    with pytest.raises(ValueError, match="max_size_bytes"):
        Mempool(max_size_bytes=0)


def test_mempool_invalid_mempool_max_count():
    with pytest.raises(ValueError, match="mempool_max_count"):
        Mempool(mempool_max_count=-1)


def test_mempool_evict_over_capacity_removes_oldest_first():
    tx_a = Transaction(
        version=1,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=b"\x71" * 32, index=0),
                script_sig=b"",
                sequence=0xFFFFFFFF,
            ),
        ),
        outputs=(TxOut(value=1, script_pubkey=b"\x51"),),
        lock_time=0,
    )
    tx_b = Transaction(
        version=1,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=b"\x72" * 32, index=0),
                script_sig=b"",
                sequence=0xFFFFFFFF,
            ),
        ),
        outputs=(TxOut(value=2, script_pubkey=b"\x51"),),
        lock_time=0,
    )
    tx_c = Transaction(
        version=1,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=b"\x73" * 32, index=0),
                script_sig=b"",
                sequence=0xFFFFFFFF,
            ),
        ),
        outputs=(TxOut(value=3, script_pubkey=b"\x51"),),
        lock_time=0,
    )
    pool = Mempool(mempool_max_count=2, max_size_bytes=64 * 1024)
    assert pool.add(tx_a) is True
    assert pool.add(tx_b) is True
    assert pool.add(tx_c) is True
    assert len(pool) == 2
    assert pool.get(transaction_txid(tx_a)) is None
    assert pool.get(transaction_txid(tx_b)) is tx_b
    assert pool.get(transaction_txid(tx_c)) is tx_c


def test_mempool_evict_expired_drops_stale_tx(monkeypatch):
    tx = Transaction(
        version=1,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=b"\x81" * 32, index=0),
                script_sig=b"",
                sequence=0xFFFFFFFF,
            ),
        ),
        outputs=(TxOut(value=9, script_pubkey=b"\x51"),),
        lock_time=0,
    )
    monkeypatch.setattr("pybitnode.mempool.mempool.time.time", lambda: 1_000_000.0)
    pool = Mempool(mempool_max_age_seconds=60, mempool_max_count=500, max_size_bytes=64 * 1024)
    tid = transaction_txid(tx)
    assert pool.add(tx) is True
    assert pool.evict_expired(1_000_030.0) == 0
    assert pool.contains(tid)
    assert pool.evict_expired(1_000_100.0) == 1
    assert not pool.contains(tid)


def test_mempool_evict_over_capacity_method_counts_bytes():
    tx_small = Transaction(
        version=1,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=b"\x91" * 32, index=0),
                script_sig=b"",
                sequence=0xFFFFFFFF,
            ),
        ),
        outputs=(TxOut(value=1, script_pubkey=b""),),
        lock_time=0,
    )
    tx_other = Transaction(
        version=1,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=b"\x92" * 32, index=0),
                script_sig=b"",
                sequence=0xFFFFFFFF,
            ),
        ),
        outputs=(TxOut(value=1, script_pubkey=b""),),
        lock_time=0,
    )
    one_size = len(tx_small.serialize(include_witness=True))
    pool = Mempool(max_size_bytes=one_size, mempool_max_count=0, mempool_max_age_seconds=0)
    assert pool.add(tx_small) is True
    assert len(pool) == 1
    assert pool.evict_over_capacity() == 0
    assert pool.add(tx_other) is True
    assert len(pool) == 1
    assert pool.get(transaction_txid(tx_other)) is tx_other


def _block_header_sid_fixture() -> BlockHeader:
    return BlockHeader(
        version=536870912,
        prev_block=b"\x01" * 32,
        merkle_root=b"\x02" * 32,
        timestamp=1_700_000_000,
        bits=0x1D00FFFF,
        nonce=0,
    )


def test_mempool_iter_pooled_transactions_bip152_short_id_map(tmp_path):
    tracker = ProjectTracker(str(tmp_path / "mempool_bip152_map.db"))
    pool = Mempool(tracker=tracker, max_size_bytes=4 * 1024 * 1024)
    coinbase = Transaction(
        version=2,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=b"\x00" * 32, index=0xFFFFFFFF),
                script_sig=b"\x02" * 5,
                sequence=0xFFFFFFFF,
            ),
        ),
        outputs=(TxOut(value=1000, script_pubkey=b"\x51"),),
        lock_time=0,
    )
    spend = Transaction(
        version=2,
        inputs=(
            TxIn(previous_output=OutPoint(hash=b"\xde" * 32, index=11), script_sig=b"", sequence=0xFFFFFFFF),
        ),
        outputs=(TxOut(value=2000, script_pubkey=b"\x76"),),
        lock_time=0,
    )
    assert pool.add(coinbase) is True
    assert pool.add(spend) is True
    header = _block_header_sid_fixture()
    nonce = 771_771
    sid = bitcoin_short_transaction_id(header, nonce, spend)
    compact = CompactBlockMessage(
        header=header,
        short_id_nonce=nonce,
        shortids=(sid,),
        prefilled=(PrefilledTransaction(index=0, tx=coinbase),),
    )
    pooled = list(pool.iter_pooled_transactions())
    assert coinbase in pooled and spend in pooled
    by_sid = mempool_short_id_transaction_map(compact, pool.iter_pooled_transactions())
    assert by_sid is not None
    assert by_sid[sid] is spend
    assert missing_indexes_for_getblocktxn(compact, by_sid) == ()
    tracker.close()


def test_accept_transaction_skips_orphan_when_defer_orphans_disabled(tmp_path):
    """enable_orphan_pool alone does nothing without defer_orphans (enqueue gate)."""
    tracker = ProjectTracker(str(tmp_path / "orp_defer_off.db"))
    prev = b"\xf5" * 32
    tx_child = Transaction(
        version=2,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=prev, index=0),
                script_sig=b"",
                sequence=0xFFFFFFFF,
            ),
        ),
        outputs=(TxOut(value=1, script_pubkey=b"\x51"),),
        lock_time=0,
    )
    orphans = OrphanPool()
    assert (
        accept_transaction(
            tx_child,
            tracker,
            settings=Settings(enable_orphan_pool=True),
            orphan_pool=orphans,
            defer_orphans=False,
        )
        is False
    )
    assert not orphans.contains(transaction_txid(tx_child))
    tracker.close()


def test_orphan_pool_keeps_partial_pending_until_second_prevout_satisfied():
    orphans = OrphanPool()
    k1 = (b"\xe1" * 32, 0)
    k2 = (b"\xe2" * 32, 1)
    tx_dual = Transaction(
        version=2,
        inputs=(
            TxIn(previous_output=OutPoint(hash=k1[0], index=k1[1]), script_sig=b"", sequence=0xFFFFFFFF),
            TxIn(previous_output=OutPoint(hash=k2[0], index=k2[1]), script_sig=b"", sequence=0xFFFFFFFF),
        ),
        outputs=(TxOut(value=2, script_pubkey=b"\x51"),),
        lock_time=0,
    )
    cid = transaction_txid(tx_dual)
    assert orphans.try_add(tx_dual, {k1, k2})
    assert orphans.take_ready_transactions_for_prevout(k1) == []
    assert orphans.contains(cid)
    snap = orphans.unresolved_prevouts_snapshot(cid)
    assert snap is not None and k2 in snap and k1 not in snap
    assert orphans.take_ready_transactions_for_prevout(k2) == [tx_dual]
    assert not orphans.contains(cid)


def test_orphan_pool_invalid_constructor():
    with pytest.raises(ValueError, match="max_transactions"):
        OrphanPool(max_transactions=0)
    with pytest.raises(ValueError, match="max_size_bytes"):
        OrphanPool(max_transactions=10, max_size_bytes=0)


def test_accept_transaction_skips_orphan_without_settings_toggle(tmp_path):
    tracker = ProjectTracker(str(tmp_path / "orp_no.cfg.db"))
    prev = b"\xf0" * 32
    tx_child = Transaction(
        version=2,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=prev, index=0),
                script_sig=b"",
                sequence=0xFFFFFFFF,
            ),
        ),
        outputs=(TxOut(value=1, script_pubkey=b"\x51"),),
        lock_time=0,
    )
    orphans = OrphanPool()
    assert (
        accept_transaction(
            tx_child,
            tracker,
            settings=Settings(enable_orphan_pool=False),
            orphan_pool=orphans,
            defer_orphans=True,
        )
        is False
    )
    assert not orphans.contains(transaction_txid(tx_child))
    tracker.close()


def test_accept_transaction_queues_orphans_when_enabled(tmp_path):
    tracker = ProjectTracker(str(tmp_path / "orp_yes.db"))
    prev = b"\xf1" * 32
    tx_child = Transaction(
        version=2,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=prev, index=0),
                script_sig=b"",
                sequence=0xFFFFFFFF,
            ),
        ),
        outputs=(TxOut(value=1, script_pubkey=b"\x51"),),
        lock_time=0,
    )
    orphans = OrphanPool()
    policies = Settings(enable_orphan_pool=True)
    accepted = accept_transaction(
        tx_child,
        tracker,
        settings=policies,
        orphan_pool=orphans,
        defer_orphans=True,
    )
    assert accepted is False
    cid = transaction_txid(tx_child)
    assert orphans.contains(cid)
    assert orphans.remove(cid)
    tracker.close()


def test_mempool_promotes_orphan_when_parent_arrives_first_in_orphan_then_mempool(tmp_path):
    tracker = ProjectTracker(str(tmp_path / "orp_chain.db"))
    prev_a = b"\xf3" * 32
    parent_amt = 400_000
    parent_out_to_child = 300_000
    child_remainder = 290_000
    pubkey = _test_pubkey_sec1()
    _fund_p2pkh_utxo(tracker=tracker, prevout=prev_a, pubkey=pubkey, value=parent_amt)

    parent, child = _signed_parent_child_chain(
        prev_coin=prev_a,
        coin_amt=parent_amt,
        parent_to_child_value=parent_out_to_child,
        child_remainder_value=child_remainder,
        private_key=1,
        pubkey=pubkey,
    )
    orphans = OrphanPool()
    policies = Settings(enable_orphan_pool=True)
    mempool = Mempool(tracker=tracker, orphan_pool=orphans)

    assert (
        accept_transaction(
            child,
            tracker,
            settings=policies,
            orphan_pool=orphans,
            defer_orphans=True,
            mempool_claimed_prevouts=mempool.claimed_prevouts_frozen(),
        )
        is False
    )
    assert mempool.claimed_prevouts_frozen() == frozenset()
    assert orphans.contains(transaction_txid(child))

    assert accept_transaction(
        parent,
        tracker,
        settings=policies,
        mempool_claimed_prevouts=mempool.claimed_prevouts_frozen(),
    )

    assert mempool.add(parent)

    pid = transaction_txid(parent)
    cid = transaction_txid(child)

    assert len(orphans) == 0
    assert not orphans.contains(cid)
    assert mempool.get(pid) is parent
    assert mempool.get(cid) is child

    tracker.close()


def test_orphan_pool_respects_transaction_limit(tmp_path):
    tracker = ProjectTracker(str(tmp_path / "orp_limit.db"))
    policies = Settings(enable_orphan_pool=True)
    orphans = OrphanPool(max_transactions=1, max_size_bytes=256 * 1024)

    def _solo_tx(which: bytes) -> Transaction:
        return Transaction(
            version=2,
            inputs=(
                TxIn(previous_output=OutPoint(hash=which, index=0), script_sig=b"", sequence=0xFFFFFFFF),
            ),
            outputs=(TxOut(value=1, script_pubkey=b"\x51"),),
            lock_time=0,
        )

    t1 = _solo_tx(b"\xfc" * 32)
    t2 = _solo_tx(b"\xfd" * 32)
    assert (
        accept_transaction(
            t1,
            tracker,
            settings=policies,
            orphan_pool=orphans,
            defer_orphans=True,
        )
        is False
    )
    assert orphans.contains(transaction_txid(t1))
    assert (
        accept_transaction(
            t2,
            tracker,
            settings=policies,
            orphan_pool=orphans,
            defer_orphans=True,
        )
        is False
    )
    assert orphans.contains(transaction_txid(t1))
    assert not orphans.contains(transaction_txid(t2))

    tracker.close()


def test_collect_missing_prevouts_finds_utxo_via_overlay_only(tmp_path):
    tracker = ProjectTracker(str(tmp_path / "ovl.db"))
    parent = Transaction(
        version=2,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=b"\xea" * 32, index=2),
                script_sig=b"",
                sequence=0xFFFFFFFF,
            ),
        ),
        outputs=(TxOut(value=777, script_pubkey=b"\xaa\xbb"), TxOut(value=333, script_pubkey=b"\xcc")),
        lock_time=0,
    )
    overlay_tid = transaction_txid(parent)

    spender = Transaction(
        version=2,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=overlay_tid, index=1),
                script_sig=b"",
                sequence=0xFFFFFFFF,
            ),
        ),
        outputs=(TxOut(value=222, script_pubkey=b"\x51"),),
        lock_time=0,
    )

    assert collect_missing_prevouts(spender, tracker, mempool_utxo_overlay=None) == {(overlay_tid, 1)}

    row = {(overlay_tid, 1): {"value": parent.outputs[1].value, "script_pubkey": parent.outputs[1].script_pubkey.hex()}}

    resolved = collect_missing_prevouts(spender, tracker, mempool_utxo_overlay=row)
    assert resolved == set()

    tracker.close()
