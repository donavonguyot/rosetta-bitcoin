from __future__ import annotations

import argparse
import asyncio
import contextlib
import logging
from pathlib import Path

from pybitnode.chain.params import get_chain
from pybitnode.config import Settings
from pybitnode.consensus.connect import ConnectBlockError
from pybitnode.db.tracker import ProjectTracker
from pybitnode.metrics import clear_last_error, record_last_error
from pybitnode.metrics_http import serve_metrics_http_forever
from pybitnode.p2p.manager import PeerManager
from pybitnode.p2p.peer import broadcast_witness_block_inv
from pybitnode.endpoint_parse import split_manual_peer_list
from pybitnode.p2p.server import serve_inbound
from pybitnode.storage.blocks import BlockStore
from pybitnode.sync.blocks import connect_stored_blocks
from pybitnode.sync.headers import ensure_genesis, repair_sync_state

logger = logging.getLogger(__name__)


def _configure_logging(level: str) -> None:
    logging.basicConfig(
        level=getattr(logging, level.upper(), logging.INFO),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )


def _parse_peers(raw: str, default_port: int) -> list[tuple[str, int]]:
    return split_manual_peer_list(raw or "", default_port)


async def run_node(settings: Settings, *, sync_only: bool = False) -> int:
    chain = get_chain(settings.chain)
    data_dir = Path(settings.data_dir)
    data_dir.mkdir(parents=True, exist_ok=True)

    tracker = ProjectTracker(settings.resolved_db_path())
    metrics_listener: asyncio.Task | None = None
    tracker.set_meta("chain", chain.name)
    tracker.set_meta("data_dir", str(data_dir))
    tracker.upsert_sync_state(chain.name, sync_status="starting")
    tracker.log_event("node", "Starting pybitnode", details={"chain": chain.name})
    ensure_genesis(tracker, chain)
    repair_sync_state(tracker, chain)

    metrics_listener = (
        asyncio.create_task(serve_metrics_http_forever(tracker=tracker, settings=settings))
        if settings.metrics_http_port > 0
        else None
    )

    port = settings.p2p_port or chain.default_port
    manual_peers = _parse_peers(settings.peers, port)
    state = tracker.get_sync_state(chain.name) or {}
    manager = PeerManager(chain, tracker, settings)
    listener: asyncio.Task | None = None

    try:
        await manager.bootstrap(manual_peers, start_height=int(state.get("best_height", 0)))
        clear_last_error(tracker)
        tracker.upsert_sync_state(chain.name, sync_status="connected")

        stored = await manager.sync_headers()
        state = tracker.get_sync_state(chain.name) or {}
        if state.get("sync_status") == "headers_current":
            tracker.update_phase("phase0", status="completed", notes="Wire protocol and handshake verified")
            tracker.update_phase(
                "phase1",
                status="completed",
                notes=f"Header chain synced to height {state.get('best_height', 0)}",
            )
        elif stored:
            tracker.update_phase("phase0", status="completed", notes="Wire protocol and handshake verified")
            tracker.update_phase("phase1", status="in_progress", notes="Header chain sync in progress")

        logger.info(
            "Header sync stored %s headers (status=%s, peers=%s)",
            stored,
            state.get("sync_status"),
            len(manager.connections),
        )

        block_store = BlockStore(Path(settings.blocks_dir()), chain.magic)
        try:
            connected, new_hashes = connect_stored_blocks(tracker, block_store, chain)
            for h in new_hashes:
                await broadcast_witness_block_inv(manager.connections, h, tracker)
            if connected:
                tracker.update_phase(
                    "phase3",
                    status="in_progress",
                    notes=(
                        f"Connected {connected} blocks to height {tracker.get_validated_height(chain.name)} "
                        f"({tracker.utxo_count()} UTXOs)"
                    ),
                )
                logger.info(
                    "Connected %s blocks (validated height=%s, utxos=%s)",
                    connected,
                    tracker.get_validated_height(chain.name),
                    tracker.utxo_count(),
                )
        except ConnectBlockError as exc:
            tracker.log_event("sync", f"Block connect failed: {exc}", level="error")
            raise

        blocks_downloaded = await manager.sync_blocks(block_store)
        validated = tracker.get_validated_height(chain.name)
        if blocks_downloaded or validated:
            tracker.update_phase(
                "phase2",
                status="in_progress",
                notes=f"{tracker.block_count()} blocks stored, validated through height {validated}",
            )
            if validated:
                tracker.update_phase(
                    "phase3",
                    status="in_progress",
                    notes=f"Validated chain through height {validated} ({tracker.utxo_count()} UTXOs)",
                )
            logger.info(
                "Block sync downloaded=%s stored=%s validated=%s utxos=%s",
                blocks_downloaded,
                tracker.block_count(),
                validated,
                tracker.utxo_count(),
            )

        if sync_only:
            tracker.upsert_sync_state(chain.name, sync_status="running")
            logger.info("Sync-only mode complete")
            return 0

        tracker.upsert_sync_state(chain.name, sync_status="running")
        logger.info("Entering message loop with %s peers", len(manager.connections))
        if settings.listen:
            listener = asyncio.create_task(
                asyncio.gather(
                    manager.run(),
                    serve_inbound(
                        chain=chain,
                        tracker=tracker,
                        settings=settings,
                        block_store=block_store,
                        mempool=manager.mempool,
                    ),
                )
            )
        else:
            listener = asyncio.create_task(manager.run())
        await listener
        return 0
    except asyncio.CancelledError:
        tracker.log_event("node", "Shutdown requested", level="info")
        return 0
    except Exception as exc:
        tracker.log_event("node", f"Node error: {exc}", level="error")
        record_last_error(tracker, str(exc))
        tracker.upsert_sync_state(chain.name, sync_status="error")
        raise
    finally:
        if metrics_listener:
            metrics_listener.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await metrics_listener
        if listener:
            listener.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await listener
        await manager.close()
        tracker.close()


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description="pybitnode — Python Bitcoin full node")
    parser.add_argument("--chain", default=None)
    parser.add_argument("--datadir", default=None)
    parser.add_argument("--db", default=None, help="SQLite database path")
    parser.add_argument("--peers", default=None, help="Comma-separated host:port list")
    parser.add_argument("--log-level", default=None)
    parser.add_argument("--sync-only", action="store_true", help="Exit after header/block sync")
    parser.add_argument("--blocks-target", type=int, default=None, help="Stop after validating this height")
    parser.add_argument("--blocks-max", type=int, default=None, help="Max blocks to download this run")
    parser.add_argument("--listen", action="store_true", help="Accept inbound P2P (same as LISTEN=1)")
    args = parser.parse_args(argv)

    settings = Settings.from_env()
    if args.chain:
        settings.chain = args.chain
    if args.datadir:
        settings.data_dir = args.datadir
    if args.db:
        settings.db_path = args.db
    if args.peers is not None:
        settings.peers = args.peers
    if args.log_level:
        settings.log_level = args.log_level
    if args.blocks_target is not None:
        settings.blocks_target_height = args.blocks_target
    if args.blocks_max is not None:
        settings.blocks_max_per_run = args.blocks_max
    if args.listen:
        settings.listen = True

    _configure_logging(settings.log_level)
    try:
        raise SystemExit(asyncio.run(run_node(settings, sync_only=args.sync_only)))
    except KeyboardInterrupt:
        raise SystemExit(130) from None


if __name__ == "__main__":
    main()
