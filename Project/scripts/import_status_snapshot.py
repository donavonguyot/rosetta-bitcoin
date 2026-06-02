#!/usr/bin/env python3
"""Import an exported node status JSON into Project/project.db."""

from __future__ import annotations

import argparse
import json
import sqlite3
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", default="Project/project.db", help="Project SQLite DB path")
    parser.add_argument("--node-id", required=True, help="Node ID for the status snapshot")
    parser.add_argument("status_json", help="Status JSON emitted by a node")
    return parser.parse_args()


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def nested(payload: dict[str, Any], *keys: str, default: Any = None) -> Any:
    current: Any = payload
    for key in keys:
        if not isinstance(current, dict) or key not in current:
            return default
        current = current[key]
    return current


def first(payload: dict[str, Any], *keys: str, default: Any = None) -> Any:
    for key in keys:
        if key in payload and payload[key] is not None:
            return payload[key]
    return default


def implementation_for(node_id: str, payload: dict[str, Any]) -> tuple[str, str, str]:
    implementation = str(first(payload, "implementation", default="")).strip()
    language = str(first(payload, "language", default="")).strip()
    role = str(first(payload, "role", default="")).strip()
    lower = node_id.lower()
    if not implementation:
        if "python" in lower or "pybitnode" in lower:
            implementation, language, role = "PythonNode", "Python", "scout"
        elif "typescript" in lower or "tsbitnode" in lower:
            implementation, language, role = "TypeScriptNode", "TypeScript", "follower"
        elif "java" in lower or "jbitnode" in lower:
            implementation, language, role = "JavaNode", "Java", "lead"
        elif "csharp" in lower or "csbitnode" in lower:
            implementation, language, role = "CSharpNode", "C#", "follower"
        elif "cpp" in lower or "cpbitnode" in lower:
            implementation, language, role = "CppNode", "C++", "follower"
        elif "elixir" in lower or "exbitnode" in lower:
            implementation, language, role = "ElixirNode", "Elixir", "follower"
        else:
            implementation, language, role = "unknown", "unknown", "unknown"
    return implementation, language or "unknown", role or "unknown"


def int_field(value: Any, default: int = -1) -> int:
    try:
        if value is None:
            return default
        return int(value)
    except (TypeError, ValueError):
        return default


def blocker_id(node_id: str, blocker: dict[str, Any]) -> str:
    height = blocker.get("height", "unknown")
    txid = blocker.get("txid", "")
    input_index = blocker.get("input_index", "")
    return f"{node_id}:{height}:{txid}:{input_index}"


def init_schema(connection: sqlite3.Connection, schema_path: Path) -> None:
    with schema_path.open("r", encoding="utf-8") as handle:
        connection.executescript(handle.read())


def import_status(db_path: Path, node_id: str, status_path: Path) -> None:
    payload = load_json(status_path)
    repo_root = Path(__file__).resolve().parents[2]
    schema_path = repo_root / "Project" / "schema.sql"
    raw_json = json.dumps(payload, sort_keys=True)
    db_path.parent.mkdir(parents=True, exist_ok=True)
    data_dir = first(payload, "datadir", "data_dir", default=None)
    if not data_dir:
        db_path_text = str(payload.get("db_path", ""))
        data_dir = str(Path(db_path_text).parent) if db_path_text else ""
    implementation, language, role = implementation_for(node_id, payload)
    sync_status = first(payload, "sync_status", default=nested(payload, "sync", "sync_status", default="starting"))
    current_blocker = payload.get("current_blocker")
    current_blocker_id = None
    if isinstance(current_blocker, dict):
        current_blocker_id = blocker_id(node_id, current_blocker)

    with sqlite3.connect(db_path) as connection:
        init_schema(connection, schema_path)
        connection.execute(
            """
            INSERT INTO nodes(node_id, implementation, language, role, repo_path, default_datadir, status, notes)
            VALUES(?, ?, ?, ?, ?, ?, 'active', 'imported status snapshot')
            ON CONFLICT(node_id) DO UPDATE SET
              implementation = excluded.implementation,
              language = excluded.language,
              role = excluded.role,
              default_datadir = excluded.default_datadir,
              updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
            """,
            (node_id, implementation, language, role, str(repo_root), data_dir),
        )
        if isinstance(current_blocker, dict) and current_blocker_id:
            connection.execute(
                """
                INSERT INTO blockers(
                  blocker_id, height, block_hash, txid, input_index,
                  spent_script_pubkey, failure, missing_rule, source_port, status
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, 'blocked')
                ON CONFLICT(blocker_id) DO UPDATE SET
                  failure = excluded.failure,
                  missing_rule = excluded.missing_rule,
                  status = excluded.status
                """,
                (
                    current_blocker_id,
                    int_field(current_blocker.get("height"), 0),
                    current_blocker.get("block_hash", ""),
                    current_blocker.get("txid", ""),
                    current_blocker.get("input_index"),
                    current_blocker.get("spent_script_pubkey", ""),
                    current_blocker.get("failure", ""),
                    current_blocker.get("missing_rule", ""),
                    implementation,
                ),
            )
        connection.execute(
            """
            INSERT INTO status_snapshots(
              node_id, chain, sync_status, binary_gate_status, header_height,
              header_hash, stored_block_height, stored_block_hash,
              validated_height, validated_hash,
              chainstate_backend, chainstate_status, chainstate_generation_id,
              chainstate_utxo_count, block_gap_count, current_blocker_id,
              last_error, raw_json
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                node_id,
                payload.get("chain", ""),
                sync_status,
                payload.get("binary_gate_status", "not_attempted"),
                int_field(payload.get("header_height")),
                payload.get("header_hash", ""),
                int_field(payload.get("stored_block_height")),
                payload.get("stored_block_hash", ""),
                int_field(payload.get("validated_height")),
                payload.get("validated_hash", ""),
                payload.get("chainstate_backend", ""),
                payload.get("chainstate_status", ""),
                payload.get("chainstate_generation_id", ""),
                int_field(first(payload, "chainstate_utxo_count", "utxo_count", default=0), 0),
                int_field(payload.get("block_gap_count"), 0),
                current_blocker_id,
                payload.get("last_error", ""),
                raw_json,
            ),
        )


def main() -> int:
    args = parse_args()
    import_status(Path(args.db), args.node_id, Path(args.status_json))
    print(f"imported_status_snapshot node_id={args.node_id} db={args.db}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
