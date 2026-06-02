from __future__ import annotations

import logging
from collections import defaultdict

from pybitnode.consensus.merkle import transaction_txid
from pybitnode.messages.transaction import Transaction

logger = logging.getLogger(__name__)


def _tx_serialized_weight_bytes(tx: Transaction) -> int:
    return len(tx.serialize(include_witness=True))


class OrphanPool:
    """
    Deferred transactions referencing prevouts absent from chain UTXO (and mempool overlay).

    Indexed by unresolved prevout keys so dependents can be reconsidered once parents arrive.

    Rejects enqueue when transaction count or serialized byte totals exceed caps.
    """

    __slots__ = ("max_size_bytes", "max_transactions", "_orphans", "_pending_by_prevout", "_size_bytes")

    def __init__(self, *, max_transactions: int = 1000, max_size_bytes: int = 512 * 1024) -> None:
        if max_transactions < 1:
            raise ValueError("max_transactions must be positive")
        if max_size_bytes < 1:
            raise ValueError("max_size_bytes must be positive")
        self.max_transactions = max_transactions
        self.max_size_bytes = max_size_bytes
        self._orphans: dict[bytes, _OrphanSlot] = {}
        self._pending_by_prevout: dict[tuple[bytes, int], set[bytes]] = defaultdict(set)
        self._size_bytes = 0

    def __len__(self) -> int:
        return len(self._orphans)

    def total_size_bytes(self) -> int:
        return self._size_bytes

    def contains(self, txid: bytes) -> bool:
        return txid in self._orphans

    def get(self, txid: bytes) -> Transaction | None:
        slot = self._orphans.get(txid)
        return slot.tx if slot else None

    def remove(self, txid: bytes) -> bool:
        slot = self._orphans.pop(txid, None)
        if slot is None:
            return False
        self._purge_prevout_refs(txid, slot.unresolved)
        self._size_bytes -= slot.size_bytes
        return True

    def try_add(self, tx: Transaction, missing_prevouts: set[tuple[bytes, int]]) -> bool:
        """Queue tx keyed by unresolved prevouts, or bump an existing orphan entry."""
        if not missing_prevouts:
            return False

        txid = transaction_txid(tx)
        size = _tx_serialized_weight_bytes(tx)

        if txid in self._orphans:
            self.remove(txid)

        if len(self._orphans) >= self.max_transactions:
            logger.debug("orphan pool: reject tx %s (count cap)", txid[::-1].hex())
            return False
        if self._size_bytes + size > self.max_size_bytes:
            logger.debug("orphan pool: reject tx %s (size cap)", txid[::-1].hex())
            return False

        slot = _OrphanSlot(tx=tx, unresolved=set(missing_prevouts))
        self._orphans[txid] = slot
        self._size_bytes += size
        for key in slot.unresolved:
            self._pending_by_prevout[key].add(txid)
        return True

    def _purge_prevout_refs(self, txid: bytes, prevouts: set[tuple[bytes, int]]) -> None:
        for key in prevouts:
            pend = self._pending_by_prevout.get(key)
            if pend is None:
                continue
            pend.discard(txid)
            if not pend:
                del self._pending_by_prevout[key]

    def take_ready_transactions_for_prevout(self, prevout: tuple[bytes, int]) -> list[Transaction]:
        """
        Prevout is assumed spendable via chain UTXO or pooled parent outputs overlay.
        Returns orphans that waited on prevout plus any other unresolved prevouts — now cleared.
        """
        txids = list(self._pending_by_prevout.pop(prevout, ()))
        detached: list[Transaction] = []
        for oid in txids:
            slot = self._orphans.get(oid)
            if slot is None:
                continue
            deps_before = frozenset(slot.unresolved)
            slot.unresolved.discard(prevout)
            if slot.unresolved:
                continue
            self._orphans.pop(oid, None)
            self._purge_prevout_refs(oid, set(deps_before))
            self._size_bytes -= slot.size_bytes
            detached.append(slot.tx)
        return detached

    def unresolved_prevouts_snapshot(self, txid: bytes) -> frozenset[tuple[bytes, int]] | None:
        slot = self._orphans.get(txid)
        return frozenset(slot.unresolved) if slot else None

    def clear(self) -> None:
        self._orphans.clear()
        self._pending_by_prevout.clear()
        self._size_bytes = 0


class _OrphanSlot:
    __slots__ = ("tx", "unresolved", "size_bytes")

    def __init__(
        self,
        *,
        tx: Transaction,
        unresolved: set[tuple[bytes, int]],
        size_bytes: int | None = None,
    ) -> None:
        self.tx = tx
        self.unresolved = unresolved
        self.size_bytes = size_bytes if size_bytes is not None else _tx_serialized_weight_bytes(tx)
