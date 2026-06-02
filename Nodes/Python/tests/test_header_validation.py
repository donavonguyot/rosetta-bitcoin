from __future__ import annotations

import pytest

from pybitnode.chain.genesis import TESTNET4_GENESIS
from pybitnode.chain.params import TESTNET4
from pybitnode.chainstate.tracker import ProjectTracker
from pybitnode.messages.headers import BlockHeader, HeadersMessage
from pybitnode.sync.headers import ensure_genesis, persist_headers
from pybitnode.sync.validate import HeaderValidationError, header_meets_target, validate_header


def test_testnet4_genesis_hash_matches_core():
    assert (
        TESTNET4_GENESIS.block_hash_hex()
        == "00000000da84f2bafbbc53dee25a72ae507ff4914b867c565be350b0da8bf043"
    )
    assert TESTNET4.genesis_hash == TESTNET4_GENESIS.block_hash_hex()


def test_genesis_meets_pow_target():
    assert header_meets_target(TESTNET4_GENESIS)


def test_validate_genesis_prev_is_all_zeros():
    validate_header(TESTNET4_GENESIS, expected_prev=b"\x00" * 32)


def test_validate_rejects_bad_prev():
    header = BlockHeader(
        version=1,
        prev_block=b"\x01" * 32,
        merkle_root=b"\x02" * 32,
        timestamp=1714777861,
        bits=0x1D00FFFF,
        nonce=1,
    )
    with pytest.raises(HeaderValidationError, match="prev_block mismatch"):
        validate_header(header, expected_prev=TESTNET4_GENESIS.block_hash())


def test_validate_rejects_bad_pow():
    header = BlockHeader(
        version=1,
        prev_block=TESTNET4_GENESIS.block_hash(),
        merkle_root=b"\x02" * 32,
        timestamp=1714777861,
        bits=0x1D00FFFF,
        nonce=1,
    )
    with pytest.raises(HeaderValidationError, match="proof of work failed"):
        validate_header(header, expected_prev=TESTNET4_GENESIS.block_hash())


def test_ensure_genesis_seeds_height_zero(tmp_path):
    tracker = ProjectTracker(tmp_path / "genesis-chainstate")
    genesis = ensure_genesis(tracker, TESTNET4)
    assert tracker.get_header_hash(0) == genesis.block_hash_hex()
    assert tracker.header_count() == 1
    state = tracker.get_sync_state("testnet4")
    assert state["best_height"] == 0
    tracker.close()


def test_persist_headers_rejects_unlinked_header(tmp_path):
    tracker = ProjectTracker(tmp_path / "reject-chainstate")
    bad = BlockHeader(
        version=1,
        prev_block=b"\xff" * 32,
        merkle_root=b"\x02" * 32,
        timestamp=1714777861,
        bits=0x1D00FFFF,
        nonce=999999999,
    )
    height, _, stored = persist_headers(tracker, TESTNET4, HeadersMessage(headers=(bad,)))
    assert stored == 0
    assert height == 0
    assert tracker.header_count() == 1  # genesis only
    tracker.close()
