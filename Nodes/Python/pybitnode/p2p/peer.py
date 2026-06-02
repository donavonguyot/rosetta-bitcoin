from __future__ import annotations

import asyncio
import logging
import random
import socket
from collections.abc import Awaitable, Callable

from pybitnode.p2p.ban_policy import (
    BAN_DISCONNECT,
    BAN_INVALID_MESSAGE,
    BAN_PROTOCOL_VIOLATION,
    BAN_REJECT_FLOOD,
    ban_score_for_reject_ccode,
)
import struct
import time
from dataclasses import dataclass, field

from pybitnode.chain.params import ChainParams
from pybitnode.config import Settings
from pybitnode.consensus.merkle import transaction_txid
from pybitnode.chainstate.tracker import ProjectTracker
from pybitnode.mempool import Mempool, accept_transaction
from pybitnode.messages.address import AddrMessage, GetAddrMessage
from pybitnode.messages.block import BlockMessage, GetDataMessage, NotFoundMessage
from pybitnode.messages.compact_block import (
    BlockTxnMessage,
    CompactBlockMessage,
    GetBlockTxnMessage,
    complete_compact_with_block_transactions,
    mempool_short_id_transaction_map,
    missing_indexes_for_getblocktxn,
    reconstruct_compact_transactions,
)
from pybitnode.messages.fee_filter import (
    FEEFILTER_MIN_VERSION,
    FeeFilterMessage,
    feefilter_wire_sat_kvb_from_settings,
)
from pybitnode.messages.handshake import (
    NODE_NETWORK,
    NODE_WITNESS,
    NetworkAddress,
    PingMessage,
    PongMessage,
    SendHeadersMessage,
    VerAckMessage,
    VersionMessage,
)
from pybitnode.messages.headers import HeadersMessage
from pybitnode.messages.inventory import (
    GetHeadersMessage,
    InvMessage,
    InventoryVector,
    TX_INVENTORY_TYPES,
    has_block_inventory,
)
from pybitnode.messages.mempool_query import MempoolRequestMessage
from pybitnode.messages.reject import RejectMessage
from pybitnode.messages.transaction import Transaction
from pybitnode.storage.blocks import block_hash_from_payload
from pybitnode.p2p.header_serving import build_headers_response
from pybitnode.sync.headers import sync_headers_to_tip
from pybitnode.wire.frame import HEADER_SIZE, build_message, parse_header, verify_checksum

logger = logging.getLogger(__name__)

# Bound transaction vectors per outbound getdata (large inv batches are chunked; cp5 hardening).
MAX_GETDATA_TX_BATCH = 1024

RelayTxAcceptedFn = Callable[[Transaction, "PeerConnection"], Awaitable[None]]


@dataclass
class _PendingCompactBlockTxnRecovery:
    """Outstanding ``blocktxn`` response after outbound ``getblocktxn`` (BIP152)."""

    compact: CompactBlockMessage
    pool_shortid_map: dict[bytes, Transaction]
    txn_indexes_sorted: tuple[int, ...]


def tx_inventory_need_getdata(items: list[InventoryVector], mempool: Mempool | None) -> list[InventoryVector]:
    """Inv vectors referencing txs we still need to download (matching inv hash type semantics)."""
    if mempool is None:
        return list(items)
    return [item for item in items if mempool.get_for_inv(inv_type=item.type, inv_hash=item.hash) is None]

async def reply_getdata_tx_inventory(
    peer: "PeerConnection",
    mempool: Mempool | None,
    tracker: ProjectTracker,
    inventory: list[InventoryVector],
) -> None:
    """Fulfill MSG_TX / MSG_WITNESS_TX inventory from mempool; notfound remainder."""
    if not inventory:
        return
    notfound: list[InventoryVector] = []
    served = False
    for iv in inventory:
        tx = mempool.get_for_inv(inv_type=iv.type, inv_hash=iv.hash) if mempool else None
        if tx is None:
            notfound.append(iv)
            continue
        include_witness = iv.type == InventoryVector.MSG_WITNESS_TX
        await peer.send("tx", tx.serialize(include_witness=include_witness))
        served = True

    if served:
        tracker.mark_wire_capability(
            "serve.getdata.txs",
            implemented=True,
            verified_by="live",
            notes="served mempool tx over getdata (MSG_TX or MSG_WITNESS_TX)",
        )
    if notfound:
        await peer.send(
            NotFoundMessage.COMMAND,
            NotFoundMessage(inventory=notfound).serialize(),
        )


async def broadcast_witness_block_inv(
    peers: list["PeerConnection"],
    block_hash: bytes,
    tracker: ProjectTracker,
) -> None:
    """INV(MSG_WITNESS_BLOCK) after validated tip advances (minimal outbound announcements)."""
    payload = InvMessage(
        inventory=[InventoryVector(type=InventoryVector.MSG_WITNESS_BLOCK, hash=block_hash)],
    ).serialize()
    sent = False
    for p in peers:
        if not p.is_connected:
            continue
        await p.send(InvMessage.COMMAND, payload)
        sent = True
    if sent:
        tracker.mark_wire_capability(
            "serve.inv.blocks",
            implemented=True,
            verified_by="live",
            notes="broadcast MSG_WITNESS_BLOCK inv on tip advance",
        )



@dataclass
class PeerConnection:
    host: str
    port: int
    chain: ChainParams
    tracker: ProjectTracker
    protocol_version: int
    user_agent: str
    start_height: int = 0
    ping_interval: float = 1200.0
    stale_timeout: float = 5400.0
    mempool: Mempool | None = None
    relay_tx_accepted: RelayTxAcceptedFn | None = None
    settings: Settings = field(default_factory=Settings)
    reader: asyncio.StreamReader | None = field(default=None, init=False)
    writer: asyncio.StreamWriter | None = field(default=None, init=False)
    peer_id: int = 0
    remote_version: VersionMessage | None = None
    #: BIP133: peer-supplied minimum feerate in sat/kvB; None until first valid feefilter.
    peer_fee_filter_sat_kvb: int | None = None
    _buffer: bytearray = field(default_factory=bytearray, init=False)
    _running: bool = field(default=False, init=False)
    _header_sync_lock: asyncio.Lock | None = field(default=None, init=False)
    _request_lock: asyncio.Lock | None = field(default=None, init=False)
    _last_activity: float = field(default=0.0, init=False)
    _last_ping: float = field(default=0.0, init=False)
    _connected_monotonic: float = field(default=0.0, init=False)
    _ban_decay_applied: bool = field(default=False, init=False)
    #: In-session count of successfully parsed inbound `reject` payloads (anti-flood hint).
    _reject_rx_count: int = field(default=0, init=False)
    #: BIP152: waiter for ``blocktxn`` matching the last outbound ``getblocktxn``.
    _pending_compact_recovery: _PendingCompactBlockTxnRecovery | None = field(default=None, init=False)

    @property
    def is_connected(self) -> bool:
        return self.writer is not None and not self.writer.is_closing()

    async def connect(self) -> None:
        self._header_sync_lock = asyncio.Lock()
        self._request_lock = asyncio.Lock()
        now = time.monotonic()
        self._last_activity = now
        self._last_ping = now
        self.reader, self.writer = await asyncio.open_connection(self.host, self.port)
        await self.handshake_as_initiator()
        self._connected_monotonic = time.monotonic()
        self._ban_decay_applied = False
        self._reject_rx_count = 0
        self._pending_compact_recovery = None
        self.peer_id = self.tracker.record_peer_connected(
            self.host,
            self.port,
            services=self.remote_version.services if self.remote_version else 0,
            peer_version=self.remote_version.version if self.remote_version else 0,
            user_agent=self.remote_version.user_agent if self.remote_version else "",
            start_height=self.remote_version.start_height if self.remote_version else 0,
        )

    async def close(self) -> None:
        self._running = False
        if self.writer and not self.writer.is_closing():
            self.writer.close()
            await self.writer.wait_closed()
        if self.peer_id:
            self.tracker.record_peer_disconnected(self.peer_id)

    async def discover_peers(self) -> None:
        """Outbound getaddr: best-effort; never raises on disconnect or timeout."""
        try:
            await self.send(GetAddrMessage.COMMAND, GetAddrMessage().serialize())
            try:
                payload = await self._read_until_command(AddrMessage.COMMAND, timeout=4.0)
            except TimeoutError:
                return
            try:
                message = AddrMessage.deserialize(payload)
            except ValueError:
                return
            for address in message.addresses:
                self.tracker.record_peer_address(
                    address.ip,
                    address.port,
                    services=address.services,
                    source="getaddr",
                )
        except (ConnectionError, TimeoutError, OSError) as exc:
            logger.warning(
                "getaddr_nonfatal_peer_retained_for_block_sync host=%s port=%s error=%s",
                self.host,
                self.port,
                exc,
            )

    def _ban_eligible_endpoint(self) -> bool:
        return bool(self.host and self.port and self.host != "unknown")

    def _note_invalid_peer_message(self) -> None:
        if self._ban_eligible_endpoint() and self.peer_id:
            self.tracker.increment_peer_ban_score(
                self.host,
                self.port,
                BAN_INVALID_MESSAGE,
                peer_id=self.peer_id,
            )

    async def consume_messages(
        self,
        on_message: Callable[[str, bytes], Awaitable[None]],
    ) -> None:
        self._running = True
        while self._running:
            try:
                command, payload = await self.read_message(timeout=30.0)
                self._touch_activity()
                await on_message(command, payload)
            except TimeoutError:
                await self._keepalive_tick()
            except ConnectionError:
                if self._ban_eligible_endpoint():
                    self.tracker.increment_peer_ban_score(
                        self.host,
                        self.port,
                        BAN_DISCONNECT,
                        peer_id=self.peer_id if self.peer_id else None,
                    )
                break
            except ValueError as exc:
                logger.warning(
                    "Protocol violation from %s:%s: %s",
                    self.host,
                    self.port,
                    exc,
                )
                if self._ban_eligible_endpoint():
                    self.tracker.increment_peer_ban_score(
                        self.host,
                        self.port,
                        BAN_PROTOCOL_VIOLATION,
                        peer_id=self.peer_id if self.peer_id else None,
                    )
                break

    async def run(self) -> None:
        await self.consume_messages(self._dispatch)

    def _touch_activity(self) -> None:
        self._last_activity = time.monotonic()
        if self.peer_id:
            self.tracker.touch_peer(self.peer_id)
        self._maybe_decay_ban_after_long_uptime()

    def _maybe_decay_ban_after_long_uptime(self) -> None:
        if self._ban_decay_applied:
            return
        if self._connected_monotonic <= 0.0 or not self.peer_id:
            return
        if not self._ban_eligible_endpoint():
            return
        if time.monotonic() - self._connected_monotonic < self.settings.peer_ban_decay_uptime_seconds:
            return
        self._ban_decay_applied = True
        self.tracker.decay_peer_ban_score(
            self.host,
            self.port,
            self.settings.peer_ban_decay_amount,
            peer_id=self.peer_id,
        )

    async def _keepalive_tick(self) -> None:
        now = time.monotonic()
        if now - self._last_activity > self.stale_timeout:
            logger.info("Disconnecting stale peer %s:%s", self.host, self.port)
            raise ConnectionError("Peer stale")
        if now - self._last_ping >= self.ping_interval:
            self._last_ping = now
            nonce = random.getrandbits(64)
            await self.send(PingMessage.COMMAND, PingMessage(nonce=nonce).serialize())

    async def sync_headers(self) -> int:
        if self._header_sync_lock is None:
            raise RuntimeError("Peer is not connected")
        async with self._header_sync_lock:
            stored = await sync_headers_to_tip(self)
            if stored:
                logger.info(
                    "Header sync stored %s headers (tip height %s)",
                    stored,
                    (self.tracker.get_sync_state(self.chain.name) or {}).get("best_height", 0),
                )
            return stored

    async def trigger_header_sync_from_inv(self) -> None:
        if self._header_sync_lock is None or self._header_sync_lock.locked():
            return
        await self.sync_headers()

    async def request_block(self, block_hash: bytes, *, timeout: float = 120.0) -> bytes | None:
        if self._request_lock is None:
            raise RuntimeError("Peer is not connected")
        async with self._request_lock:
            for inv_type in (InventoryVector.MSG_WITNESS_BLOCK, InventoryVector.MSG_BLOCK):
                payload = await self._request_block_once(block_hash, inv_type, timeout=timeout)
                if payload is not None:
                    return payload
            return None

    async def _request_block_once(
        self,
        block_hash: bytes,
        inv_type: int,
        *,
        timeout: float,
    ) -> bytes | None:
        inv = InventoryVector(type=inv_type, hash=block_hash)
        getdata = GetDataMessage(inventory=[inv])
        await self.send(getdata.COMMAND, getdata.serialize())

        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            remaining = deadline - time.monotonic()
            command, payload = await self.read_message(timeout=remaining)
            self._touch_activity()
            if command == BlockMessage.COMMAND:
                received_hash = block_hash_from_payload(payload)
                if received_hash != block_hash:
                    self.tracker.log_event(
                        "sync",
                        "Block hash mismatch on download",
                        level="warning",
                        details={
                            "expected": block_hash[::-1].hex(),
                            "received": received_hash[::-1].hex(),
                        },
                    )
                    return None
                return payload
            if command == NotFoundMessage.COMMAND:
                missing = NotFoundMessage.deserialize(payload)
                if any(item.hash == block_hash for item in missing.inventory):
                    self.tracker.log_event(
                        "sync",
                        "Peer returned notfound for block",
                        level="warning",
                        details={
                            "hash": block_hash[::-1].hex(),
                            "host": self.host,
                            "inv_type": inv_type,
                        },
                    )
                    return None
            if command == GetHeadersMessage.COMMAND:
                # Do not answer getheaders mid-block-fetch; peers still serve the block (see minimal handshake tests).
                continue
            if command == "ping":
                ping = PingMessage.deserialize(payload)
                await self.send(PongMessage.COMMAND, PongMessage(nonce=ping.nonce).serialize())
                continue
            await self._dispatch(command, payload)
        raise TimeoutError("Timed out waiting for block or notfound")

    async def handshake_as_initiator(self) -> None:
        recv_addr = NetworkAddress(services=NODE_NETWORK | NODE_WITNESS, ip="0.0.0.0", port=0)
        from_addr = NetworkAddress(services=NODE_NETWORK | NODE_WITNESS, ip="0.0.0.0", port=0)
        version = VersionMessage.build(
            protocol_version=self.protocol_version,
            services=NODE_NETWORK | NODE_WITNESS,
            addr_recv=recv_addr,
            addr_from=from_addr,
            user_agent=self.user_agent,
            start_height=self.start_height,
        )
        await self.send(version.COMMAND, version.serialize())
        await self._read_until_command("version")
        await self.send(VerAckMessage.COMMAND, VerAckMessage().serialize())
        await self._read_until_command("verack")
        if not self._lightweight_outbound_handshake():
            await self.send(SendHeadersMessage.COMMAND, SendHeadersMessage().serialize())
        await self._post_verack_negotiation(outbound=True)
        logger.info(
            "Handshake complete with %s:%s (%s)",
            self.host,
            self.port,
            self.remote_version.user_agent if self.remote_version else "?",
        )

    async def handshake_as_responder(self) -> None:
        """Complete version exchange when the peer's version arrives first (inbound)."""
        recv_addr = NetworkAddress(services=NODE_NETWORK | NODE_WITNESS, ip="0.0.0.0", port=0)
        from_addr = NetworkAddress(services=NODE_NETWORK | NODE_WITNESS, ip="0.0.0.0", port=0)
        await self._read_until_command("version")
        version = VersionMessage.build(
            protocol_version=self.protocol_version,
            services=NODE_NETWORK | NODE_WITNESS,
            addr_recv=recv_addr,
            addr_from=from_addr,
            user_agent=self.user_agent,
            start_height=self.start_height,
        )
        await self.send(version.COMMAND, version.serialize())
        await self.send(VerAckMessage.COMMAND, VerAckMessage().serialize())
        await self._read_until_command("verack")
        await self.send(SendHeadersMessage.COMMAND, SendHeadersMessage().serialize())
        await self._post_verack_negotiation(outbound=False)
        logger.info(
            "Inbound handshake complete with %s:%s (%s)",
            self.host,
            self.port,
            self.remote_version.user_agent if self.remote_version else "?",
        )

    def _lightweight_outbound_handshake(self) -> bool:
        """Block-sync connections: skip mempool/feefilter/sendheaders that break historical getdata on some peers."""
        return bool(self.settings.no_header_refresh or self.settings.sync_skip_headers)

    async def _post_verack_negotiation(self, *, outbound: bool) -> None:
        if outbound and self._lightweight_outbound_handshake():
            return
        remote = self.remote_version
        relay_on = remote is None or remote.relay

        # BIP152: ``sendcmpct`` is not sent yet. This node only parses inbound ``cmpctblock``
        # (no compact-block relay negotiation or high-bandwidth mode). Capability
        # ``handshake.sendcmpct`` remains unimplemented until negotiation is wired.

        # BIP133: outbound peers advertise relay policy once services are negotiated.
        if outbound and remote and remote.version >= FEEFILTER_MIN_VERSION:
            wire_kvb = feefilter_wire_sat_kvb_from_settings(self.settings)
            ff = FeeFilterMessage(feerate_sat_kvb=wire_kvb)
            await self.send(ff.COMMAND, ff.serialize())
            self.tracker.mark_wire_capability(
                "tx.feefilter",
                implemented=True,
                verified_by="live",
                notes=f"sent outbound feefilter ({wire_kvb} sat/kvB)",
            )

        # BIP35: request mempool inv when transaction relay is enabled for the peer.
        if relay_on:
            mempool_req = MempoolRequestMessage()
            await self.send(mempool_req.COMMAND, mempool_req.serialize())
            self.tracker.mark_wire_capability(
                "tx.mempool",
                implemented=True,
                verified_by="live",
                notes="sent mempool command (BIP35)",
            )

    async def accept_inbound(self) -> None:
        """Run responder handshake after `reader`/`writer` are wired (listening socket accept)."""
        self._header_sync_lock = asyncio.Lock()
        self._request_lock = asyncio.Lock()
        now = time.monotonic()
        self._last_activity = now
        self._last_ping = now
        if self.reader is None or self.writer is None:
            raise RuntimeError("accept_inbound requires reader/writer to be assigned")
        await self.handshake_as_responder()
        self._connected_monotonic = time.monotonic()
        self._ban_decay_applied = False
        self.peer_id = self.tracker.record_peer_connected(
            self.host,
            self.port,
            direction="inbound",
            services=self.remote_version.services if self.remote_version else 0,
            peer_version=self.remote_version.version if self.remote_version else 0,
            user_agent=self.remote_version.user_agent if self.remote_version else "",
            start_height=self.remote_version.start_height if self.remote_version else 0,
        )

    async def send(self, command: str, payload: bytes = b"") -> None:
        frame = build_message(self.chain.magic, command, payload)
        self.writer.write(frame)
        await self.writer.drain()
        self.tracker.log_event("p2p", f"Sent {command}", details={"host": self.host, "port": self.port})

    async def _read_until_command(self, command: str, timeout: float = 30.0) -> bytes:
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"Timed out waiting for {command!r}")
            msg_command, payload = await self.read_message(timeout=remaining)
            self._touch_activity()
            if msg_command == command:
                if command == "version":
                    self.remote_version = VersionMessage.deserialize(payload)
                return payload
            await self._dispatch(msg_command, payload)

    async def read_message(self, timeout: float = 60.0) -> tuple[str, bytes]:
        while True:
            if len(self._buffer) >= HEADER_SIZE:
                header = parse_header(bytes(self._buffer[:HEADER_SIZE]))
                total = HEADER_SIZE + header.length
                if len(self._buffer) >= total:
                    frame = bytes(self._buffer[:total])
                    del self._buffer[:total]
                    payload = frame[HEADER_SIZE:]
                    if header.magic != self.chain.magic:
                        raise ValueError(f"Unexpected network magic {header.magic.hex()}")
                    if not verify_checksum(payload, header.checksum):
                        raise ValueError(f"Checksum mismatch for {header.command}")
                    return header.command, payload
            chunk = await asyncio.wait_for(self.reader.read(4096), timeout=timeout)
            if not chunk:
                raise ConnectionError("Peer closed connection")
            self._buffer.extend(chunk)

    async def _dispatch(self, command: str, payload: bytes) -> None:
        self.tracker.log_event(
            "p2p",
            f"Received {command}",
            details={"host": self.host, "port": self.port, "length": len(payload)},
        )
        if command == "ping":
            ping = PingMessage.deserialize(payload)
            await self.send(PongMessage.COMMAND, PongMessage(nonce=ping.nonce).serialize())
        elif command == "pong":
            pass
        elif command == FeeFilterMessage.COMMAND:
            if len(payload) != 8:
                self.tracker.log_event(
                    "p2p",
                    "Malformed feefilter payload length",
                    level="warning",
                    details={"host": self.host, "port": self.port},
                )
                self._note_invalid_peer_message()
                return
            try:
                filt = FeeFilterMessage.deserialize(payload)
            except ValueError as exc:
                self.tracker.log_event(
                    "p2p",
                    f"Malformed feefilter: {exc}",
                    level="warning",
                    details={"host": self.host, "port": self.port},
                )
                self._note_invalid_peer_message()
                return
            self.peer_fee_filter_sat_kvb = filt.feerate_sat_kvb
            self.tracker.log_event(
                "p2p",
                "Peer feefilter received",
                level="debug",
                details={
                    "host": self.host,
                    "port": self.port,
                    "feerate_sat_kvb": filt.feerate_sat_kvb,
                },
            )
        elif command == "version":
            self.remote_version = VersionMessage.deserialize(payload)
        elif command == "addr":
            message = AddrMessage.deserialize(payload)
            for address in message.addresses:
                self.tracker.record_peer_address(
                    address.ip,
                    address.port,
                    services=address.services,
                    source="addr",
                )
        elif command == "inv":
            inv = InvMessage.deserialize(payload)
            tx_items = [item for item in inv.inventory if item.type in TX_INVENTORY_TYPES]
            if tx_items:
                self.tracker.mark_wire_capability(
                    "tx.inv.recv",
                    implemented=True,
                    verified_by="live",
                    notes="parsed inv with transaction vectors",
                )
                self.tracker.log_event(
                    "p2p",
                    "Transaction inv received",
                    details={
                        "host": self.host,
                        "port": self.port,
                        "count": len(tx_items),
                        "hashes": [item.hash[::-1].hex() for item in tx_items],
                    },
                )
                todo = tx_inventory_need_getdata(tx_items, self.mempool)
                if todo:
                    for i in range(0, len(todo), MAX_GETDATA_TX_BATCH):
                        chunk = todo[i : i + MAX_GETDATA_TX_BATCH]
                        getdata = GetDataMessage(inventory=chunk)
                        await self.send(getdata.COMMAND, getdata.serialize())
                    self.tracker.mark_wire_capability(
                        "tx.getdata.send",
                        implemented=True,
                        verified_by="live",
                        notes="getdata for tx inv hashes not yet in mempool",
                    )
            if has_block_inventory(inv):
                self.tracker.log_event(
                    "sync",
                    "Block inv received; triggering getheaders",
                    details={"host": self.host, "port": self.port, "count": len(inv.inventory)},
                )
                await self.trigger_header_sync_from_inv()
        elif command == GetHeadersMessage.COMMAND:
            msg = GetHeadersMessage.deserialize(payload)
            reply = build_headers_response(self.tracker, self.chain, msg, block_store=None)
            await self.send(HeadersMessage.COMMAND, reply.serialize())
            self.tracker.mark_wire_capability(
                "serve.getheaders",
                implemented=True,
                verified_by="live",
                notes=f"answered inbound getheaders with {len(reply.headers)} headers",
            )
        elif command == "headers":
            message = HeadersMessage.deserialize(payload)
            self.tracker.log_event(
                "sync",
                f"Received {len(message.headers)} headers",
                details={"host": self.host, "port": self.port},
            )
        elif command == "block":
            self.tracker.log_event(
                "sync",
                "Unsolicited block message received",
                details={"host": self.host, "port": self.port, "length": len(payload)},
            )
        elif command == CompactBlockMessage.COMMAND:
            try:
                compact = CompactBlockMessage.deserialize(payload)
            except (ValueError, struct.error, IndexError) as exc:
                self.tracker.log_event(
                    "p2p",
                    f"Malformed cmpctblock: {exc}",
                    level="warning",
                    details={"host": self.host, "port": self.port},
                )
                return
            self._pending_compact_recovery = None
            block_hash_hex = compact.header.block_hash_hex()
            pool = self.mempool
            mapped: dict[bytes, Transaction] | None = None
            if pool is not None:
                scanner = getattr(pool, "iter_pooled_transactions", None)
                if callable(scanner):
                    mapped = mempool_short_id_transaction_map(compact, scanner())

            filled: tuple[Transaction, ...] | None = None
            awaiting_blocktxn = False

            if mapped is not None:
                miss = missing_indexes_for_getblocktxn(compact, mapped)
                if miss is None:
                    self.tracker.log_event(
                        "p2p",
                        "Malformed cmpctblock layout",
                        details={"host": self.host, "port": self.port, "block_hash": block_hash_hex},
                        level="warning",
                    )
                elif miss:
                    req = tuple(sorted(miss))
                    gb = GetBlockTxnMessage(block_hash=compact.header.block_hash(), txn_indexes=req)
                    await self.send(gb.COMMAND, gb.serialize())
                    self._pending_compact_recovery = _PendingCompactBlockTxnRecovery(
                        compact=compact,
                        pool_shortid_map=mapped,
                        txn_indexes_sorted=req,
                    )
                    awaiting_blocktxn = True
                    self.tracker.log_event(
                        "p2p",
                        "cmpctblock missing pooled txs — sent getblocktxn",
                        details={
                            "host": self.host,
                            "port": self.port,
                            "block_hash": block_hash_hex,
                            "indexes_requested": list(req),
                        },
                        level="debug",
                    )
                    self.tracker.mark_wire_capability(
                        "ext.getblocktxn",
                        implemented=True,
                        verified_by="live",
                        notes="outbound getblocktxn for missing BIP152 short ids after cmpctblock",
                    )
                else:
                    try:
                        filled = reconstruct_compact_transactions(compact, mapped)
                    except (KeyError, ValueError):
                        filled = None

            if filled is not None:
                self.tracker.log_event(
                    "p2p",
                    "Compact block reconstructed from mempool",
                    details={
                        "host": self.host,
                        "port": self.port,
                        "block_hash": block_hash_hex,
                        "tx_count": len(filled),
                    },
                    level="debug",
                )
                self.tracker.mark_wire_capability(
                    "ext.cmpctblock",
                    implemented=True,
                    verified_by="live",
                    notes="reconstructed inbound cmpctblock from mempool (BIP152 wtxid short ids)",
                )
            elif awaiting_blocktxn:
                self.tracker.mark_wire_capability(
                    "ext.cmpctblock",
                    implemented=True,
                    verified_by="live",
                    notes="parsed inbound cmpctblock awaiting blocktxn via getblocktxn",
                )
            else:
                self.tracker.log_event(
                    "p2p",
                    "Compact block (cmpctblock) parsed",
                    details={
                        "host": self.host,
                        "port": self.port,
                        "block_hash": block_hash_hex,
                        "short_id_nonce": compact.short_id_nonce,
                        "shortid_count": len(compact.shortids),
                        "prefilled_count": len(compact.prefilled),
                    },
                )
                self.tracker.log_event(
                    "p2p",
                    "cmpctblock not fully reconstructed (no pooled map or mempool misses)",
                    details={"host": self.host, "port": self.port},
                    level="debug",
                )
                self.tracker.mark_wire_capability(
                    "ext.cmpctblock",
                    implemented=True,
                    verified_by="live",
                    notes="parsed inbound cmpctblock (partial / no pool iterator or mempool misses)",
                )
        elif command == BlockTxnMessage.COMMAND:
            pend = self._pending_compact_recovery
            try:
                blocktxn = BlockTxnMessage.deserialize(payload)
            except (ValueError, struct.error, IndexError) as exc:
                self.tracker.log_event(
                    "p2p",
                    f"Malformed blocktxn: {exc}",
                    level="warning",
                    details={"host": self.host, "port": self.port},
                )
                return

            if pend is None or blocktxn.block_hash != pend.compact.header.block_hash():
                self.tracker.log_event(
                    "p2p",
                    "blocktxn ignored (no pending recovery or mismatched hash)",
                    details={"host": self.host, "port": self.port},
                    level="debug",
                )
                return

            self._pending_compact_recovery = None
            merged = complete_compact_with_block_transactions(
                pend.compact,
                pend.pool_shortid_map,
                pend.txn_indexes_sorted,
                blocktxn.transactions,
            )
            if merged is None:
                self.tracker.log_event(
                    "p2p",
                    "blocktxn did not complete compact reconstruction",
                    level="warning",
                    details={
                        "host": self.host,
                        "port": self.port,
                        "block_hash": pend.compact.header.block_hash_hex(),
                    },
                )
                return

            bh_hex = pend.compact.header.block_hash_hex()
            self.tracker.log_event(
                "p2p",
                "Compact block reconstructed after blocktxn",
                details={
                    "host": self.host,
                    "port": self.port,
                    "block_hash": bh_hex,
                    "tx_count": len(merged),
                },
                level="debug",
            )
            self.tracker.mark_wire_capability(
                "ext.cmpctblock",
                implemented=True,
                verified_by="live",
                notes="reconstructed inbound cmpctblock after getblocktxn + blocktxn (BIP152)",
            )
        elif command == "tx":
            try:
                tx, consumed = Transaction.deserialize(payload)
                if consumed != len(payload):
                    raise ValueError("trailing bytes after transaction")
            except (ValueError, struct.error, IndexError) as exc:
                self.tracker.log_event(
                    "p2p",
                    f"Malformed tx message: {exc}",
                    level="warning",
                    details={"host": self.host, "port": self.port},
                )
                self._note_invalid_peer_message()
                return
            self.tracker.mark_wire_capability(
                "tx.tx.recv",
                implemented=True,
                verified_by="live",
                notes="deserialized inbound tx",
            )
            if self.mempool is None:
                return
            peer_endpoint = f"{self.host}:{self.port}"
            if accept_transaction(
                tx,
                self.tracker,
                settings=self.settings,
                peer_host=peer_endpoint,
                mempool_claimed_prevouts=self.mempool.claimed_prevouts_frozen(),
            ):
                if self.mempool.add(tx):
                    self.tracker.log_event(
                        "mempool",
                        "Accepted incoming transaction",
                        details={"peer": peer_endpoint, "txid": transaction_txid(tx)[::-1].hex()},
                    )
                    if self.relay_tx_accepted is not None:
                        await self.relay_tx_accepted(tx, self)
                else:
                    self.tracker.log_event(
                        "mempool",
                        "Transaction not pooled (duplicate or capacity)",
                        level="debug",
                        details={"peer": peer_endpoint, "txid": transaction_txid(tx)[::-1].hex()},
                    )
        elif command == RejectMessage.COMMAND:
            try:
                rej = RejectMessage.deserialize(payload)
            except ValueError as exc:
                self.tracker.log_event(
                    "p2p",
                    f"Malformed reject: {exc}",
                    level="warning",
                    details={"host": self.host, "port": self.port},
                )
                self._note_invalid_peer_message()
                return
            self._reject_rx_count += 1
            if self._ban_eligible_endpoint() and self.peer_id:
                self.tracker.increment_peer_ban_score(
                    self.host,
                    self.port,
                    ban_score_for_reject_ccode(rej.ccode),
                    peer_id=self.peer_id,
                )
            if (
                self._reject_rx_count == 40
                and self._ban_eligible_endpoint()
                and self.peer_id
            ):
                self.tracker.increment_peer_ban_score(
                    self.host,
                    self.port,
                    BAN_REJECT_FLOOD,
                    peer_id=self.peer_id,
                )
            data_prefix = rej.data[:32].hex()
            self.tracker.log_event(
                "p2p",
                "Peer reject received",
                level="warning",
                details={
                    "host": self.host,
                    "port": self.port,
                    "rejected_command": rej.message,
                    "ccode": rej.ccode,
                    "reason": rej.reason,
                    "data_bytes": len(rej.data),
                    "data_prefix_hex": data_prefix,
                },
            )
            self.tracker.mark_wire_capability(
                "ext.reject",
                implemented=True,
                verified_by="live",
                notes="parsed inbound reject (BIP61-style)",
            )
        elif command == GetDataMessage.COMMAND:
            gd = GetDataMessage.deserialize(payload)
            pending_tx = [iv for iv in gd.inventory if iv.type in TX_INVENTORY_TYPES]
            await reply_getdata_tx_inventory(self, self.mempool, self.tracker, pending_tx)

    async def request_headers(self, locator: list[bytes], hash_stop: bytes = b"\x00" * 32) -> HeadersMessage:
        msg = GetHeadersMessage(
            version=self.protocol_version,
            locator_hashes=locator,
            hash_stop=hash_stop,
        )
        await self.send(GetHeadersMessage.COMMAND, msg.serialize())
        payload = await self._read_until_command("headers", timeout=120.0)
        return HeadersMessage.deserialize(payload)


def resolve_seed(chain: ChainParams) -> tuple[str, int]:
    if not chain.dns_seeds:
        raise RuntimeError(f"No DNS seeds configured for {chain.name}")
    for seed in chain.dns_seeds:
        try:
            infos = socket.getaddrinfo(seed, chain.default_port, type=socket.SOCK_STREAM)
            if infos:
                host = infos[0][4][0]
                return host, chain.default_port
        except socket.gaierror:
            continue
    raise RuntimeError(f"Could not resolve any DNS seed for {chain.name}")
