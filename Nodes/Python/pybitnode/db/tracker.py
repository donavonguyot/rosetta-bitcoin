from __future__ import annotations

import json
import logging
import sqlite3
from collections.abc import Iterable, Iterator
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

import sqlite_utils

from pybitnode.db.schema import SCHEMA_VERSION, init_schema, seed_wire_capabilities
from pybitnode.endpoint_parse import host_port_is_well_formed_endpoint
from pybitnode.wire.capabilities import (
    CAPABILITIES_BY_ID,
    checkpoint_status,
    full_node_wire_progress,
)


def _utcnow() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


logger = logging.getLogger(__name__)


class ProjectTracker:
    """SQLite-backed tracker for sync state, peers, headers, and project phases."""

    def __init__(self, db_path: str | Path) -> None:
        path = Path(db_path)
        path.parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite_utils.Database(str(path))
        self._configure_sqlite_pragmas()
        init_schema(self.db)

    def close(self) -> None:
        self.db.close()

    def _configure_sqlite_pragmas(self) -> None:
        """Apply conservative SQLite settings for one-writer sync workloads."""
        pragmas: tuple[tuple[str, str], ...] = (
            ("journal_mode", "WAL"),
            ("synchronous", "NORMAL"),
            ("temp_store", "MEMORY"),
            ("cache_size", "-131072"),
            ("mmap_size", "268435456"),
        )
        for name, value in pragmas:
            try:
                self.db.conn.execute(f"PRAGMA {name}={value}")
            except sqlite3.Error:
                logger.debug("sqlite_pragma_failed name=%s value=%s", name, value, exc_info=True)

    @contextmanager
    def transaction(self) -> Iterator[None]:
        """Run a set of tracker writes in one SQLite transaction."""
        if self.db.conn.in_transaction:
            yield
            return
        self.db.conn.execute("BEGIN IMMEDIATE")
        try:
            yield
        except Exception:
            self.db.conn.rollback()
            raise
        else:
            self.db.conn.commit()

    def set_meta(self, key: str, value: str) -> None:
        self.db["meta"].upsert({"key": key, "value": value}, pk="key")

    def get_meta(self, key: str, default: str | None = None) -> str | None:
        rows = list(self.db["meta"].rows_where("key = ?", [key], limit=1))
        if not rows:
            return default
        return rows[0]["value"]

    def update_phase(self, phase: str, *, status: str | None = None, notes: str | None = None) -> None:
        rows = list(self.db["project_phases"].rows_where("phase = ?", [phase], limit=1))
        if not rows:
            raise KeyError(f"Unknown phase {phase!r}")
        updates: dict[str, str | int] = {"updated_at": _utcnow()}
        if status is not None:
            updates["status"] = status
        if notes is not None:
            updates["notes"] = notes
        self.db["project_phases"].update(rows[0]["id"], updates)

    def list_phases(self) -> list[dict]:
        return list(self.db["project_phases"].rows)

    def log_event(
        self,
        category: str,
        message: str,
        *,
        level: str = "info",
        details: dict | None = None,
    ) -> None:
        self.db["events"].insert(
            {
                "category": category,
                "level": level,
                "message": message,
                "details_json": json.dumps(details or {}),
                "created_at": _utcnow(),
            },
        )

    def upsert_sync_state(
        self,
        chain: str,
        *,
        best_height: int | None = None,
        best_hash: str | None = None,
        header_count: int | None = None,
        sync_status: str | None = None,
    ) -> None:
        now = _utcnow()
        existing = self.get_sync_state(chain) or {}
        payload = {
            "chain": chain,
            "best_height": best_height if best_height is not None else int(existing.get("best_height", 0)),
            "best_hash": best_hash if best_hash is not None else str(existing.get("best_hash", "")),
            "header_count": header_count if header_count is not None else int(existing.get("header_count", 0)),
            "sync_status": sync_status if sync_status is not None else str(existing.get("sync_status", "starting")),
            "updated_at": now,
        }
        rows = list(self.db["sync_state"].rows_where("chain = ?", [chain], limit=1))
        if rows:
            self.db["sync_state"].update(rows[0]["id"], payload)
        else:
            self.db["sync_state"].insert(payload)

    def get_sync_state(self, chain: str) -> dict | None:
        rows = list(self.db["sync_state"].rows_where("chain = ?", [chain], limit=1))
        return dict(rows[0]) if rows else None

    def _last_rowid(self) -> int:
        row = self.db.conn.execute("SELECT last_insert_rowid()").fetchone()
        return int(row[0])

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
        self.db["peers"].insert(
            {
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
        peer_id = self._last_rowid()
        self.log_event(
            "p2p",
            f"Connected to {host}:{port}",
            details={"peer_id": peer_id, "user_agent": user_agent},
        )
        return peer_id

    def record_peer_disconnected(self, peer_id: int, *, status: str = "disconnected") -> None:
        self.db["peers"].update(
            peer_id,
            {"disconnected_at": _utcnow(), "status": status},
        )

    def touch_peer(self, peer_id: int) -> None:
        self.db["peers"].update(peer_id, {"last_seen_at": _utcnow()})

    def record_peer_address(
        self,
        host: str,
        port: int,
        *,
        services: int = 0,
        source: str = "addr",
    ) -> None:
        if services >= 2**63:
            services -= 2**64
        if not host_port_is_well_formed_endpoint(host, port):
            logger.warning(
                "peer_address_skipped_malformed host=%r port=%s source=%s",
                host,
                port,
                source,
            )
            return
        now = _utcnow()
        rows = list(self.db["peer_addresses"].rows_where("host = ? AND port = ?", [host, port], limit=1))
        payload = {
            "host": host,
            "port": port,
            "services": services,
            "source": source,
            "last_seen_at": now,
        }
        if rows:
            payload["ban_score"] = int(rows[0].get("ban_score") or 0)
            self.db["peer_addresses"].update(rows[0]["id"], payload)
        else:
            payload["ban_score"] = 0
            self.db["peer_addresses"].insert(payload)

    def get_peer_endpoint_ban_score(self, host: str, port: int) -> int:
        rows = list(self.db["peer_addresses"].rows_where("host = ? AND port = ?", [host, port], limit=1))
        if not rows:
            return 0
        return int(rows[0].get("ban_score") or 0)

    def increment_peer_ban_score(self, host: str, port: int, delta: int, *, peer_id: int | None = None) -> int:
        """Add delta to endpoint aggregate (peer_addresses) and matching session row (peers) when peer_id set."""
        if delta == 0:
            return self.get_peer_endpoint_ban_score(host, port)
        now = _utcnow()
        rows = list(self.db["peer_addresses"].rows_where("host = ? AND port = ?", [host, port], limit=1))
        if rows:
            new_score = int(rows[0].get("ban_score") or 0) + delta
            self.db["peer_addresses"].update(
                rows[0]["id"],
                {"ban_score": new_score, "last_seen_at": now},
            )
        else:
            new_score = delta
            self.db["peer_addresses"].insert(
                {
                    "host": host,
                    "port": port,
                    "services": 0,
                    "source": "ban",
                    "last_seen_at": now,
                    "ban_score": new_score,
                },
            )
        if peer_id:
            prow = list(self.db["peers"].rows_where("id = ?", [peer_id], limit=1))
            if prow:
                prev = int(prow[0].get("ban_score") or 0)
                self.db["peers"].update(peer_id, {"ban_score": prev + delta})
        return new_score

    def decay_peer_ban_score(self, host: str, port: int, amount: int, *, peer_id: int | None = None) -> None:
        if amount <= 0:
            return
        rows = list(self.db["peer_addresses"].rows_where("host = ? AND port = ?", [host, port], limit=1))
        if not rows:
            return
        new_score = max(0, int(rows[0].get("ban_score") or 0) - amount)
        self.db["peer_addresses"].update(
            rows[0]["id"],
            {"ban_score": new_score, "last_seen_at": _utcnow()},
        )
        if peer_id:
            prow = list(self.db["peers"].rows_where("id = ?", [peer_id], limit=1))
            if prow:
                prev = int(prow[0].get("ban_score") or 0)
                self.db["peers"].update(peer_id, {"ban_score": max(0, prev - amount)})

    def list_peer_address_endpoints(self, *, limit: int = 32) -> list[tuple[str, int]]:
        rows = list(
            self.db.query(
                "SELECT host, port FROM peer_addresses ORDER BY last_seen_at DESC LIMIT ?",
                [limit * 8],
            )
        )
        out: list[tuple[str, int]] = []
        for row in rows:
            host, port = row["host"], int(row["port"])
            if not host_port_is_well_formed_endpoint(host, port):
                continue
            out.append((host, port))
            if len(out) >= limit:
                break
        return out

    def get_validated_height(self, chain: str = "testnet4") -> int:
        rows = list(self.db["chain_state"].rows_where("chain = ?", [chain], limit=1))
        if not rows:
            return 0
        return int(rows[0]["validated_height"])

    def get_validated_hash(self, chain: str = "testnet4") -> str | None:
        rows = list(self.db["chain_state"].rows_where("chain = ?", [chain], limit=1))
        if not rows:
            return None
        value = rows[0]["validated_hash"]
        return str(value) if value else None

    def set_validated_tip(self, height: int, block_hash_hex: str, *, chain: str = "testnet4") -> None:
        payload = {
            "chain": chain,
            "validated_height": height,
            "validated_hash": block_hash_hex,
            "updated_at": _utcnow(),
        }
        rows = list(self.db["chain_state"].rows_where("chain = ?", [chain], limit=1))
        if rows:
            self.db["chain_state"].update(rows[0]["id"], payload)
        else:
            self.db["chain_state"].insert(payload)

    def reset_validated_chain(self, *, chain: str = "testnet4", genesis_hash: str) -> None:
        for row in list(self.db["utxos"].rows):
            self.db["utxos"].delete(row["id"])
        self.db.execute("DELETE FROM utxo_undo WHERE chain = ?", [chain])
        self.set_validated_tip(0, genesis_hash, chain=chain)

    def replace_utxo_undo(self, chain: str, height: int, entries: list[dict]) -> None:
        self.db.execute("DELETE FROM utxo_undo WHERE chain = ? AND height = ?", [chain, height])
        self.db["utxo_undo"].insert(
            {
                "chain": chain,
                "height": height,
                "entries_json": json.dumps(entries),
                "created_at": _utcnow(),
            },
        )

    def take_utxo_undo(self, chain: str, height: int) -> list[dict]:
        rows = list(
            self.db["utxo_undo"].rows_where("chain = ? AND height = ?", [chain, height], limit=1)
        )
        if not rows:
            raise KeyError(f"No UTXO undo journal for {chain} height {height}")
        row = rows[0]
        self.db["utxo_undo"].delete(row["id"])
        return json.loads(row["entries_json"])

    def delete_utxos_created_at_height(self, height: int) -> None:
        self.db.execute("DELETE FROM utxos WHERE height = ?", [height])

    def add_utxo(
        self,
        txid: bytes,
        vout: int,
        *,
        height: int,
        value: int,
        script_pubkey: bytes,
        coinbase: bool,
    ) -> None:
        self.db["utxos"].insert(
            {
                "txid": txid[::-1].hex(),
                "vout": vout,
                "height": height,
                "value": value,
                "script_pubkey": script_pubkey.hex(),
                "coinbase": 1 if coinbase else 0,
                "created_at": _utcnow(),
            },
        )

    def add_utxos(self, utxos: Iterable[dict]) -> None:
        rows = [
            (
                row["txid"],
                int(row["vout"]),
                int(row["height"]),
                int(row["value"]),
                row["script_pubkey"],
                int(row["coinbase"]),
                _utcnow(),
            )
            for row in utxos
        ]
        if not rows:
            return
        self.db.conn.executemany(
            """
            INSERT INTO utxos (txid, vout, height, value, script_pubkey, coinbase, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            rows,
        )

    def spend_utxo(self, txid: bytes, vout: int) -> None:
        rows = list(
            self.db["utxos"].rows_where("txid = ? AND vout = ?", [txid[::-1].hex(), vout], limit=1)
        )
        if not rows:
            raise KeyError(f"UTXO not found: {txid[::-1].hex()}:{vout}")
        self.db["utxos"].delete(rows[0]["id"])

    def spend_utxos(self, outpoints: Iterable[tuple[bytes, int]]) -> None:
        rows = [(txid[::-1].hex(), int(vout)) for txid, vout in outpoints]
        if not rows:
            return
        cursor = self.db.conn.executemany("DELETE FROM utxos WHERE txid = ? AND vout = ?", rows)
        if cursor.rowcount != len(rows):
            raise KeyError("one or more UTXOs were not found during batch spend")

    def get_utxo(self, txid: bytes, vout: int) -> dict | None:
        rows = list(
            self.db["utxos"].rows_where("txid = ? AND vout = ?", [txid[::-1].hex(), vout], limit=1)
        )
        return dict(rows[0]) if rows else None

    def utxo_count(self) -> int:
        return self.db["utxos"].count

    def record_header(
        self,
        height: int,
        block_hash: str,
        prev_hash: str,
        timestamp: int,
        *,
        header_serialized_hex: str | None = None,
    ) -> None:
        row: dict = {
            "height": height,
            "block_hash": block_hash,
            "prev_hash": prev_hash,
            "timestamp": timestamp,
            "received_at": _utcnow(),
        }
        if header_serialized_hex is not None:
            row["header_serialized_hex"] = header_serialized_hex
        self.db["headers"].insert(row, ignore=True)

    def header_count(self) -> int:
        return self.db["headers"].count

    def get_header_hash(self, height: int) -> str | None:
        rows = list(self.db["headers"].rows_where("height = ?", [height], limit=1))
        if not rows:
            return None
        return rows[0]["block_hash"]

    def lookup_header_height(self, block_hash_hex: str) -> int | None:
        """Resolve display-order block hash hex (RPC style) to main-chain header height."""
        rows = list(self.db["headers"].rows_where("block_hash = ?", [block_hash_hex], limit=1))
        return int(rows[0]["height"]) if rows else None

    def max_header_height(self) -> int:
        rows = list(self.db.query("SELECT MAX(height) AS h FROM headers"))
        if not rows or rows[0]["h"] is None:
            return 0
        return int(rows[0]["h"])

    def get_stored_block_for_hash_hex(self, block_hash_hex: str) -> dict | None:
        """Row from blocks flat-file index keyed by RPC-style hex hash."""
        rows = list(self.db["blocks"].rows_where("block_hash = ?", [block_hash_hex], limit=1))
        return dict(rows[0]) if rows else None

    def has_block(self, height: int) -> bool:
        return self.db["blocks"].count_where("height = ?", [height]) > 0

    def block_count(self) -> int:
        return self.db["blocks"].count

    def list_missing_block_heights(self, *, limit: int = 32) -> list[int]:
        rows = list(
            self.db.query(
                """
                SELECT h.height
                FROM headers h
                LEFT JOIN blocks b ON b.height = h.height
                WHERE h.height > 0 AND b.height IS NULL
                ORDER BY h.height
                LIMIT ?
                """,
                [limit],
            )
        )
        return [int(row["height"]) for row in rows]

    def record_block(
        self,
        height: int,
        block_hash: str,
        file_name: str,
        file_offset: int,
        size: int,
    ) -> None:
        self.db["blocks"].insert(
            {
                "height": height,
                "block_hash": block_hash,
                "file_name": file_name,
                "file_offset": file_offset,
                "size": size,
                "received_at": _utcnow(),
            },
            ignore=True,
        )

    def get_block(self, height: int) -> dict | None:
        rows = list(self.db["blocks"].rows_where("height = ?", [height], limit=1))
        return dict(rows[0]) if rows else None

    def max_stored_block_height(self) -> int:
        row = list(self.db.query("SELECT MAX(height) AS height FROM blocks"))
        if not row or row[0]["height"] is None:
            return 0
        return int(row[0]["height"])

    def recent_events(self, limit: int = 20) -> list[dict]:
        return list(
            self.db.query(
                "SELECT * FROM events ORDER BY id DESC LIMIT ?",
                [limit],
            )
        )

    def wire_capability_map(self) -> dict[str, int]:
        return {
            row["capability_id"]: int(row["implemented"])
            for row in self.db["wire_capabilities"].rows
        }

    def mark_wire_capability(
        self,
        capability_id: str,
        *,
        implemented: bool,
        verified_by: str = "live",
        notes: str = "",
    ) -> None:
        if capability_id not in CAPABILITIES_BY_ID:
            raise KeyError(f"Unknown wire capability {capability_id!r}")
        rows = list(
            self.db["wire_capabilities"].rows_where("capability_id = ?", [capability_id], limit=1)
        )
        payload = {
            "implemented": 1 if implemented else 0,
            "verified_by": verified_by if implemented else "",
            "verified_at": _utcnow() if implemented else "",
            "notes": notes,
        }
        if rows:
            self.db["wire_capabilities"].update(rows[0]["id"], payload)
        else:
            cap = CAPABILITIES_BY_ID[capability_id]
            self.db["wire_capabilities"].insert(
                {
                    "capability_id": cap.id,
                    "checkpoint": cap.checkpoint,
                    "category": cap.category,
                    "name": cap.name,
                    "description": cap.description,
                    "required": 1 if cap.required else 0,
                    **payload,
                },
            )

    def list_wire_capabilities(self, checkpoint: str | None = None) -> list[dict]:
        if checkpoint:
            return list(
                self.db["wire_capabilities"].rows_where(
                    "checkpoint = ? ORDER BY capability_id",
                    [checkpoint],
                )
            )
        return list(self.db.query("SELECT * FROM wire_capabilities ORDER BY checkpoint, capability_id"))

    def wire_progress(self) -> dict:
        cap_map = self.wire_capability_map()
        return {
            "capabilities": self.list_wire_capabilities(),
            "checkpoints": checkpoint_status(cap_map),
            "summary": full_node_wire_progress(cap_map),
        }

    def summary(self, chain: str) -> dict:
        sync = self.get_sync_state(chain) or {}
        return {
            "chain": chain,
            "sync": sync,
            "header_count": self.header_count(),
            "block_count": self.block_count(),
            "validated_height": self.get_validated_height(chain),
            "validated_hash": self.get_validated_hash(chain),
            "utxo_count": self.utxo_count(),
            "peer_count": self.db["peers"].count,
            "connected_peers": self.db["peers"].count_where("status = 'connected'"),
            "phases": self.list_phases(),
            "wire": self.wire_progress()["summary"],
            "checkpoints": self.wire_progress()["checkpoints"],
            "recent_events": self.recent_events(limit=5),
        }
