from __future__ import annotations

import logging
import time
from collections.abc import Collection, Iterator, Mapping

from pybitnode.consensus.merkle import transaction_txid
from pybitnode.consensus.script.verify import ScriptVerifyError, verify_transaction_input
from pybitnode.consensus.witness import transaction_wtxid
from pybitnode.config import Settings
from pybitnode.chainstate.tracker import ProjectTracker
from pybitnode.messages.inventory import InventoryVector
from pybitnode.messages.transaction import TxIn, Transaction

from pybitnode.mempool.orphan_pool import OrphanPool

logger = logging.getLogger(__name__)


class _MempoolEntry:
    __slots__ = ("added_at", "tx")

    def __init__(self, *, tx: Transaction, added_at: float) -> None:
        self.tx = tx
        self.added_at = added_at


def _input_prevout_key(tx_in: TxIn) -> tuple[bytes, int]:
    return (tx_in.previous_output.hash, tx_in.previous_output.index)


def estimate_tx_virtual_size_scaffold(tx: Transaction) -> int:
    """Coarse virtual-size stand-in: non-witness serialization length (vbytes scaffold)."""
    return max(1, len(tx.serialize(include_witness=False)))


def _transaction_fee_known_prevouts(tx: Transaction, tracker: ProjectTracker) -> int | None:
    """Return fee in satoshis when every non-coinbase input prevout resolves in tracker UTXO set."""
    if tx.is_coinbase:
        return None
    spent = 0
    for inp in tx.inputs:
        row = tracker.get_utxo(inp.previous_output.hash, inp.previous_output.index)
        if row is None:
            return None
        spent += int(row["value"])
    out_sum = sum(out.value for out in tx.outputs)
    return spent - out_sum


def _effective_utxo_row(
    tracker: ProjectTracker,
    mempool_utxo_overlay: Mapping[tuple[bytes, int], dict] | None,
    tx_in: TxIn,
) -> dict | None:
    k = _input_prevout_key(tx_in)
    row_internal = tracker.get_utxo(tx_in.previous_output.hash, tx_in.previous_output.index)
    if row_internal is not None:
        return row_internal
    if mempool_utxo_overlay is None:
        return None
    return mempool_utxo_overlay.get(k)


def collect_missing_prevouts(
    tx: Transaction,
    tracker: ProjectTracker,
    *,
    mempool_utxo_overlay: Mapping[tuple[bytes, int], dict] | None = None,
    mempool_claimed_prevouts: Collection[tuple[bytes, int]] | None = None,
) -> set[tuple[bytes, int]] | None:
    """
    Prevouts unavailable through tracker (+ optional mempool overlay).

    Returns None on duplicate-prevout-within-tx or mempool-prevout-conflict guards (mirrors admission).
    Empty set means every referenced prevout resolves in the given view (no script checks).
    """
    if tx.is_coinbase:
        return set()
    if not tx.inputs or not tx.outputs:
        return set()
    seen_prevouts: set[tuple[bytes, int]] = set()
    missing: set[tuple[bytes, int]] = set()
    for tx_in in tx.inputs:
        key = _input_prevout_key(tx_in)
        if key in seen_prevouts:
            return None
        seen_prevouts.add(key)
        if mempool_claimed_prevouts is not None and key in mempool_claimed_prevouts:
            return None
        row = _effective_utxo_row(tracker, mempool_utxo_overlay, tx_in)
        if row is None:
            missing.add(key)
    return missing


def accept_transaction(
    tx: Transaction,
    tracker: ProjectTracker,
    *,
    settings: Settings | None = None,
    peer_host: str = "",
    mempool_claimed_prevouts: Collection[tuple[bytes, int]] | None = None,
    mempool_utxo_overlay: Mapping[tuple[bytes, int], dict] | None = None,
    orphan_pool: OrphanPool | None = None,
    defer_orphans: bool = False,
) -> bool:
    """
    Mempool admission: structural checks, UTXO + script verification per input,
    intra-tx duplicate prevout rejection, optional conflict with txs already pooled,
    non-negative fee, and optional minimum relay fee rate when configured.
    """
    if tx.is_coinbase:
        tracker.log_event(
            "mempool",
            "Rejected coinbase relay",
            level="warning",
            details={"peer": peer_host},
        )
        return False
    if not tx.inputs:
        tracker.log_event(
            "mempool",
            "Rejected tx: no inputs",
            level="warning",
            details={"peer": peer_host},
        )
        return False
    if not tx.outputs:
        tracker.log_event(
            "mempool",
            "Rejected tx: no outputs",
            level="warning",
            details={"peer": peer_host},
        )
        return False

    resolved = settings or Settings()
    min_feerate = int(resolved.min_relay_feerate_sat_vb)
    allow_orphan_enqueue = orphan_pool is not None and defer_orphans and resolved.enable_orphan_pool

    seen_prevouts: set[tuple[bytes, int]] = set()
    input_total_sat = 0
    missing_prevouts: set[tuple[bytes, int]] = set()
    rows_for_inputs: list[dict | None] = [None] * len(tx.inputs)

    for input_index, tx_in in enumerate(tx.inputs):
        key = _input_prevout_key(tx_in)

        if key in seen_prevouts:
            tracker.log_event(
                "mempool",
                "Rejected tx: duplicate prevout spends in single transaction",
                level="warning",
                details={"peer": peer_host, "duplicate_prevout_index": tx_in.previous_output.index},
            )
            return False
        seen_prevouts.add(key)

        if mempool_claimed_prevouts is not None and key in mempool_claimed_prevouts:
            tracker.log_event(
                "mempool",
                "Rejected tx: mempool already spends this prevout",
                level="warning",
                details={
                    "peer": peer_host,
                    "spent_txid": tx_in.previous_output.hash[::-1].hex(),
                    "spent_vout": tx_in.previous_output.index,
                },
            )
            return False

        row = _effective_utxo_row(tracker, mempool_utxo_overlay, tx_in)
        if row is None:
            missing_prevouts.add(key)
            continue
        rows_for_inputs[input_index] = row

    if missing_prevouts:
        if allow_orphan_enqueue:
            enqueued_to_orphans = orphan_pool.try_add(tx, missing_prevouts)
            if enqueued_to_orphans:
                tracker.log_event(
                    "mempool",
                    "Deferred tx: queued in orphan pool (missing prevouts)",
                    level="warning",
                    details={
                        "peer": peer_host,
                        "missing_prevouts": [(h[::-1].hex(), v) for (h, v) in sorted(missing_prevouts)],
                    },
                )
                return False
            tracker.log_event(
                "mempool",
                "Rejected tx: orphan pool capacity exhausted",
                level="warning",
                details={
                    "peer": peer_host,
                    "missing_prevouts": [(h[::-1].hex(), v) for (h, v) in sorted(missing_prevouts)],
                },
            )
            return False
        tracker.log_event(
            "mempool",
            "Rejected tx: unknown prevouts (not in effective UTXO view)",
            level="warning",
            details={
                "peer": peer_host,
                "missing_prevouts": [(h[::-1].hex(), v) for (h, v) in sorted(missing_prevouts)],
            },
        )
        return False

    spent_prevouts = tuple((int(row["value"]), bytes.fromhex(row["script_pubkey"])) for row in rows_for_inputs)

    for input_index, tx_in in enumerate(tx.inputs):
        row = rows_for_inputs[input_index]
        script_pubkey = bytes.fromhex(row["script_pubkey"])
        amount = int(row["value"])
        try:
            verify_transaction_input(
                tx,
                input_index,
                script_pubkey=script_pubkey,
                amount=amount,
                spent_prevouts=spent_prevouts,
            )
        except ScriptVerifyError as exc:
            tracker.log_event(
                "mempool",
                f"Rejected tx: script/input verification failed: {exc}",
                level="warning",
                details={"peer": peer_host, "input_index": input_index},
            )
            return False
        input_total_sat += amount

    output_total_sat = sum(out.value for out in tx.outputs)
    if output_total_sat > input_total_sat:
        tracker.log_event(
            "mempool",
            "Rejected tx: outputs exceed inputs (negative fee)",
            level="warning",
            details={"peer": peer_host, "input_total_sat": input_total_sat, "output_total_sat": output_total_sat},
        )
        return False

    fee = input_total_sat - output_total_sat
    if min_feerate > 0:
        vsize = estimate_tx_virtual_size_scaffold(tx)
        if vsize <= 0:
            return False
        required = min_feerate * vsize
        if fee < required:
            tracker.log_event(
                "mempool",
                "Rejected tx: fee rate below min relay",
                level="warning",
                details={
                    "peer": peer_host,
                    "fee": fee,
                    "vbytes_approx": vsize,
                    "min_sat_vbyte": min_feerate,
                },
            )
            return False

    return True


def transaction_meets_peer_feefilter(
    tx: Transaction,
    tracker: ProjectTracker,
    peer_fee_filter_sat_kvb: int | None,
) -> bool:
    """
    Decide whether announcing this tx satisfies a peer feefilter (BIP133, sat/kvB on wire).
    Missing filter before first feefilter (None) relays; filter 0 means no minimum.
    Unknown fee inputs defer to announcing (minimal relay policy).
    """
    if peer_fee_filter_sat_kvb is None or peer_fee_filter_sat_kvb <= 0:
        return True
    vsize = estimate_tx_virtual_size_scaffold(tx)
    if vsize <= 0:
        return False
    fee = _transaction_fee_known_prevouts(tx, tracker)
    if fee is None or fee < 0:
        return True
    return fee * 1000 >= peer_fee_filter_sat_kvb * vsize


class Mempool:
    """Simple txid-keyed mempool with deduplication and a byte budget."""

    __slots__ = (
        "_by_wtxid",
        "_claimed_prevouts",
        "_max_age_seconds",
        "_max_size_bytes",
        "_max_tx_count",
        "_orphan_pool",
        "_size_bytes",
        "_spenders",
        "_tracker",
        "_tx_by_id",
    )

    def __init__(
        self,
        *,
        max_size_bytes: int = 32 * 1024 * 1024,
        tracker: ProjectTracker | None = None,
        orphan_pool: OrphanPool | None = None,
        mempool_max_count: int | None = None,
        mempool_max_age_seconds: int | None = None,
        settings: Settings | None = None,
    ) -> None:
        if max_size_bytes < 1:
            raise ValueError("max_size_bytes must be positive")
        policy = settings if settings is not None else Settings.from_env()
        max_tx_count = policy.mempool_max_count if mempool_max_count is None else mempool_max_count
        max_age_seconds = policy.mempool_max_age_seconds if mempool_max_age_seconds is None else mempool_max_age_seconds
        if max_tx_count < 0:
            raise ValueError("mempool_max_count must be >= 0 (0 means unlimited)")
        if max_age_seconds < 0:
            raise ValueError("mempool_max_age_seconds must be >= 0 (0 disables age eviction)")
        self._max_size_bytes = max_size_bytes
        self._max_tx_count = max_tx_count
        self._max_age_seconds = max_age_seconds
        self._tracker = tracker
        self._orphan_pool = orphan_pool
        self._tx_by_id: dict[bytes, _MempoolEntry] = {}
        self._by_wtxid: dict[bytes, Transaction] = {}
        self._spenders: dict[bytes, set[bytes]] = {}
        self._claimed_prevouts: set[tuple[bytes, int]] = set()
        self._size_bytes = 0
        self._persist_stats()

    def _mempool_utxo_overlay(self) -> dict[tuple[bytes, int], dict]:
        rows: dict[tuple[bytes, int], dict] = {}
        for entry in self._tx_by_id.values():
            candidate = entry.tx
            prod_txid = transaction_txid(candidate)
            for vout_idx, tx_out in enumerate(candidate.outputs):
                rows[(prod_txid, vout_idx)] = {
                    "value": tx_out.value,
                    "script_pubkey": tx_out.script_pubkey.hex(),
                }
        return rows

    def _cluster_post_order(self, root: bytes) -> list[bytes]:
        """Descendants first, then root — safe removal order for dependent unconfirmed spends."""
        order: list[bytes] = []
        visiting: set[bytes] = set()

        def dfs(tid: bytes) -> None:
            if tid not in self._tx_by_id:
                return
            if tid in visiting:
                return
            visiting.add(tid)
            for child in list(self._spenders.get(tid, ())):
                dfs(child)
            visiting.discard(tid)
            order.append(tid)

        dfs(root)
        return order

    def _remove_single(self, txid: bytes) -> bool:
        entry = self._tx_by_id.pop(txid, None)
        if entry is None:
            return False
        tx = entry.tx
        self._by_wtxid.pop(transaction_wtxid(tx), None)
        for inp in tx.inputs:
            self._claimed_prevouts.discard(_input_prevout_key(inp))
            parent_id = inp.previous_output.hash
            spenders = self._spenders.get(parent_id)
            if spenders:
                spenders.discard(txid)
                if not spenders:
                    del self._spenders[parent_id]
        self._spenders.pop(txid, None)
        self._size_bytes -= self._serialized_len(tx)
        return True

    def _evict_oldest_cluster(self) -> int:
        if not self._tx_by_id:
            return 0
        root = min(self._tx_by_id.keys(), key=lambda tid: self._tx_by_id[tid].added_at)
        removed = 0
        for tid in self._cluster_post_order(root):
            if tid in self._tx_by_id and self._remove_single(tid):
                removed += 1
        return removed

    def _link_incoming_spenders(self, txid: bytes, tx: Transaction) -> None:
        for inp in tx.inputs:
            parent_id = inp.previous_output.hash
            if parent_id in self._tx_by_id:
                self._spenders.setdefault(parent_id, set()).add(txid)

    def evict_expired(self, now: float) -> int:
        """
        Remove txs older than mempool_max_age_seconds (Settings / constructor), including descendants.
        Returns the number of pooled transactions removed.
        """
        if self._max_age_seconds <= 0:
            return 0
        removed = 0
        while True:
            expired = [
                tid
                for tid, entry in self._tx_by_id.items()
                if now - entry.added_at > self._max_age_seconds
            ]
            if not expired:
                self._persist_stats()
                return removed
            root = min(expired, key=lambda tid: self._tx_by_id[tid].added_at)
            for tid in self._cluster_post_order(root):
                if tid in self._tx_by_id and self._remove_single(tid):
                    removed += 1

    def evict_over_capacity(self) -> int:
        """
        Evict oldest-first transaction clusters until within byte and count limits.
        Returns the number of pooled transactions removed.
        """
        removed = 0
        while self._tx_by_id:
            over_count = self._max_tx_count > 0 and len(self._tx_by_id) > self._max_tx_count
            over_bytes = self._size_bytes > self._max_size_bytes
            if not over_count and not over_bytes:
                break
            n = self._evict_oldest_cluster()
            if n == 0:
                break
            removed += n
        self._persist_stats()
        return removed

    def _try_promote_orphans_for(self, producer: Transaction) -> None:
        if self._orphan_pool is None or self._tracker is None:
            return
        prod_txid = transaction_txid(producer)
        for vout_idx in range(len(producer.outputs)):
            for candidate in list(
                self._orphan_pool.take_ready_transactions_for_prevout((prod_txid, vout_idx))
            ):
                overlay = self._mempool_utxo_overlay()
                promote_settings = Settings(enable_orphan_pool=True)
                accepted_here = accept_transaction(
                    candidate,
                    self._tracker,
                    settings=promote_settings,
                    mempool_claimed_prevouts=self.claimed_prevouts_frozen(),
                    mempool_utxo_overlay=overlay,
                    orphan_pool=self._orphan_pool,
                    defer_orphans=True,
                )
                if accepted_here and self.add(candidate):
                    continue
                requeue = collect_missing_prevouts(
                    candidate,
                    self._tracker,
                    mempool_utxo_overlay=overlay,
                    mempool_claimed_prevouts=self.claimed_prevouts_frozen(),
                )
                if requeue is not None and requeue:
                    self._orphan_pool.try_add(candidate, set(requeue))

    def claimed_prevouts_frozen(self) -> frozenset[tuple[bytes, int]]:
        """Prevouts spent by txs currently pooled; used for mempool double-spend policy."""
        return frozenset(self._claimed_prevouts)

    def entry_added_at(self, txid: bytes) -> float | None:
        """Wall-clock timestamp when the tx was admitted; None if absent."""
        entry = self._tx_by_id.get(txid)
        return None if entry is None else entry.added_at

    def _persist_stats(self) -> None:
        if self._tracker is None:
            return
        self._tracker.set_meta("mempool_tx_count", str(len(self._tx_by_id)))
        self._tracker.set_meta("mempool_size_bytes", str(self._size_bytes))

    def __len__(self) -> int:
        return len(self._tx_by_id)

    def get(self, txid: bytes) -> Transaction | None:
        entry = self._tx_by_id.get(txid)
        return None if entry is None else entry.tx

    def iter_pooled_transactions(self) -> Iterator[Transaction]:
        """Iterate pooled transactions so P2P can resolve BIP152 short IDs."""

        yield from (e.tx for e in self._tx_by_id.values())

    def get_for_inv(self, *, inv_type: int, inv_hash: bytes) -> Transaction | None:
        """Resolve a getdata/inv hash (txid vs wtxid depends on inventory type)."""
        if inv_type == InventoryVector.MSG_WITNESS_TX:
            return self._by_wtxid.get(inv_hash)
        if inv_type == InventoryVector.MSG_TX:
            entry = self._tx_by_id.get(inv_hash)
            return None if entry is None else entry.tx
        return None

    def _serialized_len(self, tx: Transaction) -> int:
        return len(tx.serialize(include_witness=True))

    def contains(self, txid: bytes) -> bool:
        return txid in self._tx_by_id

    def add(self, tx: Transaction) -> bool:
        """
        Insert by txid. Returns False when duplicate or over capacity.
        Caller should run admission policy (e.g. accept_transaction) first.
        Applies age eviction then, when over limits, drops oldest-first clusters (optional policy).
        """
        txid = transaction_txid(tx)
        if txid in self._tx_by_id:
            return False
        now = time.time()
        self.evict_expired(now)
        size = self._serialized_len(tx)
        while self._max_tx_count > 0 and len(self._tx_by_id) >= self._max_tx_count:
            if self._evict_oldest_cluster() == 0:
                break
        while self._size_bytes + size > self._max_size_bytes:
            if self._evict_oldest_cluster() == 0:
                break
        if self._size_bytes + size > self._max_size_bytes:
            logger.debug("mempool capacity: reject tx %s (+%s bytes)", txid[::-1].hex(), size)
            return False
        if self._max_tx_count > 0 and len(self._tx_by_id) >= self._max_tx_count:
            logger.debug("mempool count cap: reject tx %s", txid[::-1].hex())
            return False
        wtxid = transaction_wtxid(tx)
        self._tx_by_id[txid] = _MempoolEntry(tx=tx, added_at=now)
        self._by_wtxid[wtxid] = tx
        self._link_incoming_spenders(txid, tx)
        for inp in tx.inputs:
            self._claimed_prevouts.add(_input_prevout_key(inp))
        self._size_bytes += size
        self._persist_stats()
        self._try_promote_orphans_for(tx)
        return True

    def remove(self, txid: bytes) -> bool:
        if not self._remove_single(txid):
            return False
        self._persist_stats()
        return True

    def total_size_bytes(self) -> int:
        return self._size_bytes
