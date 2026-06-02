from __future__ import annotations

import asyncio
import contextlib
import logging

from pybitnode.chain.params import ChainParams
from pybitnode.config import Settings
from pybitnode.db.tracker import ProjectTracker
from pybitnode.mempool import Mempool
from pybitnode.messages.block import BlockMessage, GetDataMessage, NotFoundMessage
from pybitnode.messages.headers import HeadersMessage
from pybitnode.messages.inventory import GetHeadersMessage, InventoryVector, TX_INVENTORY_TYPES
from pybitnode.p2p.ban_policy import BAN_HANDSHAKE_FAIL
from pybitnode.p2p.header_serving import build_headers_response
from pybitnode.p2p.peer import PeerConnection, reply_getdata_tx_inventory
from pybitnode.storage.blocks import BlockStore, block_hash_from_payload

logger = logging.getLogger(__name__)


async def handle_inbound_getdata(
    peer: PeerConnection,
    tracker: ProjectTracker,
    block_store: BlockStore,
    payload: bytes,
    *,
    mempool: Mempool | None = None,
) -> None:
    gd = GetDataMessage.deserialize(payload)
    _block_types = (InventoryVector.MSG_BLOCK, InventoryVector.MSG_WITNESS_BLOCK)
    block_ivs = [iv for iv in gd.inventory if iv.type in _block_types]
    rest = [iv for iv in gd.inventory if iv.type not in _block_types]

    nf_blocks: list[InventoryVector] = []
    served_block = False
    for iv in block_ivs:
        row = tracker.get_stored_block_for_hash_hex(iv.hash[::-1].hex())
        if row is None:
            nf_blocks.append(iv)
            continue
        try:
            block_bytes = block_store.read(row["file_name"], int(row["file_offset"]), int(row["size"]))
        except (OSError, ValueError):
            nf_blocks.append(iv)
            continue
        if block_hash_from_payload(block_bytes) != iv.hash:
            nf_blocks.append(iv)
            continue
        await peer.send(BlockMessage.COMMAND, block_bytes)
        served_block = True

    if served_block:
        tracker.mark_wire_capability(
            "serve.getdata.blocks",
            implemented=True,
            verified_by="live",
            notes="served MSG_BLOCK / MSG_WITNESS_BLOCK from BlockStore",
        )

    if nf_blocks:
        await peer.send(NotFoundMessage.COMMAND, NotFoundMessage(inventory=nf_blocks).serialize())

    tx_items = [iv for iv in rest if iv.type in TX_INVENTORY_TYPES]
    forward = [
        iv for iv in rest if iv.type not in TX_INVENTORY_TYPES and iv.type not in _block_types
    ]
    await reply_getdata_tx_inventory(peer, mempool, tracker, tx_items)
    if forward:
        await peer._dispatch(GetDataMessage.COMMAND, GetDataMessage(forward).serialize())


async def dispatch_inbound_message(
    peer: PeerConnection,
    *,
    tracker: ProjectTracker,
    chain: ChainParams,
    settings: Settings,
    block_store: BlockStore,
    mempool: Mempool | None = None,
    command: str,
    payload: bytes,
) -> None:
    if command == GetHeadersMessage.COMMAND:
        msg = GetHeadersMessage.deserialize(payload)
        reply = build_headers_response(tracker, chain, msg, block_store)
        await peer.send(HeadersMessage.COMMAND, reply.serialize())
        tracker.mark_wire_capability(
            "serve.getheaders",
            implemented=True,
            verified_by="live",
            notes=f"answered getheaders with {len(reply.headers)} headers",
        )
        return

    if command == GetDataMessage.COMMAND:
        await handle_inbound_getdata(peer, tracker, block_store, payload, mempool=mempool)
        return

    await peer._dispatch(command, payload)


def _normalize_peer(remote: object) -> tuple[str, int]:
    if remote is None:
        return ("unknown", 0)
    if isinstance(remote, (list, tuple)) and len(remote) >= 2:
        host_part, port_part = remote[0], remote[1]
        try:
            return str(host_part), int(port_part)
        except (TypeError, ValueError):
            pass
    return ("unknown", 0)


async def serve_inbound_session(
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
    *,
    chain: ChainParams,
    tracker: ProjectTracker,
    settings: Settings,
    block_store: BlockStore,
    mempool: Mempool | None = None,
) -> None:
    host, port = _normalize_peer(writer.get_extra_info("peername"))
    peer = PeerConnection(
        host=host,
        port=port,
        chain=chain,
        tracker=tracker,
        protocol_version=settings.protocol_version,
        user_agent=settings.user_agent,
        start_height=int((tracker.get_sync_state(chain.name) or {}).get("best_height", 0)),
        ping_interval=settings.ping_interval_seconds,
        stale_timeout=settings.peer_stale_seconds,
        settings=settings,
        mempool=mempool,
    )
    peer.reader = reader
    peer.writer = writer
    try:
        await peer.accept_inbound()
    except (
        asyncio.IncompleteReadError,
        TimeoutError,
        ConnectionError,
        ValueError,
        OSError,
    ) as exc:
        logger.warning("Inbound handshake failed from %s:%s: %s", host, port, exc)
        if host != "unknown" and port > 0:
            tracker.increment_peer_ban_score(host, port, BAN_HANDSHAKE_FAIL)
        writer.close()
        with contextlib.suppress(ConnectionError, OSError, TimeoutError):
            await writer.wait_closed()
        return

    try:
        async def handle_inbound_command(command: str, payload: bytes) -> None:
            await dispatch_inbound_message(
                peer,
                tracker=tracker,
                chain=chain,
                settings=settings,
                block_store=block_store,
                mempool=mempool,
                command=command,
                payload=payload,
            )

        await peer.consume_messages(handle_inbound_command)
    finally:
        peer._running = False
        await peer.close()


async def serve_inbound(
    *,
    chain: ChainParams,
    tracker: ProjectTracker,
    settings: Settings,
    block_store: BlockStore,
    mempool: Mempool | None = None,
) -> None:
    bind_port = settings.p2p_port or chain.default_port
    bind_host = "0.0.0.0"

    async def _client(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        rh, rp = _normalize_peer(writer.get_extra_info("peername"))
        logger.info("Inbound connection from %s:%s", rh, rp)
        await serve_inbound_session(
            reader,
            writer,
            chain=chain,
            tracker=tracker,
            settings=settings,
            block_store=block_store,
            mempool=mempool,
        )

    server = await asyncio.start_server(_client, host=bind_host, port=bind_port)
    sockets = getattr(server, "sockets", None) or ()
    ports = sorted({sock.getsockname()[1] for sock in sockets if sock})
    tracker.log_event(
        "node",
        f"Inbound TCP listening on {bind_host}:{bind_port}",
        details={"ports": ports, "listen": settings.listen},
    )
    tracker.mark_wire_capability(
        "transport.inbound",
        implemented=True,
        verified_by="live",
        notes="asyncio TCP listener accepting peers",
    )
    async with server:
        await server.serve_forever()
