from __future__ import annotations

import asyncio
import logging

from pybitnode.chain.params import ChainParams
from pybitnode.consensus.connect import ConnectBlockError, connect_block
from pybitnode.chainstate.tracker import ProjectTracker
from pybitnode.p2p.peer import PeerConnection, broadcast_witness_block_inv
from pybitnode.storage.blocks import BlockStore
from pybitnode.sync.validate import BlockValidationError, validate_block

logger = logging.getLogger(__name__)


def _expected_prev_hash(tracker: ProjectTracker, height: int) -> bytes | None:
    prev_hex = tracker.get_header_hash(height - 1)
    if not prev_hex:
        return None
    return bytes.fromhex(prev_hex)[::-1]


async def request_block_from_peers(
    peers: list[PeerConnection],
    block_hash: bytes,
) -> tuple[bytes, PeerConnection] | None:
    for peer in peers:
        if not peer.is_connected:
            continue
        try:
            payload = await peer.request_block(block_hash)
        except (TimeoutError, ConnectionError, ValueError):
            continue
        if payload is not None:
            return payload, peer
    return None


_PARALLEL_CAP_ID = "blocks.parallel"


async def request_block_from_peers_parallel(
    peers: list[PeerConnection],
    block_hash: bytes,
) -> tuple[bytes, PeerConnection] | None:
    """Ask every connected peer for the same block; first successful response wins.

    Tasks for slower peers are cancelled once a usable payload arrives.
    """
    eligible = [p for p in peers if p.is_connected]
    if not eligible:
        return None

    async def try_peer(peer: PeerConnection) -> tuple[bytes, PeerConnection] | None:
        try:
            payload = await peer.request_block(block_hash)
        except (TimeoutError, ConnectionError, ValueError):
            return None
        if payload is not None:
            return payload, peer
        return None

    tasks = [asyncio.create_task(try_peer(p)) for p in eligible]
    try:
        for fut in asyncio.as_completed(tasks):
            outcome = await fut
            if outcome is not None:
                return outcome
        return None
    finally:
        for t in tasks:
            if not t.done():
                t.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)


def _maybe_mark_parallel_sync(tracker: ProjectTracker, *, parallel_downloads: int) -> None:
    if parallel_downloads <= 0:
        return
    if tracker.wire_capability_map().get(_PARALLEL_CAP_ID, 0) == 1:
        return
    tracker.mark_wire_capability(
        _PARALLEL_CAP_ID,
        implemented=True,
        verified_by="code",
        notes="prototype parallel height + peer races",
    )


async def sync_blocks_batch(
    peers: list[PeerConnection],
    tracker: ProjectTracker,
    chain: ChainParams,
    block_store: BlockStore,
    *,
    batch_size: int,
    max_blocks: int,
    parallel_downloads: int = 0,
) -> int:
    if not peers:
        return 0

    limit = batch_size if max_blocks == 0 else min(batch_size, max_blocks)
    missing = tracker.list_missing_block_heights(limit=limit)
    if not missing:
        tracker.upsert_sync_state(chain.name, sync_status="blocks_current")
        return 0

    tracker.upsert_sync_state(chain.name, sync_status="blocks_syncing")
    downloaded = 0

    if parallel_downloads > 0:
        work: list[tuple[int, str, bytes, bytes]] = []
        for height in missing:
            if max_blocks and len(work) >= max_blocks:
                break
            block_hash_hex = tracker.get_header_hash(height)
            if not block_hash_hex:
                continue
            block_hash_rev = bytes.fromhex(block_hash_hex)[::-1]
            expected_prev = _expected_prev_hash(tracker, height)
            if expected_prev is None:
                continue
            work.append((height, block_hash_hex, block_hash_rev, expected_prev))

        if work:
            _maybe_mark_parallel_sync(tracker, parallel_downloads=parallel_downloads)

            sem = asyncio.Semaphore(parallel_downloads)

            async def _fetch_one(item: tuple[int, str, bytes, bytes]):
                ht, _, blk_hash, _ = item
                async with sem:
                    res = await request_block_from_peers_parallel(peers, blk_hash)
                return ht, res

            rows = await asyncio.gather(*(_fetch_one(w) for w in work))
            fetched = {ht: res for ht, res in rows}

            for height, block_hash_hex, block_hash_rev, expected_prev in work:
                outcome = fetched[height]
                if outcome is None:
                    tracker.log_event(
                        "sync",
                        "Block unavailable from peers",
                        level="warning",
                        details={"height": height, "block_hash": block_hash_hex},
                    )
                    break
                payload, _peer = outcome
                try:
                    connect_block(
                        tracker,
                        payload,
                        height=height,
                        expected_prev=expected_prev,
                        expected_hash=block_hash_rev,
                        chain_name=chain.name,
                    )
                    await broadcast_witness_block_inv(peers, block_hash_rev, tracker)
                except ConnectBlockError as exc:
                    tracker.log_event(
                        "sync",
                        "Rejected invalid block",
                        level="warning",
                        details={"height": height, "error": str(exc)},
                    )
                    tracker.upsert_sync_state(chain.name, sync_status="blocks_blocked")
                    break
                file_name, offset, size = block_store.write(payload)
                tracker.record_block(height, block_hash_hex, file_name, offset, size)
                downloaded += 1
                if downloaded == 1 or downloaded % 32 == 0:
                    logger.info(
                        "Block sync progress: height=%s batch_downloaded=%s utxos=%s",
                        height,
                        downloaded,
                        tracker.utxo_count(),
                    )

    else:
        for height in missing:
            if max_blocks and downloaded >= max_blocks:
                break
            block_hash_hex = tracker.get_header_hash(height)
            if not block_hash_hex:
                continue
            block_hash = bytes.fromhex(block_hash_hex)[::-1]
            expected_prev = _expected_prev_hash(tracker, height)
            if expected_prev is None:
                continue
            result = await request_block_from_peers(peers, block_hash)
            if result is None:
                tracker.log_event(
                    "sync",
                    "Block unavailable from peers",
                    level="warning",
                    details={"height": height, "block_hash": block_hash_hex},
                )
                break
            payload, _peer = result
            try:
                connect_block(
                    tracker,
                    payload,
                    height=height,
                    expected_prev=expected_prev,
                    expected_hash=block_hash,
                    chain_name=chain.name,
                )
                await broadcast_witness_block_inv(peers, block_hash, tracker)
            except ConnectBlockError as exc:
                tracker.log_event(
                    "sync",
                    "Rejected invalid block",
                    level="warning",
                    details={"height": height, "error": str(exc)},
                )
                tracker.upsert_sync_state(chain.name, sync_status="blocks_blocked")
                break
            file_name, offset, size = block_store.write(payload)
            tracker.record_block(height, block_hash_hex, file_name, offset, size)
            downloaded += 1
            if downloaded == 1 or downloaded % 32 == 0:
                logger.info(
                    "Block sync progress: height=%s batch_downloaded=%s utxos=%s",
                    height,
                    downloaded,
                    tracker.utxo_count(),
                )

    if downloaded:
        tracker.log_event(
            "sync",
            f"Downloaded {downloaded} blocks",
            details={"from_height": missing[0], "to_height": missing[min(downloaded, len(missing)) - 1]},
        )

    if not tracker.list_missing_block_heights(limit=1):
        tracker.upsert_sync_state(chain.name, sync_status="blocks_current")
    return downloaded


async def sync_blocks_to_tip(
    peers: list[PeerConnection],
    tracker: ProjectTracker,
    chain: ChainParams,
    block_store: BlockStore,
    *,
    batch_size: int = 32,
    max_blocks: int = 0,
    target_height: int = 0,
    parallel_downloads: int = 0,
) -> int:
    total = 0
    while True:
        validated = tracker.get_validated_height(chain.name)
        if target_height and validated >= target_height:
            break
        remaining = max_blocks - total if max_blocks else batch_size
        if max_blocks and remaining <= 0:
            break
        batch_limit = min(batch_size, remaining) if max_blocks else batch_size
        if target_height:
            heights_left = target_height - validated
            if heights_left <= 0:
                break
            batch_limit = min(batch_limit, heights_left)
        downloaded = await sync_blocks_batch(
            peers,
            tracker,
            chain,
            block_store,
            batch_size=batch_limit,
            max_blocks=batch_limit if max_blocks else 0,
            parallel_downloads=parallel_downloads,
        )
        if downloaded == 0:
            break
        total += downloaded
    return total


def repair_validated_if_ahead(
    tracker: ProjectTracker,
    block_store: BlockStore,
    chain: ChainParams,
) -> int:
    """Rebuild validated state when tip ran ahead of stored blocks (e.g. partial manual connect)."""
    max_stored = tracker.max_stored_block_height()
    validated = tracker.get_validated_height(chain.name)
    if validated <= max_stored:
        return 0
    logger.warning(
        "Validated height %s is ahead of stored blocks (%s); rebuilding UTXO set",
        validated,
        max_stored,
    )
    return rebuild_validated_chain(tracker, block_store, chain)


def rebuild_validated_chain(
    tracker: ProjectTracker,
    block_store: BlockStore,
    chain: ChainParams,
) -> int:
    tracker.reset_validated_chain(chain=chain.name, genesis_hash=chain.genesis_hash)
    total = 0
    while True:
        connected, _ = connect_stored_blocks(tracker, block_store, chain)
        if not connected:
            break
        total += connected
        if total == connected or total % 256 == 0:
            logger.info(
                "Rebuild progress: connected=%s height=%s utxos=%s",
                total,
                tracker.get_validated_height(chain.name),
                tracker.utxo_count(),
            )
    return total


def connect_stored_blocks(
    tracker: ProjectTracker,
    block_store: BlockStore,
    chain: ChainParams,
) -> tuple[int, list[bytes]]:
    connected = 0
    hashes: list[bytes] = []
    while True:
        height = tracker.get_validated_height(chain.name) + 1
        row = tracker.get_block(height)
        if not row:
            break
        expected_prev = _expected_prev_hash(tracker, height)
        if expected_prev is None:
            break
        payload = block_store.read(row["file_name"], int(row["file_offset"]), int(row["size"]))
        block_hash = bytes.fromhex(row["block_hash"])[::-1]
        connect_block(
            tracker,
            payload,
            height=height,
            expected_prev=expected_prev,
            expected_hash=block_hash,
            chain_name=chain.name,
        )
        hashes.append(block_hash)
        connected += 1
    return connected, hashes


def validate_stored_blocks(
    tracker: ProjectTracker,
    block_store: BlockStore,
) -> int:
    rows = tracker.iter_blocks()
    validated = 0
    for row in rows:
        height = int(row["height"])
        expected_prev = _expected_prev_hash(tracker, height)
        if expected_prev is None:
            continue
        payload = block_store.read(row["file_name"], int(row["file_offset"]), int(row["size"]))
        block_hash = bytes.fromhex(row["block_hash"])[::-1]
        validate_block(payload, expected_prev=expected_prev, expected_hash=block_hash)
        validated += 1
    return validated
