from __future__ import annotations

import pytest

from pybitnode.chain.genesis import TESTNET4_GENESIS
from pybitnode.chain.params import TESTNET4
from pybitnode.consensus.block import Block
from pybitnode.consensus.merkle import block_merkle_root, merkle_root
from pybitnode.messages.transaction import Transaction
from pybitnode.storage.blocks import BlockStore
from pybitnode.sync.validate import BlockValidationError, validate_block

from tests.blocks_fixture import FIXTURE_BLOCKS_DIR


@pytest.fixture
def block1_payload() -> bytes:
    store = BlockStore(FIXTURE_BLOCKS_DIR, TESTNET4.magic)
    return store.read("blk00000.dat", 0, 258)


def test_transaction_roundtrip_coinbase(block1_payload: bytes):
    block = Block.deserialize(block1_payload)
    assert len(block.transactions) == 1
    coinbase = block.transactions[0]
    assert coinbase.is_coinbase
    restored, offset = Transaction.deserialize(block1_payload, 81)
    assert offset == len(block1_payload)
    assert restored == coinbase


def test_block1_merkle_root_matches_header(block1_payload: bytes):
    block = Block.deserialize(block1_payload)
    computed = block_merkle_root(list(block.transactions))
    assert computed == block.header.merkle_root


def test_block1_validate(block1_payload: bytes):
    block = validate_block(
        block1_payload,
        expected_prev=TESTNET4_GENESIS.block_hash(),
        expected_hash=bytes.fromhex("0000000012982b6d5f621229286b880e909984df669c2afabb102ce311b13f28")[::-1],
    )
    assert block.header.block_hash_hex() == "0000000012982b6d5f621229286b880e909984df669c2afabb102ce311b13f28"
    assert block.transactions[0].outputs[0].value == 50 * 100_000_000


def test_merkle_root_duplicates_last_hash():
    left = b"\x01" * 32
    right = b"\x02" * 32
    assert merkle_root([left, right]) != merkle_root([left])
    assert merkle_root([left]) == left


def test_validate_block_rejects_bad_merkle(block1_payload: bytes):
    corrupted = bytearray(block1_payload)
    corrupted[40] ^= 0xFF
    with pytest.raises(BlockValidationError, match="merkle root mismatch|proof of work failed|prev_block mismatch"):
        validate_block(
            bytes(corrupted),
            expected_prev=TESTNET4_GENESIS.block_hash(),
        )


def test_validate_stored_blocks_from_tracker(tmp_path):
    from pybitnode.db.tracker import ProjectTracker
    from pybitnode.sync.blocks import validate_stored_blocks
    from pybitnode.sync.headers import ensure_genesis

    tracker = ProjectTracker(tmp_path / "validate.db")
    ensure_genesis(tracker, TESTNET4)
    store = BlockStore(FIXTURE_BLOCKS_DIR, TESTNET4.magic)
    payload = store.read("blk00000.dat", 0, 258)
    file_name, offset, size = BlockStore(tmp_path / "blocks", TESTNET4.magic).write(payload)
    tracker.record_header(
        1,
        "0000000012982b6d5f621229286b880e909984df669c2afabb102ce311b13f28",
        TESTNET4.genesis_hash,
        1714777861,
    )
    tracker.record_block(
        1,
        "0000000012982b6d5f621229286b880e909984df669c2afabb102ce311b13f28",
        file_name,
        offset,
        size,
    )
    validated = validate_stored_blocks(tracker, BlockStore(tmp_path / "blocks", TESTNET4.magic))
    assert validated == 1
    tracker.close()


def test_validate_stored_blocks_1_through_5():
    store = BlockStore(FIXTURE_BLOCKS_DIR, TESTNET4.magic)
    offsets = [0, 266, 532, 798, 1064]
    sizes = [258] * 5
    hashes = [
        "0000000012982b6d5f621229286b880e909984df669c2afabb102ce311b13f28",
        "000000001fed1a914651afc36574003c5300cac5df738c3976f28d54f7096253",
        "000000008ddb4258595f9d8079a0b83fdc2816c9e3511acc739c16f5bce14e56",
        "000000008f5794caa45c418a0184303e848e9d6756e4d77234c9aada983b4265",
        "00000000ccefd2182ad4bb311c866233d32aae0a85f9568588ffd8e0432b7355",
    ]
    prev = TESTNET4_GENESIS.block_hash()
    for offset, size, hash_hex in zip(offsets, sizes, hashes, strict=True):
        payload = store.read("blk00000.dat", offset, size)
        block = validate_block(payload, expected_prev=prev, expected_hash=bytes.fromhex(hash_hex)[::-1])
        prev = block.header.block_hash()
