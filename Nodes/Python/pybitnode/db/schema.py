from __future__ import annotations

from datetime import datetime, timezone

import sqlite_utils

from pybitnode.wire.capabilities import CAPABILITIES

SCHEMA_VERSION = 7

DEFAULT_PHASES = (
    ("phase0", "Wire + handshake", "in_progress", "Message framing, version/verack, Docker scaffold"),
    ("phase1", "Header sync", "pending", "Block locator, header chain persistence"),
    ("phase2", "Block download", "pending", "Parallel getdata, raw block storage"),
    ("phase3", "Consensus validation", "pending", "PoW, merkle root, and script verification in pure Python"),
    ("phase4", "Mempool + relay", "pending", "Tx admission and rebroadcast"),
    ("phase5", "Hardening", "pending", "Metrics, peer banning, optional BIP324"),
)


def _utcnow() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def _ensure_headers_serialized_column(db: sqlite_utils.Database) -> None:
    rows = db.execute("PRAGMA table_info(headers)").fetchall()
    columns = {row[1] for row in rows}
    if "header_serialized_hex" not in columns:
        db.execute("ALTER TABLE headers ADD COLUMN header_serialized_hex TEXT")


def _ensure_peer_addresses_ban_score(db: sqlite_utils.Database) -> None:
    rows = db.execute("PRAGMA table_info(peer_addresses)").fetchall()
    columns = {row[1] for row in rows}
    if "ban_score" not in columns:
        db.execute("ALTER TABLE peer_addresses ADD COLUMN ban_score INTEGER DEFAULT 0")


def init_schema(db: sqlite_utils.Database) -> None:
    db["meta"].create(
        {
            "id": int,
            "key": str,
            "value": str,
        },
        pk="id",
        if_not_exists=True,
    )
    db["meta"].create_index(["key"], unique=True, if_not_exists=True)

    db["project_phases"].create(
        {
            "id": int,
            "phase": str,
            "title": str,
            "status": str,
            "notes": str,
            "updated_at": str,
        },
        pk="id",
        if_not_exists=True,
    )
    db["project_phases"].create_index(["phase"], unique=True, if_not_exists=True)

    db["sync_state"].create(
        {
            "id": int,
            "chain": str,
            "best_height": int,
            "best_hash": str,
            "header_count": int,
            "sync_status": str,
            "updated_at": str,
        },
        pk="id",
        if_not_exists=True,
    )
    db["sync_state"].create_index(["chain"], unique=True, if_not_exists=True)

    db["peers"].create(
        {
            "id": int,
            "host": str,
            "port": int,
            "connected_at": str,
            "disconnected_at": str,
            "direction": str,
            "services": int,
            "peer_version": int,
            "user_agent": str,
            "start_height": int,
            "last_seen_at": str,
            "ban_score": int,
            "status": str,
        },
        pk="id",
        if_not_exists=True,
    )
    db["peers"].create_index(["host", "port"], if_not_exists=True)

    db["headers"].create(
        {
            "id": int,
            "height": int,
            "block_hash": str,
            "prev_hash": str,
            "timestamp": int,
            "received_at": str,
        },
        pk="id",
        if_not_exists=True,
    )
    db["headers"].create_index(["height"], unique=True, if_not_exists=True)
    db["headers"].create_index(["block_hash"], unique=True, if_not_exists=True)
    _ensure_headers_serialized_column(db)

    db["blocks"].create(
        {
            "id": int,
            "height": int,
            "block_hash": str,
            "file_name": str,
            "file_offset": int,
            "size": int,
            "received_at": str,
        },
        pk="id",
        if_not_exists=True,
    )
    db["blocks"].create_index(["height"], unique=True, if_not_exists=True)
    db["blocks"].create_index(["block_hash"], unique=True, if_not_exists=True)

    db["peer_addresses"].create(
        {
            "id": int,
            "host": str,
            "port": int,
            "services": int,
            "source": str,
            "last_seen_at": str,
        },
        pk="id",
        if_not_exists=True,
    )
    db["peer_addresses"].create_index(["host", "port"], unique=True, if_not_exists=True)
    _ensure_peer_addresses_ban_score(db)

    db["chain_state"].create(
        {
            "id": int,
            "chain": str,
            "validated_height": int,
            "validated_hash": str,
            "updated_at": str,
        },
        pk="id",
        if_not_exists=True,
    )
    db["chain_state"].create_index(["chain"], unique=True, if_not_exists=True)

    db["utxos"].create(
        {
            "id": int,
            "txid": str,
            "vout": int,
            "height": int,
            "value": int,
            "script_pubkey": str,
            "coinbase": int,
            "created_at": str,
        },
        pk="id",
        if_not_exists=True,
    )
    db["utxos"].create_index(["txid", "vout"], unique=True, if_not_exists=True)

    db["utxo_undo"].create(
        {
            "id": int,
            "chain": str,
            "height": int,
            "entries_json": str,
            "created_at": str,
        },
        pk="id",
        if_not_exists=True,
    )
    db["utxo_undo"].create_index(["chain", "height"], unique=True, if_not_exists=True)

    db["events"].create(
        {
            "id": int,
            "category": str,
            "level": str,
            "message": str,
            "details_json": str,
            "created_at": str,
        },
        pk="id",
        if_not_exists=True,
    )
    db["events"].create_index(["category", "created_at"], if_not_exists=True)

    db["wire_capabilities"].create(
        {
            "id": int,
            "capability_id": str,
            "checkpoint": str,
            "category": str,
            "name": str,
            "description": str,
            "required": int,
            "implemented": int,
            "verified_by": str,
            "verified_at": str,
            "notes": str,
        },
        pk="id",
        if_not_exists=True,
    )
    db["wire_capabilities"].create_index(["capability_id"], unique=True, if_not_exists=True)
    db["wire_capabilities"].create_index(["checkpoint"], if_not_exists=True)

    if db["meta"].count == 0:
        db["meta"].insert({"key": "schema_version", "value": str(SCHEMA_VERSION)})
        db["meta"].insert({"key": "node_version", "value": "0.1.0"})
    else:
        db["meta"].upsert({"key": "schema_version", "value": str(SCHEMA_VERSION)}, pk="key")

    if db["project_phases"].count == 0:
        now = _utcnow()
        for phase, title, status, notes in DEFAULT_PHASES:
            db["project_phases"].insert(
                {
                    "phase": phase,
                    "title": title,
                    "status": status,
                    "notes": notes,
                    "updated_at": now,
                },
            )

    seed_wire_capabilities(db)


def seed_wire_capabilities(db: sqlite_utils.Database) -> None:
    for cap in CAPABILITIES:
        db["wire_capabilities"].upsert(
            {
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
            pk="capability_id",
        )
