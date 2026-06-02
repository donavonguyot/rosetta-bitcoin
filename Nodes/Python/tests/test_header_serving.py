from __future__ import annotations

import struct

import pytest

from pybitnode.chain.genesis import TESTNET4_GENESIS
from pybitnode.chain.params import TESTNET4
from pybitnode.chainstate.tracker import ProjectTracker
from pybitnode.messages.headers import BlockHeader
from pybitnode.messages.inventory import GetHeadersMessage
from pybitnode.p2p.header_serving import (
    HEADER_BATCH_MAX,
    build_headers_response,
    find_common_fork_height,
    resolve_header_record,
)
from pybitnode.storage.blocks import BlockStore
from pybitnode.sync.headers import ensure_genesis
from pybitnode.wire.serialize import write_varint

from tests.blocks_fixture import FIXTURE_BLOCKS_DIR


BLOCK1_HASH_HEX = "0000000012982b6d5f621229286b880e909984df669c2afabb102ce311b13f28"


def test_getheaders_message_roundtrip():
    locator = [b"\xaa" * 32, TESTNET4_GENESIS.block_hash()]
    msg = GetHeadersMessage(version=70016, locator_hashes=locator, hash_stop=b"\x00" * 32)
    raw = msg.serialize()
    decoded = GetHeadersMessage.deserialize(raw)
    assert decoded.version == msg.version
    assert decoded.locator_hashes == msg.locator_hashes
    assert decoded.hash_stop == msg.hash_stop


def test_getheaders_deserialize_truncated_hash_stop_rejects():
    bad = struct.pack("<i", 70016) + write_varint(0) + b"\x00" * 31
    with pytest.raises(ValueError, match="invalid getheaders"):
        GetHeadersMessage.deserialize(bad)


def test_getheaders_deserialize_trailing_bytes_rejects():
    ok = GetHeadersMessage(
        version=70016,
        locator_hashes=[b"\xaa" * 32],
        hash_stop=b"\x00" * 32,
    ).serialize()
    with pytest.raises(ValueError, match="invalid getheaders"):
        GetHeadersMessage.deserialize(ok + b"\xff")


def test_find_common_fork_height_skips_unknown_then_hits_genesis(tmp_path):
    tracker = ProjectTracker(tmp_path / "fork-chainstate")
    ensure_genesis(tracker, TESTNET4)
    g = TESTNET4_GENESIS.block_hash()
    assert find_common_fork_height(tracker, [b"\xee" * 32, g]) == 0
    tracker.close()


def test_find_common_fork_height_returns_minus_one_when_no_locator_matches(tmp_path):
    tracker = ProjectTracker(tmp_path / "fork_no_match-chainstate")
    ensure_genesis(tracker, TESTNET4)
    assert find_common_fork_height(tracker, [b"\xcc" * 32, b"\xdd" * 32]) == -1
    tracker.close()


def test_build_headers_response_empty_chain_unknown_locator_returns_no_headers(tmp_path):
    """No headers row: fork unresolved uses start=0 but height 0 missing -> empty reply."""
    tracker = ProjectTracker(tmp_path / "empty-chainstate")
    gh = GetHeadersMessage(version=70016, locator_hashes=[b"\xaa" * 32], hash_stop=b"\x00" * 32)
    reply = build_headers_response(tracker, TESTNET4, gh, None)
    assert reply.headers == ()
    tracker.close()


def test_build_headers_response_genesis_only_unknown_locator_restarts_from_genesis(tmp_path):
    """When no locator hash is on our chain, fork_height is -1 so we start at height 0."""
    tracker = ProjectTracker(tmp_path / "gen_only-chainstate")
    genesis = ensure_genesis(tracker, TESTNET4)
    gh = GetHeadersMessage(version=70016, locator_hashes=[b"\xbb" * 32], hash_stop=b"\x00" * 32)
    reply = build_headers_response(tracker, TESTNET4, gh, None)
    assert reply.headers == (genesis,)
    tracker.close()


def test_build_headers_response_returns_successors_after_locator(tmp_path):
    tracker = ProjectTracker(tmp_path / "chs-chainstate")
    g = ensure_genesis(tracker, TESTNET4)
    h1 = BlockHeader(
        version=g.version,
        prev_block=g.block_hash(),
        merkle_root=b"\x12" * 32,
        timestamp=g.timestamp + 600,
        bits=g.bits,
        nonce=g.nonce + 1,
    )
    tracker.record_header(
        1,
        h1.block_hash_hex(),
        g.block_hash_hex(),
        h1.timestamp,
        header_serialized_hex=h1.serialize().hex(),
    )
    gh = GetHeadersMessage(
        version=70016,
        locator_hashes=[g.block_hash()],
        hash_stop=b"\x00" * 32,
    )
    reply = build_headers_response(tracker, TESTNET4, gh, None)
    assert tuple(reply.headers) == (h1,)

    gh2 = GetHeadersMessage(version=70016, locator_hashes=[h1.block_hash()], hash_stop=b"\x00" * 32)
    assert len(build_headers_response(tracker, TESTNET4, gh2, None).headers) == 0

    gh3 = GetHeadersMessage(
        version=70016,
        locator_hashes=[g.block_hash()],
        hash_stop=h1.block_hash(),
    )
    trunc = build_headers_response(tracker, TESTNET4, gh3, None)
    assert len(trunc.headers) == 1
    assert trunc.headers[0] == h1
    tracker.close()


def test_build_headers_response_hash_stop_truncates_after_second_header(tmp_path):
    tracker = ProjectTracker(tmp_path / "stop-chainstate")
    g = ensure_genesis(tracker, TESTNET4)
    h1 = BlockHeader(
        version=g.version,
        prev_block=g.block_hash(),
        merkle_root=b"\x12" * 32,
        timestamp=g.timestamp + 600,
        bits=g.bits,
        nonce=g.nonce + 1,
    )
    h2 = BlockHeader(
        version=h1.version,
        prev_block=h1.block_hash(),
        merkle_root=b"\x34" * 32,
        timestamp=h1.timestamp + 600,
        bits=h1.bits,
        nonce=h1.nonce + 1,
    )
    tracker.record_header(
        1,
        h1.block_hash_hex(),
        g.block_hash_hex(),
        h1.timestamp,
        header_serialized_hex=h1.serialize().hex(),
    )
    tracker.record_header(
        2,
        h2.block_hash_hex(),
        h1.block_hash_hex(),
        h2.timestamp,
        header_serialized_hex=h2.serialize().hex(),
    )

    gh_stop_h1 = GetHeadersMessage(
        version=70016,
        locator_hashes=[g.block_hash()],
        hash_stop=h1.block_hash(),
    )
    assert tuple(build_headers_response(tracker, TESTNET4, gh_stop_h1, None).headers) == (h1,)

    gh_stop_h2 = GetHeadersMessage(
        version=70016,
        locator_hashes=[g.block_hash()],
        hash_stop=h2.block_hash(),
    )
    assert tuple(build_headers_response(tracker, TESTNET4, gh_stop_h2, None).headers) == (h1, h2)
    tracker.close()


def test_build_headers_response_truncates_at_2000_headers(tmp_path):
    tracker = ProjectTracker(tmp_path / "batch-chainstate")
    tip = ensure_genesis(tracker, TESTNET4)
    prev = tip.block_hash()
    prev_hex = tip.block_hash_hex()
    for height in range(1, HEADER_BATCH_MAX + 2):
        hdr = BlockHeader(
            version=tip.version,
            prev_block=prev,
            merkle_root=height.to_bytes(32, "big"),
            timestamp=tip.timestamp + 600 * height,
            bits=tip.bits,
            nonce=tip.nonce + height,
        )
        tracker.record_header(
            height,
            hdr.block_hash_hex(),
            prev_hex,
            hdr.timestamp,
            header_serialized_hex=hdr.serialize().hex(),
        )
        prev = hdr.block_hash()
        prev_hex = hdr.block_hash_hex()

    gh = GetHeadersMessage(
        version=70016,
        locator_hashes=[TESTNET4_GENESIS.block_hash()],
        hash_stop=b"\x00" * 32,
    )
    reply = build_headers_response(tracker, TESTNET4, gh, None)
    assert len(reply.headers) == HEADER_BATCH_MAX
    assert reply.headers[0].prev_block == TESTNET4_GENESIS.block_hash()
    tracker.close()

def test_build_headers_null_locator_zero_hash_stop_returns_empty(tmp_path):
    tracker = ProjectTracker(tmp_path / "null_loc0-chainstate")
    ensure_genesis(tracker, TESTNET4)
    gh = GetHeadersMessage(version=70016, locator_hashes=[], hash_stop=b"\x00" * 32)
    reply = build_headers_response(tracker, TESTNET4, gh, None)
    assert reply.headers == ()
    tracker.close()


def test_build_headers_null_locator_valid_hash_stop_returns_single_header(tmp_path):
    tracker = ProjectTracker(tmp_path / "null_loc_ok-chainstate")
    genesis = ensure_genesis(tracker, TESTNET4)
    gh = GetHeadersMessage(version=70016, locator_hashes=[], hash_stop=genesis.block_hash())
    reply = build_headers_response(tracker, TESTNET4, gh, None)
    assert reply.headers == (genesis,)
    tracker.close()


def test_build_headers_null_locator_unknown_hash_stop_returns_empty(tmp_path):
    tracker = ProjectTracker(tmp_path / "null_loc_bad-chainstate")
    ensure_genesis(tracker, TESTNET4)
    unknown = b"\x22" * 32
    gh = GetHeadersMessage(version=70016, locator_hashes=[], hash_stop=unknown)
    reply = build_headers_response(tracker, TESTNET4, gh, None)
    assert reply.headers == ()
    tracker.close()


def test_build_headers_hash_stop_before_fork_start_returns_empty(tmp_path):
    tracker = ProjectTracker(tmp_path / "stop_before-chainstate")
    g = ensure_genesis(tracker, TESTNET4)
    h1 = BlockHeader(
        version=g.version,
        prev_block=g.block_hash(),
        merkle_root=b"\x12" * 32,
        timestamp=g.timestamp + 600,
        bits=g.bits,
        nonce=g.nonce + 1,
    )
    tracker.record_header(
        1,
        h1.block_hash_hex(),
        g.block_hash_hex(),
        h1.timestamp,
        header_serialized_hex=h1.serialize().hex(),
    )
    gh = GetHeadersMessage(
        version=70016,
        locator_hashes=[h1.block_hash()],
        hash_stop=g.block_hash(),
    )
    assert build_headers_response(tracker, TESTNET4, gh, None).headers == ()
    tracker.close()


def test_build_headers_stops_at_missing_intermediate_height(tmp_path):
    tracker = ProjectTracker(tmp_path / "hole-chainstate")
    g = ensure_genesis(tracker, TESTNET4)
    h1 = BlockHeader(
        version=g.version,
        prev_block=g.block_hash(),
        merkle_root=b"\xab" * 32,
        timestamp=g.timestamp + 600,
        bits=g.bits,
        nonce=g.nonce + 1,
    )
    h2 = BlockHeader(
        version=h1.version,
        prev_block=h1.block_hash(),
        merkle_root=b"\xcd" * 32,
        timestamp=h1.timestamp + 600,
        bits=h1.bits,
        nonce=h1.nonce + 1,
    )
    tracker.record_header(
        1,
        h1.block_hash_hex(),
        g.block_hash_hex(),
        h1.timestamp,
        header_serialized_hex=h1.serialize().hex(),
    )
    tracker.record_header(
        3,
        h2.block_hash_hex(),
        h1.block_hash_hex(),
        h2.timestamp,
        header_serialized_hex=h2.serialize().hex(),
    )
    gh = GetHeadersMessage(version=70016, locator_hashes=[g.block_hash()], hash_stop=b"\x00" * 32)
    reply = build_headers_response(tracker, TESTNET4, gh, None)
    assert tuple(reply.headers) == (h1,)
    tracker.close()



def test_resolve_header_from_block_store_when_serialized_missing(tmp_path):
    """Height > 0 without header_serialized_hex: read 80-byte header from flat file."""
    tracker = ProjectTracker(tmp_path / "blk_hdr-chainstate")
    ensure_genesis(tracker, TESTNET4)
    fixture_store = BlockStore(FIXTURE_BLOCKS_DIR, TESTNET4.magic)
    payload = fixture_store.read("blk00000.dat", 0, 258)
    local = BlockStore(tmp_path / "blocks", TESTNET4.magic)
    file_name, offset, size = local.write(payload)

    tracker.record_header(
        1,
        BLOCK1_HASH_HEX,
        TESTNET4.genesis_hash,
        1714777861,
    )
    tracker.record_block(1, BLOCK1_HASH_HEX, file_name, offset, size)

    hdr = resolve_header_record(tracker, TESTNET4, 1, local)
    assert hdr is not None
    assert hdr.block_hash_hex() == BLOCK1_HASH_HEX

    gh = GetHeadersMessage(
        version=70016,
        locator_hashes=[TESTNET4_GENESIS.block_hash()],
        hash_stop=b"\x00" * 32,
    )
    reply = build_headers_response(tracker, TESTNET4, gh, local)
    assert tuple(reply.headers) == (hdr,)

    assert resolve_header_record(tracker, TESTNET4, 1, None) is None
    tracker.close()


def test_header_batch_limit_constants():
    """Guardrail aligned with Bitcoin getheaders responses."""
    assert HEADER_BATCH_MAX == 2000
