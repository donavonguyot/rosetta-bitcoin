from __future__ import annotations

from pybitnode.chain.genesis import genesis_header_for
from pybitnode.chain.params import ChainParams
from pybitnode.db.tracker import ProjectTracker
from pybitnode.messages.headers import HEADER_SIZE, BlockHeader, HeadersMessage
from pybitnode.messages.inventory import GetHeadersMessage
from pybitnode.storage.blocks import BlockStore

HEADER_BATCH_MAX = 2000


def find_common_fork_height(tracker: ProjectTracker, locator_hashes: list[bytes]) -> int:
    """Return height of newest header in locator that appears on our best header chain."""
    for internal_hash in locator_hashes:
        display = internal_hash[::-1].hex()
        height = tracker.lookup_header_height(display)
        if height is not None:
            return height
    return -1


def resolve_header_record(
    tracker: ProjectTracker,
    chain: ChainParams,
    height: int,
    block_store: BlockStore | None,
) -> BlockHeader | None:
    row = tracker.get_header(height)
    if row is None:
        return None
    stored_hash_hex = row["block_hash"]

    serialized = row.get("header_serialized_hex") or ""
    if serialized:
        blob = bytes.fromhex(serialized)
        if len(blob) != HEADER_SIZE:
            return None
        header_obj, consumed = BlockHeader.deserialize(blob, 0)
        if consumed != HEADER_SIZE:
            return None
        if header_obj.block_hash_hex() != stored_hash_hex:
            return None
        return header_obj

    if height == 0:
        genesis = genesis_header_for(chain.name)
        if stored_hash_hex == genesis.block_hash_hex():
            return genesis
        return None

    block_row = tracker.get_block(height)
    if block_store is None or block_row is None:
        return None
    try:
        raw = block_store.read(
            block_row["file_name"],
            int(block_row["file_offset"]),
            int(block_row["size"]),
        )
    except (OSError, ValueError):
        return None
    header_obj, consumed = BlockHeader.deserialize(raw, 0)
    if consumed != HEADER_SIZE:
        return None
    if header_obj.block_hash_hex() != stored_hash_hex:
        return None
    return header_obj


def build_headers_response(
    tracker: ProjectTracker,
    chain: ChainParams,
    message: GetHeadersMessage,
    block_store: BlockStore | None = None,
) -> HeadersMessage:
    """Locate fork from locator hashes and attach up to 2000 succeeding headers."""
    zero_stop = message.hash_stop == b"\x00" * 32

    # bitcoin/test/functional/p2p_sendheaders.py — null locator + hash_stop probes a single header.
    if not message.locator_hashes:
        if zero_stop:
            return HeadersMessage(headers=tuple())
        stop_hex = message.hash_stop[::-1].hex()
        stop_h = tracker.lookup_header_height(stop_hex)
        if stop_h is None:
            return HeadersMessage(headers=tuple())
        resolved_stop = resolve_header_record(tracker, chain, stop_h, block_store)
        if resolved_stop is None or resolved_stop.block_hash() != message.hash_stop:
            return HeadersMessage(headers=tuple())
        return HeadersMessage(headers=(resolved_stop,))

    fork_height = find_common_fork_height(tracker, message.locator_hashes)
    start = max(fork_height + 1, 0)
    tip = tracker.max_header_height()
    explicit_stop_hash = None if zero_stop else message.hash_stop
    if explicit_stop_hash is not None:
        stop_height = tracker.lookup_header_height(explicit_stop_hash[::-1].hex())
        if stop_height is not None and stop_height < start:
            return HeadersMessage(headers=tuple())

    gathered: list[BlockHeader] = []
    for height in range(start, tip + 1):
        if len(gathered) >= HEADER_BATCH_MAX:
            break
        resolved = resolve_header_record(tracker, chain, height, block_store)
        if resolved is None:
            break
        gathered.append(resolved)
        if explicit_stop_hash is not None and resolved.block_hash() == explicit_stop_hash:
            break

    return HeadersMessage(headers=tuple(gathered))
