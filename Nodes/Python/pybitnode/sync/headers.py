from __future__ import annotations

from pybitnode.chain.genesis import genesis_header_for
from pybitnode.chain.params import ChainParams
from pybitnode.chainstate.tracker import ProjectTracker
from pybitnode.messages.headers import BlockHeader, HeadersMessage
from pybitnode.sync.validate import HeaderValidationError, validate_header


def repair_sync_state(tracker: ProjectTracker, chain: ChainParams) -> None:
    """Align sync_state with the highest stored header (resume after crash)."""
    height = tracker.max_header_height()
    block_hash = tracker.get_header_hash(height)
    if block_hash is None:
        return
    tracker.upsert_sync_state(
        chain.name,
        best_height=height,
        best_hash=block_hash,
        header_count=tracker.header_count(),
        sync_status="headers_syncing",
    )


def ensure_genesis(tracker: ProjectTracker, chain: ChainParams) -> BlockHeader:
    existing = tracker.get_header_hash(0)
    genesis = genesis_header_for(chain.name)
    if existing:
        if existing != genesis.block_hash_hex():
            raise HeaderValidationError(
                f"Stored genesis hash {existing} does not match chain genesis {genesis.block_hash_hex()}"
            )
        tracker.backfill_header_serialized(0, genesis.serialize().hex())
        return genesis

    tracker.record_header(
        0,
        genesis.block_hash_hex(),
        "0" * 64,
        genesis.timestamp,
        header_serialized_hex=genesis.serialize().hex(),
    )
    tracker.upsert_sync_state(
        chain.name,
        best_height=0,
        best_hash=genesis.block_hash_hex(),
        header_count=tracker.header_count(),
        sync_status="genesis_seeded",
    )
    tracker.log_event("sync", "Genesis header seeded", details={"hash": genesis.block_hash_hex()})
    return genesis


def genesis_locator(chain: ChainParams) -> list[bytes]:
    genesis = genesis_header_for(chain.name)
    return [genesis.block_hash()]


def persist_headers(
    tracker: ProjectTracker,
    chain: ChainParams,
    message: HeadersMessage,
) -> tuple[int, str, int]:
    """Validate and store headers. Returns (best_height, best_hash_hex, stored_count)."""
    ensure_genesis(tracker, chain)
    state = tracker.get_sync_state(chain.name) or {}
    tip_height = int(state.get("best_height", 0))
    tip_hash_hex = tracker.get_header_hash(tip_height) or chain.genesis_hash
    tip_internal = bytes.fromhex(tip_hash_hex)[::-1]

    stored = 0
    for header in message.headers:
        try:
            validate_header(header, expected_prev=tip_internal)
        except HeaderValidationError as exc:
            tracker.log_event(
                "sync",
                f"Header rejected at height {tip_height + 1}: {exc}",
                level="warning",
            )
            break

        tip_height += 1
        block_hash = header.block_hash_hex()
        prev_hash = header.prev_block[::-1].hex()
        tracker.record_header(
            tip_height,
            block_hash,
            prev_hash,
            header.timestamp,
            header_serialized_hex=header.serialize().hex(),
        )
        tip_internal = header.block_hash()
        stored += 1

    if stored:
        tracker.upsert_sync_state(
            chain.name,
            best_height=tip_height,
            best_hash=tracker.get_header_hash(tip_height) or chain.genesis_hash,
            header_count=tracker.header_count(),
            sync_status="headers_syncing",
        )
    return tip_height, tracker.get_header_hash(tip_height) or chain.genesis_hash, stored


def next_locator(tracker: ProjectTracker, chain: ChainParams) -> list[bytes]:
    ensure_genesis(tracker, chain)
    state = tracker.get_sync_state(chain.name)
    best_height = int(state["best_height"]) if state else 0
    locator_heights = _locator_heights(best_height)
    hashes: list[bytes] = []
    for height in locator_heights:
        block_hash = tracker.get_header_hash(height)
        if block_hash:
            hashes.append(bytes.fromhex(block_hash)[::-1])
    if not hashes:
        return genesis_locator(chain)
    return hashes


def _locator_heights(tip: int) -> list[int]:
    """Exponential block locator matching Bitcoin Core behavior."""
    step = 1
    heights = [tip]
    while tip > 0:
        tip = max(tip - step, 0)
        heights.append(tip)
        step <<= 1
    return heights


def headers_sync_done(*, best_height: int, peer_height: int, batch_count: int) -> bool:
    """Return True when header sync should stop."""
    if batch_count == 0:
        return True
    return peer_height >= 0 and best_height >= peer_height


HEADER_SYNC_NEAR_PEER_TIP = 2


def local_header_tip_height(tracker: ProjectTracker, chain: ChainParams) -> int:
    """Best local header height from sync_state and headers table."""
    state = tracker.get_sync_state(chain.name) or {}
    best_state = int(state.get("best_height", 0))
    return max(best_state, tracker.max_header_height())


def required_header_tip_for_block_followup(
    tracker: ProjectTracker,
    chain: ChainParams,
    *,
    blocks_target_height: int,
) -> int:
    """Minimum main-chain header height that must exist to continue block validation/download."""
    missing = tracker.list_missing_block_heights(limit=1)
    validated = tracker.get_validated_height(chain.name)
    if missing:
        need = missing[0]
    else:
        need = validated + 1

    tgt = blocks_target_height or 0
    if tgt > 0:
        need = max(need, tgt)
    return max(need, validated + 1)


def local_headers_cover_block_followup(
    tracker: ProjectTracker,
    chain: ChainParams,
    *,
    blocks_target_height: int,
) -> bool:
    """True when stored headers suffice for downloading/validating the next batch (and blocks-target if set)."""
    need_through = required_header_tip_for_block_followup(
        tracker,
        chain,
        blocks_target_height=blocks_target_height,
    )
    tip = max(local_header_tip_height(tracker, chain), tracker.max_header_height())
    if tip < need_through:
        return False
    return tracker.get_header_hash(need_through) is not None


def should_skip_header_download(
    tracker: ProjectTracker,
    chain: ChainParams,
    *,
    peer_tip_height: int,
) -> bool:
    """Avoid getheaders churn when locals are aligned with peer tip or only block-sync remains."""
    if peer_tip_height < 0:
        return False

    tip_local = local_header_tip_height(tracker, chain)
    return tip_local >= peer_tip_height - HEADER_SYNC_NEAR_PEER_TIP


def mark_headers_current(tracker: ProjectTracker, chain: ChainParams) -> None:
    state = tracker.get_sync_state(chain.name) or {}
    tracker.upsert_sync_state(
        chain.name,
        best_height=int(state.get("best_height", 0)),
        best_hash=state.get("best_hash", chain.genesis_hash),
        header_count=tracker.header_count(),
        sync_status="headers_current",
    )


async def sync_headers_to_tip(connection, *, peer_height: int | None = None) -> int:
    """Download and validate headers until tip or peer height is reached."""
    from pybitnode.p2p.peer import PeerConnection

    if not isinstance(connection, PeerConnection):
        raise TypeError("connection must be a PeerConnection")

    chain = connection.chain
    tracker = connection.tracker
    target_height = peer_height if peer_height is not None else (
        connection.remote_version.start_height if connection.remote_version else -1
    )

    ensure_genesis(tracker, chain)

    if should_skip_header_download(tracker, chain, peer_tip_height=target_height):
        mark_headers_current(tracker, chain)
        return 0

    total_stored = 0

    while True:
        state = tracker.get_sync_state(chain.name) or {}
        best_height = int(state.get("best_height", 0))
        locator = next_locator(tracker, chain)
        if should_skip_header_download(tracker, chain, peer_tip_height=target_height):
            mark_headers_current(tracker, chain)
            return total_stored
        message = await connection.request_headers(locator)
        batch_count = len(message.headers)

        if headers_sync_done(best_height=best_height, peer_height=target_height, batch_count=batch_count):
            mark_headers_current(tracker, chain)
            break

        _, _, stored = persist_headers(tracker, chain, message)
        total_stored += stored

        if stored == 0:
            mark_headers_current(tracker, chain)
            break

        state = tracker.get_sync_state(chain.name) or {}
        best_height = int(state.get("best_height", 0))
        if headers_sync_done(best_height=best_height, peer_height=target_height, batch_count=batch_count):
            mark_headers_current(tracker, chain)
            break

    return total_stored

