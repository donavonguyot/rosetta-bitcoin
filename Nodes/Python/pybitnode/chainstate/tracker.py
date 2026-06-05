from __future__ import annotations

import json
import logging
import struct
from collections.abc import Iterable, Iterator
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from pybitnode.endpoint_parse import host_port_is_well_formed_endpoint
from pybitnode.wire.capabilities import (
    CAPABILITIES_BY_ID,
    checkpoint_status,
    full_node_wire_progress,
)

try:
    from rocksdict import Rdict, WriteBatch
except ImportError as exc:  # pragma: no cover - exercised by packaging/proof commands.
    Rdict = None  # type: ignore[assignment]
    WriteBatch = None  # type: ignore[assignment]
    _ROCKSDB_IMPORT_ERROR = exc
else:
    _ROCKSDB_IMPORT_ERROR = None


SCHEMA_VERSION = 1
NATIVE_MARKER = "pybitnode-native-chainstate-v1"
STATS_KEY = "default"
STATS_VERSION = 1
UTXO_CODEC_VERSION = "2"
UTXO_CODEC_MAGIC = b"pyutxo2\x00"
STAT_FIELDS = (
    "utxo_count",
    "header_count",
    "block_count",
    "max_header_height",
    "max_stored_block_height",
)

DEFAULT_PHASES = (
    ("phase0", "Wire + handshake", "in_progress", "Message framing, version/verack, Docker scaffold"),
    ("phase1", "Header sync", "pending", "Block locator, header chain persistence"),
    ("phase2", "Block download", "pending", "Parallel getdata, raw block storage"),
    ("phase3", "Consensus validation", "pending", "PoW, merkle root, and script verification in Python"),
    ("phase4", "Mempool + relay", "pending", "Tx admission and rebroadcast"),
    ("phase5", "Hardening", "pending", "Metrics, peer banning, optional BIP324"),
)

logger = logging.getLogger(__name__)


def _utcnow() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def _json_dumps(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def _json_loads(raw: bytes | str | None) -> Any:
    if raw is None:
        return None
    if isinstance(raw, bytes):
        raw = raw.decode()
    return json.loads(raw)


def _compact_size(value: int) -> bytes:
    if value < 0xFD:
        return bytes([value])
    if value <= 0xFFFF:
        return b"\xfd" + struct.pack("<H", value)
    if value <= 0xFFFF_FFFF:
        return b"\xfe" + struct.pack("<I", value)
    return b"\xff" + struct.pack("<Q", value)


def _read_compact_size(raw: bytes, offset: int) -> tuple[int, int]:
    first = raw[offset]
    offset += 1
    if first < 0xFD:
        return first, offset
    if first == 0xFD:
        return struct.unpack_from("<H", raw, offset)[0], offset + 2
    if first == 0xFE:
        return struct.unpack_from("<I", raw, offset)[0], offset + 4
    return struct.unpack_from("<Q", raw, offset)[0], offset + 8


def _part(value: object) -> str:
    return str(value).replace("|", "%7C")


class ProjectTracker:
    """RocksDB-backed operational state for Python native/Core mode.

    Native entry points fail closed when handed a legacy ``*.db`` path.
    """

    def __init__(self, state_path: str | Path) -> None:
        if Rdict is None:
            raise RuntimeError(
                "pybitnode native mode requires the 'rocksdict' package; "
                "official runtime storage is RocksDB"
            ) from _ROCKSDB_IMPORT_ERROR

        path = Path(state_path)
        if path.name == "pybitnode.db" or path.suffix in {".sqlite", ".sqlite3"}:
            raise RuntimeError(
                f"native mode requires a chainstate-rocksdb directory: {path}"
            )
        path.mkdir(parents=True, exist_ok=True)
        marker = path / "PYBITNODE_NATIVE_CHAINSTATE"
        if marker.exists() and marker.read_text().strip() != NATIVE_MARKER:
            raise RuntimeError(f"incompatible native chainstate marker: {marker}")
        marker.write_text(NATIVE_MARKER + "\n")

        self.path = path
        self._db = Rdict(str(path / "rocksdb"))
        self._txn_ops: list[tuple[str, bytes, bytes | None]] | None = None
        self._bootstrap()

    def close(self) -> None:
        self._db.close()

    @contextmanager
    def transaction(self) -> Iterator[None]:
        if self._txn_ops is not None:
            yield
            return
        self._txn_ops = []
        try:
            yield
        except Exception:
            self._txn_ops = None
            raise
        else:
            ops = self._txn_ops
            self._txn_ops = None
            self._write_ops(ops)

    def _key(self, namespace: str, *parts: object) -> bytes:
        joined = "|".join((namespace, *(_part(part) for part in parts)))
        return joined.encode()

    def _utxo_key(self, txid_hex: str, vout: int) -> bytes:
        return self._key("utxo", txid_hex, int(vout))

    def _decode_utxo_key(self, key: bytes) -> tuple[str, int]:
        parts = key.decode().split("|")
        if len(parts) != 3 or parts[0] != "utxo":
            raise ValueError(f"invalid utxo key: {key!r}")
        return parts[1], int(parts[2])

    def _prefix(self, namespace: str, *parts: object) -> bytes:
        return self._key(namespace, *parts) + b"|"

    def _get(self, namespace: str, *parts: object) -> Any:
        return _json_loads(self._db.get(self._key(namespace, *parts)))

    def _put(self, namespace: str, *parts: object, value: Any) -> None:
        key = self._key(namespace, *parts)
        raw = _json_dumps(value)
        if self._txn_ops is not None:
            self._txn_ops.append(("put", key, raw))
            return
        self._db[key] = raw

    def _delete(self, namespace: str, *parts: object) -> None:
        key = self._key(namespace, *parts)
        if self._txn_ops is not None:
            self._txn_ops.append(("delete", key, None))
            return
        try:
            del self._db[key]
        except KeyError:
            pass

    def _write_ops(self, ops: list[tuple[str, bytes, bytes | None]]) -> None:
        if not ops:
            return
        if WriteBatch is not None:
            batch = WriteBatch()
            for op, key, raw in ops:
                if op == "put":
                    batch.put(key, raw)
                else:
                    batch.delete(key)
            self._db.write(batch)
            return
        for op, key, raw in ops:
            if op == "put":
                self._db[key] = raw
            else:
                try:
                    del self._db[key]
                except KeyError:
                    pass

    def _iter_prefix(self, namespace: str, *parts: object) -> Iterator[tuple[bytes, Any]]:
        prefix = self._prefix(namespace, *parts)
        for key, raw in self._db.items():
            key_b = key if isinstance(key, bytes) else str(key).encode()
            if key_b.startswith(prefix):
                if namespace == "utxo":
                    yield key_b, self._decode_utxo_row(key_b, raw, include_script_bytes=False)
                else:
                    yield key_b, _json_loads(raw)

    def _all(self, namespace: str, *parts: object) -> list[dict]:
        return [dict(value) for _, value in self._iter_prefix(namespace, *parts)]

    def _count(self, namespace: str, *parts: object) -> int:
        return sum(1 for _ in self._iter_prefix(namespace, *parts))

    def _next_id(self, namespace: str) -> int:
        key = f"next_id:{namespace}"
        value = int(self.get_meta(key, "0") or "0") + 1
        self.set_meta(key, str(value))
        return value

    def _bootstrap(self) -> None:
        if self.get_meta("schema_version") is None:
            self.set_meta("schema_version", str(SCHEMA_VERSION))
            self.set_meta("node_version", "0.1.0")
            self.set_meta("backend_name", "rocksdb")
            self.set_meta("backend_version", self.rocksdb_version())
            self.set_meta("generation_id", _utcnow())
        if self.get_meta("codec_version") is None:
            self.set_meta("codec_version", "1")
        if self.get_meta("optimized_stats") is None:
            self.set_meta("optimized_stats", "true")
        if self.get_meta("native_multi_get") is None:
            self.set_meta("native_multi_get", "false")
        for phase, title, status, notes in DEFAULT_PHASES:
            if self._get("phase", phase) is None:
                self._put(
                    "phase",
                    phase,
                    value={
                        "phase": phase,
                        "title": title,
                        "status": status,
                        "notes": notes,
                        "updated_at": _utcnow(),
                    },
                )
        for cap_id, cap in CAPABILITIES_BY_ID.items():
            if self._get("wire_capability", cap_id) is None:
                self._put(
                    "wire_capability",
                    cap_id,
                    value={
                        "capability_id": cap.id,
                        "checkpoint": cap.checkpoint,
                        "category": cap.category,
                        "name": cap.name,
                        "description": cap.description,
                        "required": 1 if cap.required else 0,
                        "implemented": 1 if cap.implemented else 0,
                        "verified_by": "code" if cap.implemented else "",
                        "verified_at": _utcnow() if cap.implemented else "",
                        "notes": "",
                    },
                )
        if self._get("stats", STATS_KEY) is None:
            self.recompute_stats()

    def rocksdb_version(self) -> str:
        return getattr(self._db, "rocksdb_version", lambda: "unknown")()

    def set_meta(self, key: str, value: str) -> None:
        self._put("meta", key, value=value)

    def get_meta(self, key: str, default: str | None = None) -> str | None:
        value = self._get("meta", key)
        return default if value is None else str(value)

    def _empty_stats(self) -> dict[str, int | str]:
        return {
            "stats_version": STATS_VERSION,
            "updated_at": _utcnow(),
            "utxo_count": 0,
            "header_count": 0,
            "block_count": 0,
            "max_header_height": 0,
            "max_stored_block_height": 0,
        }

    def _stats_row(self) -> dict[str, int | str]:
        row = None
        if self._txn_ops is not None:
            stats_key = self._key("stats", STATS_KEY)
            for op, key, raw in reversed(self._txn_ops):
                if key == stats_key:
                    row = _json_loads(raw) if op == "put" else None
                    break
        if row is None:
            row = self._get("stats", STATS_KEY)
        if row is None:
            return self.recompute_stats()
        out = self._empty_stats()
        out.update(row)
        for field in STAT_FIELDS:
            out[field] = int(out.get(field, 0) or 0)
        return out

    def _put_stats(self, stats: dict[str, int | str]) -> None:
        row = dict(stats)
        row["stats_version"] = STATS_VERSION
        row["updated_at"] = _utcnow()
        self._put("stats", STATS_KEY, value=row)

    def _adjust_stat(self, field: str, delta: int = 0, *, max_value: int | None = None) -> None:
        stats = self._stats_row()
        if delta:
            stats[field] = max(0, int(stats.get(field, 0) or 0) + delta)
        if max_value is not None:
            stats[field] = max(int(stats.get(field, 0) or 0), max_value)
        self._put_stats(stats)

    def stats(self) -> dict[str, int | str]:
        return dict(self._stats_row())

    def recompute_stats(self) -> dict[str, int | str]:
        headers = self._all("header_by_height")
        blocks = self._all("block_by_height")
        stats = self._empty_stats()
        stats.update(
            {
                "utxo_count": self._count("utxo"),
                "header_count": len(headers),
                "block_count": len(blocks),
                "max_header_height": max((int(row["height"]) for row in headers), default=0),
                "max_stored_block_height": max((int(row["height"]) for row in blocks), default=0),
            }
        )
        self._put_stats(stats)
        return stats

    def update_phase(self, phase: str, *, status: str | None = None, notes: str | None = None) -> None:
        row = self._get("phase", phase)
        if row is None:
            raise KeyError(f"Unknown phase {phase!r}")
        if status is not None:
            row["status"] = status
        if notes is not None:
            row["notes"] = notes
        row["updated_at"] = _utcnow()
        self._put("phase", phase, value=row)

    def list_phases(self) -> list[dict]:
        return sorted(self._all("phase"), key=lambda row: row["phase"])

    def log_event(self, category: str, message: str, *, level: str = "info", details: dict | None = None) -> None:
        event_id = self._next_id("events")
        self._put(
            "event",
            f"{event_id:020d}",
            value={
                "id": event_id,
                "category": category,
                "level": level,
                "message": message,
                "details_json": json.dumps(details or {}),
                "created_at": _utcnow(),
            },
        )

    def recent_events(self, limit: int = 20) -> list[dict]:
        rows = self._all("event")
        rows.sort(key=lambda row: int(row["id"]), reverse=True)
        return rows[:limit]

    def list_events(self, *, category: str | None = None) -> list[dict]:
        rows = self._all("event")
        if category is not None:
            rows = [row for row in rows if row.get("category") == category]
        rows.sort(key=lambda row: int(row["id"]))
        return rows

    def upsert_sync_state(
        self,
        chain: str,
        *,
        best_height: int | None = None,
        best_hash: str | None = None,
        header_count: int | None = None,
        sync_status: str | None = None,
    ) -> None:
        existing = self.get_sync_state(chain) or {}
        self._put(
            "sync_state",
            chain,
            value={
                "chain": chain,
                "best_height": best_height if best_height is not None else int(existing.get("best_height", 0)),
                "best_hash": best_hash if best_hash is not None else str(existing.get("best_hash", "")),
                "header_count": header_count if header_count is not None else int(existing.get("header_count", 0)),
                "sync_status": sync_status if sync_status is not None else str(existing.get("sync_status", "starting")),
                "updated_at": _utcnow(),
            },
        )

    def get_sync_state(self, chain: str) -> dict | None:
        row = self._get("sync_state", chain)
        return dict(row) if row else None

    def record_peer_connected(
        self,
        host: str,
        port: int,
        *,
        direction: str = "outbound",
        services: int = 0,
        peer_version: int = 0,
        user_agent: str = "",
        start_height: int = 0,
    ) -> int:
        peer_id = self._next_id("peers")
        self._put(
            "peer",
            peer_id,
            value={
                "id": peer_id,
                "host": host,
                "port": port,
                "connected_at": _utcnow(),
                "disconnected_at": "",
                "direction": direction,
                "services": services,
                "peer_version": peer_version,
                "user_agent": user_agent,
                "start_height": start_height,
                "last_seen_at": _utcnow(),
                "ban_score": 0,
                "status": "connected",
            },
        )
        self.log_event("p2p", f"Connected to {host}:{port}", details={"peer_id": peer_id, "user_agent": user_agent})
        return peer_id

    def record_peer_disconnected(self, peer_id: int, *, status: str = "disconnected") -> None:
        row = self._get("peer", peer_id)
        if row:
            row.update({"disconnected_at": _utcnow(), "status": status})
            self._put("peer", peer_id, value=row)

    def get_peer(self, peer_id: int) -> dict | None:
        row = self._get("peer", peer_id)
        return dict(row) if row else None

    def touch_peer(self, peer_id: int) -> None:
        row = self._get("peer", peer_id)
        if row:
            row["last_seen_at"] = _utcnow()
            self._put("peer", peer_id, value=row)

    def record_peer_address(self, host: str, port: int, *, services: int = 0, source: str = "addr") -> None:
        if services >= 2**63:
            services -= 2**64
        if not host_port_is_well_formed_endpoint(host, port):
            logger.warning("peer_address_skipped_malformed host=%r port=%s source=%s", host, port, source)
            return
        existing = self._get("peer_address", host, port) or {}
        self._put(
            "peer_address",
            host,
            port,
            value={
                "host": host,
                "port": port,
                "services": services,
                "source": source,
                "last_seen_at": _utcnow(),
                "ban_score": int(existing.get("ban_score") or 0),
            },
        )

    def get_peer_endpoint_ban_score(self, host: str, port: int) -> int:
        row = self._get("peer_address", host, port)
        return int(row.get("ban_score") or 0) if row else 0

    def increment_peer_ban_score(self, host: str, port: int, delta: int, *, peer_id: int | None = None) -> int:
        score = self.get_peer_endpoint_ban_score(host, port) + delta
        existing = self._get("peer_address", host, port) or {
            "host": host,
            "port": port,
            "services": 0,
            "source": "ban",
        }
        existing.update({"ban_score": score, "last_seen_at": _utcnow()})
        self._put("peer_address", host, port, value=existing)
        if peer_id:
            peer = self._get("peer", peer_id)
            if peer:
                peer["ban_score"] = int(peer.get("ban_score") or 0) + delta
                self._put("peer", peer_id, value=peer)
        return score

    def decay_peer_ban_score(self, host: str, port: int, amount: int, *, peer_id: int | None = None) -> None:
        if amount <= 0:
            return
        score = max(0, self.get_peer_endpoint_ban_score(host, port) - amount)
        row = self._get("peer_address", host, port)
        if row:
            row.update({"ban_score": score, "last_seen_at": _utcnow()})
            self._put("peer_address", host, port, value=row)
        if peer_id:
            peer = self._get("peer", peer_id)
            if peer:
                peer["ban_score"] = max(0, int(peer.get("ban_score") or 0) - amount)
                self._put("peer", peer_id, value=peer)

    def list_peer_address_endpoints(self, *, limit: int = 32) -> list[tuple[str, int]]:
        rows = sorted(self._all("peer_address"), key=lambda row: row.get("last_seen_at", ""), reverse=True)
        out: list[tuple[str, int]] = []
        for row in rows:
            host, port = str(row["host"]), int(row["port"])
            if host_port_is_well_formed_endpoint(host, port):
                out.append((host, port))
            if len(out) >= limit:
                break
        return out

    def get_validated_height(self, chain: str = "testnet4") -> int:
        row = self._get("chain_state", chain)
        return int(row["validated_height"]) if row else 0

    def get_validated_hash(self, chain: str = "testnet4") -> str | None:
        row = self._get("chain_state", chain)
        if not row:
            return None
        return str(row["validated_hash"]) if row.get("validated_hash") else None

    def set_validated_tip(self, height: int, block_hash_hex: str, *, chain: str = "testnet4") -> None:
        self._put(
            "chain_state",
            chain,
            value={"chain": chain, "validated_height": height, "validated_hash": block_hash_hex, "updated_at": _utcnow()},
        )

    def reset_validated_chain(self, *, chain: str = "testnet4", genesis_hash: str) -> None:
        with self.transaction():
            for key, _ in list(self._iter_prefix("utxo")):
                if key.startswith(b"utxo|"):
                    self._delete_key(key)
            for key, _row in list(self._iter_prefix("utxo_undo", chain)):
                self._delete_key(key)
            stats = self._stats_row()
            stats["utxo_count"] = 0
            self._put_stats(stats)
            self.set_validated_tip(0, genesis_hash, chain=chain)

    def _delete_key(self, key: bytes) -> None:
        if self._txn_ops is not None:
            self._txn_ops.append(("delete", key, None))
            return
        try:
            del self._db[key]
        except KeyError:
            pass

    def _encode_utxo_row(self, row: dict) -> bytes:
        script = row.get("script_pubkey_bytes")
        if script is None:
            script = bytes.fromhex(str(row["script_pubkey"]))
        value = int(row["value"])
        height = int(row["height"])
        coinbase = 1 if bool(row["coinbase"]) else 0
        return (
            UTXO_CODEC_MAGIC
            + struct.pack("<qIB", value, height, coinbase)
            + _compact_size(len(script))
            + bytes(script)
        )

    def _decode_utxo_row(
        self,
        key: bytes,
        raw: bytes | str | None,
        *,
        include_script_bytes: bool = True,
        include_script_hex: bool = True,
    ) -> dict | None:
        if raw is None:
            return None
        txid_hex, vout = self._decode_utxo_key(key)
        if isinstance(raw, str):
            row = dict(_json_loads(raw))
        elif raw.startswith(UTXO_CODEC_MAGIC):
            offset = len(UTXO_CODEC_MAGIC)
            value, height, coinbase = struct.unpack_from("<qIB", raw, offset)
            offset += struct.calcsize("<qIB")
            script_len, offset = _read_compact_size(raw, offset)
            script = raw[offset:offset + script_len]
            if len(script) != script_len:
                raise ValueError(f"short binary UTXO script for {txid_hex}:{vout}")
            row = {
                "txid": txid_hex,
                "vout": vout,
                "height": height,
                "value": value,
                "coinbase": int(coinbase),
            }
            if include_script_hex:
                row["script_pubkey"] = script.hex()
            if include_script_bytes:
                row["script_pubkey_bytes"] = script
            return row
        else:
            row = dict(_json_loads(raw))
        if include_script_bytes and "script_pubkey_bytes" not in row:
            row["script_pubkey_bytes"] = bytes.fromhex(str(row["script_pubkey"]))
        return row

    def replace_utxo_undo(self, chain: str, height: int, entries: list[dict]) -> None:
        self._put("utxo_undo", chain, height, value={"chain": chain, "height": height, "entries": entries, "created_at": _utcnow()})

    def take_utxo_undo(self, chain: str, height: int) -> list[dict]:
        row = self._get("utxo_undo", chain, height)
        if not row:
            raise KeyError(f"No UTXO undo journal for {chain} height {height}")
        self._delete("utxo_undo", chain, height)
        return list(row.get("entries") or [])

    def get_utxo_undo(self, chain: str, height: int) -> list[dict] | None:
        row = self._get("utxo_undo", chain, height)
        return list(row.get("entries") or []) if row else None

    def delete_utxos_created_at_height(self, height: int) -> None:
        deleted = 0
        for key, row in list(self._iter_prefix("utxo")):
            if int(row.get("height", -1)) == height:
                self._delete_key(key)
                deleted += 1
        if deleted:
            self._adjust_stat("utxo_count", -deleted)

    def add_utxo(self, txid: bytes, vout: int, *, height: int, value: int, script_pubkey: bytes, coinbase: bool) -> None:
        if self.get_utxo(txid, vout) is not None:
            raise KeyError(f"UTXO already exists: {txid[::-1].hex()}:{vout}")
        key = self._utxo_key(txid[::-1].hex(), vout)
        raw = self._encode_utxo_row(
            {
                "height": height,
                "value": value,
                "script_pubkey_bytes": script_pubkey,
                "coinbase": 1 if coinbase else 0,
            }
        )
        if self._txn_ops is not None:
            self._txn_ops.append(("put", key, raw))
        else:
            self._db[key] = raw
        self._adjust_stat("utxo_count", 1)

    def add_utxos(self, utxos: Iterable[dict]) -> None:
        added = 0
        seen: set[tuple[str, int]] = set()
        for row in utxos:
            txid = str(row["txid"])
            vout = int(row["vout"])
            key = (txid, vout)
            if key in seen:
                raise KeyError(f"duplicate UTXO in batch: {txid}:{vout}")
            seen.add(key)
            key_bytes = self._utxo_key(txid, vout)
            if self._decode_utxo_row(key_bytes, self._db.get(key_bytes), include_script_bytes=False) is not None:
                raise KeyError(f"UTXO already exists: {txid}:{vout}")
            if "script_pubkey_bytes" not in row and "script_pubkey" in row:
                row = {**row, "script_pubkey_bytes": bytes.fromhex(str(row["script_pubkey"]))}
            raw = self._encode_utxo_row(row)
            if self._txn_ops is not None:
                self._txn_ops.append(("put", key_bytes, raw))
            else:
                self._db[key_bytes] = raw
            added += 1
        if added:
            self._adjust_stat("utxo_count", added)

    def spend_utxo(self, txid: bytes, vout: int) -> None:
        if self.get_utxo(txid, vout) is None:
            raise KeyError(f"UTXO not found: {txid[::-1].hex()}:{vout}")
        self._delete("utxo", txid[::-1].hex(), vout)
        self._adjust_stat("utxo_count", -1)

    def spend_utxos(self, outpoints: Iterable[tuple[bytes, int]]) -> None:
        for txid, vout in outpoints:
            self.spend_utxo(txid, int(vout))

    def delete_known_utxos(self, outpoints: Iterable[tuple[bytes, int]]) -> None:
        deleted = 0
        for txid, vout in outpoints:
            self._delete("utxo", txid[::-1].hex(), int(vout))
            deleted += 1
        if deleted:
            self._adjust_stat("utxo_count", -deleted)

    def get_utxo(self, txid: bytes, vout: int) -> dict | None:
        key = self._utxo_key(txid[::-1].hex(), int(vout))
        row = self._decode_utxo_row(key, self._db.get(key), include_script_bytes=True)
        return dict(row) if row else None

    def get_utxos_many(self, outpoints: Iterable[tuple[bytes, int]]) -> dict[tuple[bytes, int], dict | None]:
        keys: dict[tuple[bytes, int], bytes] = {}
        for txid, vout in dict.fromkeys((txid, int(vout)) for txid, vout in outpoints):
            keys[(txid, vout)] = self._utxo_key(txid[::-1].hex(), int(vout))
        out: dict[tuple[bytes, int], dict | None] = {key: None for key in keys}
        if not keys:
            return out
        raw_by_key: dict[bytes, bytes | str | None]
        get_many = getattr(self._db, "get_many", None) or getattr(self._db, "multi_get", None)
        if callable(get_many):
            values = get_many(list(keys.values()))
            if isinstance(values, dict):
                raw_by_key = {k if isinstance(k, bytes) else str(k).encode(): v for k, v in values.items()}
            else:
                raw_by_key = dict(zip(keys.values(), values, strict=False))
        else:
            raw_by_key = {raw_key: self._db.get(raw_key) for raw_key in keys.values()}
        for outpoint, raw_key in keys.items():
            out[outpoint] = self._decode_utxo_row(
                raw_key,
                raw_by_key.get(raw_key),
                include_script_bytes=True,
                include_script_hex=False,
            )
        return out

    def list_utxos(self) -> list[dict]:
        return sorted(self._all("utxo"), key=lambda row: (row["txid"], int(row["vout"])))

    def delete_utxo_by_hex(self, txid_hex: str, vout: int) -> None:
        key = self._utxo_key(txid_hex, int(vout))
        if self._decode_utxo_row(key, self._db.get(key), include_script_bytes=False) is None:
            return
        self._delete_key(key)
        self._adjust_stat("utxo_count", -1)

    def utxo_count(self) -> int:
        return int(self._stats_row()["utxo_count"])

    def record_header(
        self,
        height: int,
        block_hash: str,
        prev_hash: str,
        timestamp: int,
        *,
        header_serialized_hex: str | None = None,
    ) -> None:
        if self._get("header_by_height", height) is not None:
            return
        row = {
            "height": height,
            "block_hash": block_hash,
            "prev_hash": prev_hash,
            "timestamp": timestamp,
            "received_at": _utcnow(),
            "header_serialized_hex": header_serialized_hex or "",
        }
        self._put("header_by_height", height, value=row)
        self._put("header_height_by_hash", block_hash, value=height)
        stats = self._stats_row()
        stats["header_count"] = int(stats["header_count"]) + 1
        stats["max_header_height"] = max(int(stats["max_header_height"]), height)
        self._put_stats(stats)

    def get_header(self, height: int) -> dict | None:
        row = self._get("header_by_height", height)
        return dict(row) if row else None

    def backfill_header_serialized(self, height: int, header_serialized_hex: str) -> None:
        row = self.get_header(height)
        if not row or row.get("header_serialized_hex"):
            return
        row["header_serialized_hex"] = header_serialized_hex
        self._put("header_by_height", height, value=row)

    def header_count(self) -> int:
        return int(self._stats_row()["header_count"])

    def get_header_hash(self, height: int) -> str | None:
        row = self.get_header(height)
        return str(row["block_hash"]) if row else None

    def lookup_header_height(self, block_hash_hex: str) -> int | None:
        value = self._get("header_height_by_hash", block_hash_hex)
        return int(value) if value is not None else None

    def max_header_height(self) -> int:
        return int(self._stats_row()["max_header_height"])

    def record_block(self, height: int, block_hash: str, file_name: str, file_offset: int, size: int) -> None:
        if self._get("block_by_height", height) is not None:
            return
        row = {
            "height": height,
            "block_hash": block_hash,
            "file_name": file_name,
            "file_offset": file_offset,
            "size": size,
            "received_at": _utcnow(),
        }
        self._put("block_by_height", height, value=row)
        self._put("block_height_by_hash", block_hash, value=height)
        stats = self._stats_row()
        stats["block_count"] = int(stats["block_count"]) + 1
        stats["max_stored_block_height"] = max(int(stats["max_stored_block_height"]), height)
        self._put_stats(stats)

    def update_block_location(self, height: int, *, file_name: str, file_offset: int, size: int) -> None:
        row = self.get_block(height)
        if row is None:
            raise KeyError(f"block height not indexed: {height}")
        row.update({"file_name": file_name, "file_offset": file_offset, "size": size, "received_at": _utcnow()})
        self._put("block_by_height", height, value=row)

    def get_stored_block_for_hash_hex(self, block_hash_hex: str) -> dict | None:
        height = self._get("block_height_by_hash", block_hash_hex)
        return self.get_block(int(height)) if height is not None else None

    def get_block(self, height: int) -> dict | None:
        row = self._get("block_by_height", height)
        return dict(row) if row else None

    def has_block(self, height: int) -> bool:
        return self.get_block(height) is not None

    def block_count(self) -> int:
        return int(self._stats_row()["block_count"])

    def max_stored_block_height(self) -> int:
        return int(self._stats_row()["max_stored_block_height"])

    def list_missing_block_heights(self, *, limit: int = 32) -> list[int]:
        out: list[int] = []
        for height in range(1, self.max_header_height() + 1):
            if self.get_block(height) is None:
                out.append(height)
                if len(out) >= limit:
                    break
        return out

    def iter_blocks(self) -> list[dict]:
        return sorted(self._all("block_by_height"), key=lambda row: int(row["height"]))

    def wire_capability_map(self) -> dict[str, int]:
        return {row["capability_id"]: int(row["implemented"]) for row in self._all("wire_capability")}

    def mark_wire_capability(self, capability_id: str, *, implemented: bool, verified_by: str = "live", notes: str = "") -> None:
        if capability_id not in CAPABILITIES_BY_ID:
            raise KeyError(f"Unknown wire capability {capability_id!r}")
        row = self._get("wire_capability", capability_id)
        cap = CAPABILITIES_BY_ID[capability_id]
        row = row or {
            "capability_id": cap.id,
            "checkpoint": cap.checkpoint,
            "category": cap.category,
            "name": cap.name,
            "description": cap.description,
            "required": 1 if cap.required else 0,
        }
        row.update(
            {
                "implemented": 1 if implemented else 0,
                "verified_by": verified_by if implemented else "",
                "verified_at": _utcnow() if implemented else "",
                "notes": notes,
            }
        )
        self._put("wire_capability", capability_id, value=row)

    def list_wire_capabilities(self, checkpoint: str | None = None) -> list[dict]:
        rows = sorted(self._all("wire_capability"), key=lambda row: (row["checkpoint"], row["capability_id"]))
        if checkpoint:
            rows = [row for row in rows if row["checkpoint"] == checkpoint]
        return rows

    def get_wire_capability(self, capability_id: str) -> dict | None:
        row = self._get("wire_capability", capability_id)
        return dict(row) if row else None

    def wire_progress(self) -> dict:
        cap_map = self.wire_capability_map()
        return {
            "capabilities": self.list_wire_capabilities(),
            "checkpoints": checkpoint_status(cap_map),
            "summary": full_node_wire_progress(cap_map),
        }

    def peer_count(self) -> int:
        return self._count("peer")

    def connected_peer_count(self) -> int:
        return sum(1 for row in self._all("peer") if row.get("status") == "connected")

    def summary(self, chain: str) -> dict:
        sync = self.get_sync_state(chain) or {}
        return {
            "chain": chain,
            "storage_backend": "rocksdb",
            "sync": sync,
            "header_count": self.header_count(),
            "block_count": self.block_count(),
            "validated_height": self.get_validated_height(chain),
            "validated_hash": self.get_validated_hash(chain),
            "utxo_count": self.utxo_count(),
            "peer_count": self.peer_count(),
            "connected_peers": self.connected_peer_count(),
            "phases": self.list_phases(),
            "wire": self.wire_progress()["summary"],
            "checkpoints": self.wire_progress()["checkpoints"],
            "recent_events": self.recent_events(limit=5),
        }
