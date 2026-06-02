from __future__ import annotations

import argparse
import asyncio
import logging
from pathlib import Path

from pybitnode.chain.params import get_chain
from pybitnode.config import Settings
from pybitnode.consensus.connect import ConnectBlockError
from pybitnode.chainstate.tracker import ProjectTracker
from pybitnode.node import _configure_logging, _parse_peers
from pybitnode.p2p.manager import PeerManager
from pybitnode.storage.blocks import BlockStore
from pybitnode.sync.blocks import connect_stored_blocks, rebuild_validated_chain, repair_validated_if_ahead
from pybitnode.sync.header_refresh import (
    HeaderRefreshAction,
    decide_header_refresh_action,
    header_refresh_log_message,
)
from pybitnode.sync.headers import (
    ensure_genesis,
    local_headers_cover_block_followup,
    mark_headers_current,
    repair_sync_state,
)
from pybitnode.sync.sync_datadir_lock import ExclusiveDataDirSyncLock

logger = logging.getLogger(__name__)


def _latest_sync_blocker(tracker: ProjectTracker) -> str:
    for event in tracker.recent_events(limit=20):
        message = str(event.get("message", ""))
        if message.startswith("Block connect failed"):
            return message
        if message in {"Rejected invalid block", "Block unavailable from peers"}:
            return str(event.get("details_json", "") or message)
    return ""


def _print_sync_summary(
    tracker: ProjectTracker,
    chain_name: str,
    *,
    downloaded_blocks: int = 0,
    connected_blocks: int = 0,
    current_blocker: str = "",
) -> None:
    sync_state = tracker.get_sync_state(chain_name) or {}
    blocker = current_blocker or _latest_sync_blocker(tracker) or "(none)"
    print("pybitnode sync summary")
    print(f"  downloaded_blocks={downloaded_blocks}")
    print(f"  connected_blocks={connected_blocks}")
    print(f"  sync_status={sync_state.get('sync_status', 'unknown')}")
    print(f"  current_blocker={blocker}")
    print(f"  validated_height={tracker.get_validated_height(chain_name)}")
    print(f"  header_height={tracker.max_header_height()}")
    print(f"  utxo_count={tracker.utxo_count()}")
    print("  binary_gate_status=not_attempted")


def _update_phase3(tracker: ProjectTracker, chain_name: str) -> None:
    validated = tracker.get_validated_height(chain_name)
    tracker.update_phase(
        "phase3",
        status="in_progress",
        notes=f"Validated through height {validated} ({tracker.utxo_count()} UTXOs)",
    )


async def connect_stored(settings: Settings, *, rebuild: bool = False) -> int:
    chain = get_chain(settings.chain)
    tracker = ProjectTracker(settings.resolved_state_path())
    ensure_genesis(tracker, chain)
    repair_sync_state(tracker, chain)
    block_store = BlockStore(Path(settings.blocks_dir()), chain.magic)
    connected = 0
    try:
        repair_validated_if_ahead(tracker, block_store, chain)
        if rebuild:
            connected = rebuild_validated_chain(tracker, block_store, chain)
            logger.info(
                "Rebuilt validated chain from stored blocks (height=%s, utxos=%s)",
                tracker.get_validated_height(chain.name),
                tracker.utxo_count(),
            )
        else:
            connected, _ = connect_stored_blocks(tracker, block_store, chain)
        if connected:
            _update_phase3(tracker, chain.name)
            logger.info(
                "Connected %s stored blocks (validated height=%s, utxos=%s)",
                connected,
                tracker.get_validated_height(chain.name),
                tracker.utxo_count(),
            )
        _print_sync_summary(tracker, chain.name, connected_blocks=connected)
        return 0
    except ConnectBlockError as exc:
        tracker.log_event("sync", f"Block connect failed: {exc}", level="error")
        _print_sync_summary(tracker, chain.name, connected_blocks=connected, current_blocker=str(exc))
        raise
    finally:
        tracker.close()


async def sync_blocks(settings: Settings) -> int:
    chain = get_chain(settings.chain)
    tracker = ProjectTracker(settings.resolved_state_path())
    ensure_genesis(tracker, chain)
    repair_sync_state(tracker, chain)
    block_store = BlockStore(Path(settings.blocks_dir()), chain.magic)
    port = settings.p2p_port or chain.default_port
    manual_peers = _parse_peers(settings.peers, port)
    manager = PeerManager(chain, tracker, settings)
    connected = 0
    downloaded = 0

    try:
        repair_validated_if_ahead(tracker, block_store, chain)
        if settings.rebuild_validated_chain:
            connected = rebuild_validated_chain(tracker, block_store, chain)
            logger.info(
                "Rebuilt validated chain before download (height=%s, utxos=%s)",
                tracker.get_validated_height(chain.name),
                tracker.utxo_count(),
            )
        else:
            connected, _ = connect_stored_blocks(tracker, block_store, chain)
        if connected:
            _update_phase3(tracker, chain.name)
            logger.info("Connected %s stored blocks before download", connected)

        state = tracker.get_sync_state(chain.name) or {}
        sync_best = int(state.get("best_height", 0))
        validated = tracker.get_validated_height(chain.name)
        blocks_target = settings.blocks_target_height or 0
        skip_header_network = (
            settings.no_header_refresh
            or settings.sync_skip_headers
            or (blocks_target > 0 and tracker.max_header_height() >= blocks_target)
        )
        handshake_height = validated if skip_header_network else sync_best
        await manager.bootstrap(manual_peers, start_height=handshake_height)

        ordered = manager._ordered_sync_peers()
        advertised = (
            int(ordered[0].remote_version.start_height)
            if ordered and ordered[0].remote_version is not None
            else -1
        )
        refresh_action = decide_header_refresh_action(
            settings,
            tracker,
            chain,
            sync_best_height=sync_best,
            advertised_peer_height=advertised,
        )
        blocks_target = settings.blocks_target_height or 0
        locals_cover_followup = local_headers_cover_block_followup(
            tracker,
            chain,
            blocks_target_height=blocks_target,
        )

        if refresh_action is not HeaderRefreshAction.NETWORK_SYNC:
            mark_headers_current(tracker, chain)
            logger.info(header_refresh_log_message(refresh_action))
        else:
            await manager.sync_headers(
                best_effort_if_headers_cover_followup_blocks=locals_cover_followup,
            )

        downloaded = await manager.sync_blocks(block_store)
        validated = tracker.get_validated_height(chain.name)
        if downloaded or validated:
            tracker.update_phase(
                "phase2",
                status="in_progress",
                notes=f"{tracker.block_count()} blocks stored, validated through height {validated}",
            )
            _update_phase3(tracker, chain.name)
            logger.info(
                "Block sync complete: downloaded=%s stored=%s validated=%s utxos=%s",
                downloaded,
                tracker.block_count(),
                validated,
                tracker.utxo_count(),
            )
        _print_sync_summary(
            tracker,
            chain.name,
            downloaded_blocks=downloaded,
            connected_blocks=connected + downloaded,
        )
        return 0
    except ConnectBlockError as exc:
        tracker.log_event("sync", f"Block connect failed: {exc}", level="error")
        _print_sync_summary(
            tracker,
            chain.name,
            downloaded_blocks=downloaded,
            connected_blocks=connected + downloaded,
            current_blocker=str(exc),
        )
        raise
    finally:
        await manager.close()
        tracker.close()


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description="pybitnode offline/online block sync helpers")
    parser.add_argument("--chain", default=None)
    parser.add_argument("--datadir", default=None)
    parser.add_argument("--state-path", default=None, help="Native RocksDB chainstate directory")
    parser.add_argument("--peers", default=None)
    parser.add_argument("--blocks-target", type=int, default=None)
    parser.add_argument("--blocks-max", type=int, default=None)
    parser.add_argument("--log-level", default=None)
    parser.add_argument("--connect-only", action="store_true", help="Connect stored blocks without network")
    parser.add_argument(
        "--no-header-refresh",
        action="store_true",
        help="Skip networked header refresh; validate/download blocks using existing native headers only",
    )
    parser.add_argument(
        "--rebuild",
        action="store_true",
        help="Rebuild UTXO set and validated tip from stored blocks (clears utxos first)",
    )
    args = parser.parse_args(argv)

    settings = Settings.from_env()
    if args.chain:
        settings.chain = args.chain
    if args.datadir:
        settings.data_dir = args.datadir
    if args.state_path:
        settings.state_path = args.state_path
    if args.peers is not None:
        settings.peers = args.peers
    if args.blocks_target is not None:
        settings.blocks_target_height = args.blocks_target
    if args.blocks_max is not None:
        settings.blocks_max_per_run = args.blocks_max
    if args.log_level:
        settings.log_level = args.log_level
    if args.rebuild:
        settings.rebuild_validated_chain = True
    if getattr(args, "no_header_refresh", False):
        settings.no_header_refresh = True

    _configure_logging(settings.log_level)

    resolved_data = Path(settings.data_dir).expanduser()

    async def async_main() -> int:
        if args.connect_only:
            return await connect_stored(settings, rebuild=args.rebuild)
        return await sync_blocks(settings)

    try:
        with ExclusiveDataDirSyncLock(resolved_data):
            rc = asyncio.run(async_main())
        raise SystemExit(rc)
    except RuntimeError as exc:
        if "Another pybitnode-sync holds this datadir" in str(exc):
            raise SystemExit(2) from exc
        raise


if __name__ == "__main__":
    main()
