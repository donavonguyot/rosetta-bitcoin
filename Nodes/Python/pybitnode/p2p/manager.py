from __future__ import annotations

import asyncio
import logging

from pybitnode.chain.params import ChainParams
from pybitnode.config import Settings
from pybitnode.consensus.witness import transaction_wtxid
from pybitnode.chainstate.tracker import ProjectTracker
from pybitnode.mempool import Mempool, transaction_meets_peer_feefilter
from pybitnode.metrics import META_TXS_RELAYED_TOTAL, incr_meta_counter
from pybitnode.messages.inventory import InvMessage, InventoryVector
from pybitnode.messages.transaction import Transaction
from pybitnode.p2p.ban_policy import BAN_HANDSHAKE_FAIL
from pybitnode.p2p.discovery import bootstrap_peer_targets
from pybitnode.p2p.peer import PeerConnection
from pybitnode.storage.blocks import BlockStore
from pybitnode.sync.blocks import sync_blocks_to_tip

logger = logging.getLogger(__name__)


class PeerManager:
    def __init__(
        self,
        chain: ChainParams,
        tracker: ProjectTracker,
        settings: Settings,
    ) -> None:
        self.chain = chain
        self.tracker = tracker
        self.settings = settings
        self.connections: list[PeerConnection] = []
        self.mempool = Mempool(tracker=tracker)
        self._effective_max_outbound = settings.max_outbound_peers
        self._manual_sync_peers: set[tuple[str, int]] = set()

    async def relay_accepted_transaction(self, tx: Transaction, source: PeerConnection) -> None:
        """Announce mempool accept to outbound peers except the broadcaster (minimal cp5 relay)."""
        payload = InvMessage(
            inventory=[InventoryVector(type=InventoryVector.MSG_WITNESS_TX, hash=transaction_wtxid(tx))],
        ).serialize()
        relayed_any = False
        for peer in self.connections:
            if peer is source or not peer.is_connected:
                continue
            if not transaction_meets_peer_feefilter(tx, self.tracker, peer.peer_fee_filter_sat_kvb):
                continue
            await peer.send(InvMessage.COMMAND, payload)
            relayed_any = True
        if relayed_any:
            incr_meta_counter(self.tracker, META_TXS_RELAYED_TOTAL)
            self.tracker.mark_wire_capability(
                "tx.inv.send",
                implemented=True,
                verified_by="live",
                notes="witness-tx inv after mempool insert",
            )

    async def connect_peers(
        self,
        targets: list[tuple[str, int]],
        *,
        start_height: int = 0,
        discover_peer_addresses: bool = True,
    ) -> None:
        for host, port in targets:
            if len(self.connections) >= self._effective_max_outbound:
                break
            if any(c.host == host and c.port == port for c in self.connections):
                continue

            async def relay(tx: Transaction, peer: PeerConnection) -> None:
                await self.relay_accepted_transaction(tx, peer)

            connection = PeerConnection(
                host=host,
                port=port,
                chain=self.chain,
                tracker=self.tracker,
                protocol_version=self.settings.protocol_version,
                user_agent=self.settings.user_agent,
                start_height=start_height,
                ping_interval=self.settings.ping_interval_seconds,
                stale_timeout=self.settings.peer_stale_seconds,
                mempool=self.mempool,
                relay_tx_accepted=relay,
                settings=self.settings,
            )
            try:
                await connection.connect()
            except (OSError, TimeoutError, ConnectionError, ValueError) as exc:
                logger.warning("Failed to connect to %s:%s: %s", host, port, exc)
                if host and host != "unknown" and port > 0:
                    self.tracker.increment_peer_ban_score(host, port, BAN_HANDSHAKE_FAIL)
                continue
            self.connections.append(connection)
            if discover_peer_addresses:
                try:
                    await connection.discover_peers()
                except (ConnectionError, TimeoutError, OSError, ValueError) as exc:
                    logger.warning(
                        "Peer address discovery failed for %s:%s (continuing sync): %s",
                        host,
                        port,
                        exc,
                    )
            if len(self.connections) >= self._effective_max_outbound:
                break

    async def bootstrap(self, manual_peers: list[tuple[str, int]], *, start_height: int = 0) -> None:
        self._manual_sync_peers = set(manual_peers)
        if manual_peers:
            # Respect MAX_OUTBOUND_PEERS for sync; do not pull extra DB/DNS targets when --peers is set.
            self._effective_max_outbound = max(1, self.settings.max_outbound_peers)
            targets = list(manual_peers)
        else:
            self._effective_max_outbound = self.settings.max_outbound_peers
            targets = await bootstrap_peer_targets(self.chain, self.tracker, self.settings, manual_peers)
        discover = not self.settings.skip_getaddr
        await self.connect_peers(targets, start_height=start_height, discover_peer_addresses=discover)
        if not self.connections:
            raise RuntimeError("Could not connect to any peers")

    def _ordered_sync_peers(self) -> list[PeerConnection]:
        """Prefer `--peers` endpoints, then highest advertised peer height."""
        manual = self._manual_sync_peers

        def sort_key(peer: PeerConnection) -> tuple[int, int]:
            manual_rank = 0 if (peer.host, peer.port) in manual else 1
            remote_h = -(peer.remote_version.start_height if peer.remote_version else 0)
            return (manual_rank, remote_h)

        return sorted(
            (p for p in self.connections if p.is_connected),
            key=sort_key,
        )

    async def sync_headers(self, *, best_effort_if_headers_cover_followup_blocks: bool = False) -> int:
        peers = self._ordered_sync_peers()
        if not peers:
            raise RuntimeError("No connected peers available for header sync")

        from pybitnode.sync.headers import local_headers_cover_block_followup, mark_headers_current

        last_error: BaseException | None = None
        for peer in peers:
            try:
                return await peer.sync_headers()
            except (ConnectionError, TimeoutError, OSError, ValueError) as exc:
                last_error = exc
                logger.warning(
                    "Header sync failed via %s:%s (%s); trying next peer",
                    peer.host,
                    peer.port,
                    exc,
                )
        assert last_error is not None  # pragma: no cover — peers imply a failing attempt occurred
        if (
            best_effort_if_headers_cover_followup_blocks
            and local_headers_cover_block_followup(
                self.tracker,
                self.chain,
                blocks_target_height=self.settings.blocks_target_height or 0,
            )
        ):
            logger.warning(
                "header_sync_best_effort_continuing_block_download error=%s",
                last_error,
            )
            mark_headers_current(self.tracker, self.chain)
            return 0
        raise last_error

    async def sync_blocks(self, block_store: BlockStore) -> int:
        return await sync_blocks_to_tip(
            self._ordered_sync_peers(),
            self.tracker,
            self.chain,
            block_store,
            batch_size=self.settings.blocks_batch_size,
            max_blocks=self.settings.blocks_max_per_run,
            target_height=self.settings.blocks_target_height,
            parallel_downloads=self.settings.parallel_block_downloads,
        )

    async def run(self) -> None:
        await asyncio.gather(*(connection.run() for connection in self.connections))

    async def close(self) -> None:
        await asyncio.gather(*(connection.close() for connection in self.connections))
