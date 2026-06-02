from __future__ import annotations

from collections.abc import Iterable, Mapping
from dataclasses import dataclass

from pybitnode.consensus.block import Block
from pybitnode.consensus.witness import transaction_wtxid
from pybitnode.messages.bip152_short_txid import presalted_short_id_from_uint256_digest, short_id_nonce_key
from pybitnode.messages.headers import BlockHeader
from pybitnode.messages.transaction import Transaction, WITNESS_MARKER
from pybitnode.wire.serialize import pack_uint64_le, read_varint, unpack_uint64_le, write_varint


def bitcoin_short_transaction_id(header: BlockHeader, short_id_nonce: int, tx: Transaction) -> bytes:
    """Witness-hash compact short identifier (six bytes LE) compatible with Bitcoin Core."""

    keys = short_id_nonce_key(header, short_id_nonce)
    return presalted_short_id_from_uint256_digest(keys[0], keys[1], transaction_wtxid(tx))


def reconstruct_compact_transactions(
    compact: CompactBlockMessage,
    txs_by_shortid: Mapping[bytes, Transaction],
) -> tuple[Transaction, ...]:
    """
    Merge prefilled txs and ``shortids`` in ascending block-slot order per BIP152.
    """

    total = len(compact.shortids) + len(compact.prefilled)

    prefilled_by_index = {pf.index: pf.tx for pf in compact.prefilled}
    gaps = _compact_non_prefilled_shortid_slots(compact)

    txs_out: list[Transaction] = []
    gid = 0
    for pos in range(total):
        if pos in prefilled_by_index:
            txs_out.append(prefilled_by_index[pos])
            continue
        sid = gaps[gid][1]
        gid += 1
        tx = txs_by_shortid.get(sid)
        if tx is None:
            raise KeyError(f"missing compact short ID for block position {pos}")
        txs_out.append(tx)

    assert gid == len(gaps)
    return tuple(txs_out)


def serialize_block_wire(header: BlockHeader, transactions: tuple[Transaction, ...]) -> bytes:
    """Consensus block serialization matching :meth:`pybitnode.consensus.block.Block.deserialize`."""

    payload = header.serialize()
    payload += write_varint(len(transactions))
    witness_block = any(bool(tx.witness) for tx in transactions)
    if witness_block:
        payload += WITNESS_MARKER
    for tx in transactions:
        payload += tx.serialize(include_witness=witness_block)
    return payload


def reconstruct_compact_block_wire(
    compact: CompactBlockMessage,
    txs_by_shortid: Mapping[bytes, Transaction],
) -> bytes:
    txs = reconstruct_compact_transactions(compact, txs_by_shortid)
    return serialize_block_wire(compact.header, txs)


def reconstructed_block(
    compact: CompactBlockMessage,
    txs_by_shortid: Mapping[bytes, Transaction],
) -> Block:
    return Block(header=compact.header, transactions=reconstruct_compact_transactions(compact, txs_by_shortid))


def try_reconstruct_compact_block(
    compact: CompactBlockMessage,
    pooled_transactions: Iterable[Transaction],
) -> tuple[Transaction, ...] | None:
    """
    Convenience for inbound ``cmpctblock`` handling: map pooled txs by short ID, then reconstruct.

    Returns ``None`` on short-ID collision among pooled txs or any reconstruction error.
    """

    by_sid = mempool_short_id_transaction_map(compact, pooled_transactions)
    if by_sid is None:
        return None
    if missing_indexes_for_getblocktxn(compact, by_sid):
        return None
    try:
        return reconstruct_compact_transactions(compact, by_sid)
    except (KeyError, ValueError):
        return None


def mempool_short_id_transaction_map(
    compact: CompactBlockMessage,
    pooled_transactions: Iterable[Transaction],
) -> dict[bytes, Transaction] | None:
    """
    Maps pooled txs to their BIP152 short IDs under ``compact``. Returns ``None`` on SID collision (distinct wTXID).

    Matches the pool half of ``try_reconstruct_compact_block``.
    """

    by_sid: dict[bytes, Transaction] = {}
    for tx in pooled_transactions:
        sid = bitcoin_short_transaction_id(compact.header, compact.short_id_nonce, tx)
        existing = by_sid.get(sid)
        if existing is None:
            by_sid[sid] = tx
        elif transaction_wtxid(existing) != transaction_wtxid(tx):
            return None
    return by_sid


def _compact_non_prefilled_shortid_slots(compact: CompactBlockMessage) -> tuple[tuple[int, bytes], ...]:
    """Validates ``cmpctblock`` layout; returns ascending ``(block_index, shortid)`` gaps."""

    n_short = len(compact.shortids)
    n_pf = len(compact.prefilled)
    total = n_short + n_pf

    prefilled_by_index = {pf.index: pf.tx for pf in compact.prefilled}
    if len(prefilled_by_index) != n_pf:
        raise ValueError("duplicate prefilled transaction index in compact block")
    for idx in prefilled_by_index:
        if idx < 0:
            raise ValueError("prefilled transaction index negative")
        if idx >= total:
            raise ValueError("prefilled index out of range for reconstructed block tx count")

    slots_needing_sid = sum(1 for pos in range(total) if pos not in prefilled_by_index)
    if slots_needing_sid != n_short:
        raise ValueError("prefilled gaps do not align with compact shortid vector length")

    short_iter = iter(compact.shortids)
    gaps: list[tuple[int, bytes]] = []
    try:
        for pos in range(total):
            if pos in prefilled_by_index:
                continue
            sid = next(short_iter)
            gaps.append((pos, sid))
    except StopIteration as exc:
        raise ValueError("not enough shortids for non-prefilled block positions") from exc

    try:
        next(short_iter)
    except StopIteration:
        pass
    else:
        raise ValueError("too many shortids for reconstructed block transaction count")

    return tuple(gaps)


def missing_indexes_for_getblocktxn(
    compact: CompactBlockMessage,
    txs_by_shortid: Mapping[bytes, Transaction],
) -> tuple[int, ...] | None:
    """
    Indexes (absolute block positions) whose short IDs are not in ``txs_by_shortid``.

    Sorted ascending for ``getblocktxn``. Returns ``None`` if compact layout is invalid.
    """

    try:
        gaps = _compact_non_prefilled_shortid_slots(compact)
    except ValueError:
        return None
    missing = sorted(pos for pos, sid in gaps if txs_by_shortid.get(sid) is None)
    return tuple(missing)


def complete_compact_with_block_transactions(
    compact: CompactBlockMessage,
    pool_map: Mapping[bytes, Transaction],
    indexes_requested_sorted: tuple[int, ...],
    reply_transactions: tuple[Transaction, ...],
) -> tuple[Transaction, ...] | None:
    """
    Merge ``pool_map`` plus ``reply_transactions`` after a ``blocktxn``, then reconstruct wire order.

    Returns ``None`` on length/hash/short-ID mismatch or invalid compact layout.
    """

    try:
        gaps = _compact_non_prefilled_shortid_slots(compact)
    except ValueError:
        return None
    idx_to_sid = {pos: sid for pos, sid in gaps}

    ix = tuple(sorted(indexes_requested_sorted))
    if len(ix) != len(reply_transactions):
        return None

    merged: dict[bytes, Transaction] = dict(pool_map)
    for pos, reply_tx in zip(ix, reply_transactions):
        expected_sid = idx_to_sid.get(pos)
        if expected_sid is None:
            return None
        computed = bitcoin_short_transaction_id(compact.header, compact.short_id_nonce, reply_tx)
        if computed != expected_sid:
            return None
        merged[expected_sid] = reply_tx
    try:
        return reconstruct_compact_transactions(compact, merged)
    except (KeyError, ValueError):
        return None


@dataclass(frozen=True)
class PrefilledTransaction:
    """One prefilled transaction inside a BIP152 ``cmpctblock`` (absolute block tx index)."""

    index: int
    tx: Transaction


@dataclass(frozen=True)
class CompactBlockMessage:
    """
    BIP152 ``cmpctblock`` HeaderAndShortIDs parsing/serialization plus reconstruction helpers.
    """

    header: BlockHeader
    short_id_nonce: int
    shortids: tuple[bytes, ...]
    prefilled: tuple[PrefilledTransaction, ...]
    COMMAND = "cmpctblock"

    def serialize(self) -> bytes:
        payload = self.header.serialize()
        payload += pack_uint64_le(self.short_id_nonce)
        payload += write_varint(len(self.shortids))
        for sid in self.shortids:
            if len(sid) != 6:
                raise ValueError("each shortid must be exactly 6 bytes")
            payload += sid
        payload += write_varint(len(self.prefilled))
        prev_index = -1
        for i, pf in enumerate(self.prefilled):
            diff = pf.index if i == 0 else pf.index - prev_index - 1
            if diff < 0:
                raise ValueError("prefilled transactions must be ordered by increasing index")
            payload += write_varint(diff)
            payload += pf.tx.serialize()
            prev_index = pf.index
        return payload

    @classmethod
    def deserialize(cls, payload: bytes) -> CompactBlockMessage:
        if len(payload) < 88:
            raise ValueError("cmpctblock too short for header and short_id_nonce")
        header, offset = BlockHeader.deserialize(payload, 0)
        short_id_nonce, offset = unpack_uint64_le(payload, offset)
        n_short, offset = read_varint(payload, offset)
        need_short = n_short * 6
        if offset + need_short > len(payload):
            raise ValueError("cmpctblock shortid bytes truncated")
        shortids = [payload[offset + i * 6 : offset + (i + 1) * 6] for i in range(n_short)]
        offset += need_short
        n_prefill, offset = read_varint(payload, offset)
        prefilled: list[PrefilledTransaction] = []
        prev_abs = -1
        for _ in range(n_prefill):
            delta, offset = read_varint(payload, offset)
            abs_index = delta if not prefilled else prev_abs + 1 + delta
            if abs_index <= prev_abs:
                raise ValueError("prefilled transaction indices must be strictly increasing")
            tx, offset = Transaction.deserialize(payload, offset)
            prefilled.append(PrefilledTransaction(index=abs_index, tx=tx))
            prev_abs = abs_index
        if offset != len(payload):
            raise ValueError("trailing bytes after cmpctblock")
        return cls(
            header=header,
            short_id_nonce=short_id_nonce,
            shortids=tuple(shortids),
            prefilled=tuple(prefilled),
        )


@dataclass(frozen=True)
class GetBlockTxnMessage:
    """BIP152 ``getblocktxn``: block hash plus absolute transaction indexes."""

    block_hash: bytes
    txn_indexes: tuple[int, ...]
    COMMAND = "getblocktxn"

    def serialize(self) -> bytes:
        if len(self.block_hash) != 32:
            raise ValueError("block hash must be 32 bytes")
        buf = bytearray(self.block_hash)
        buf.extend(write_varint(len(self.txn_indexes)))
        for ix in self.txn_indexes:
            buf.extend(write_varint(ix))
        return bytes(buf)

    @classmethod
    def deserialize(cls, payload: bytes) -> GetBlockTxnMessage:
        if len(payload) < 32:
            raise ValueError("getblocktxn payload too short for block hash")
        block_hash = payload[:32]
        n_indexes, offset = read_varint(payload, 32)
        indexes: list[int] = []
        for _ in range(n_indexes):
            ix, offset = read_varint(payload, offset)
            indexes.append(ix)
        if offset != len(payload):
            raise ValueError("trailing bytes after getblocktxn indexes")
        return cls(block_hash=block_hash, txn_indexes=tuple(indexes))


@dataclass(frozen=True)
class BlockTxnMessage:
    """BIP152 ``blocktxn`` with requested transactions."""

    block_hash: bytes
    transactions: tuple[Transaction, ...]
    COMMAND = "blocktxn"

    def serialize(self) -> bytes:
        if len(self.block_hash) != 32:
            raise ValueError("block hash must be 32 bytes")
        buf = bytearray(self.block_hash)
        buf.extend(write_varint(len(self.transactions)))
        witness_mode = any(bool(tx.witness) for tx in self.transactions)
        for tx in self.transactions:
            buf.extend(tx.serialize(include_witness=witness_mode))
        return bytes(buf)

    @classmethod
    def deserialize(cls, payload: bytes) -> BlockTxnMessage:
        if len(payload) < 32:
            raise ValueError("blocktxn payload too short for block hash")
        block_hash = payload[:32]
        n_txn, offset = read_varint(payload, 32)
        txs: list[Transaction] = []
        for _ in range(n_txn):
            tx, offset = Transaction.deserialize(payload, offset)
            txs.append(tx)
        if offset != len(payload):
            raise ValueError("trailing bytes after blocktxn transactions")
        return cls(block_hash=block_hash, transactions=tuple(txs))
