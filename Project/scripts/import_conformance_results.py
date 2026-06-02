#!/usr/bin/env python3
"""Import NodeCore conformance result JSON into Project/project.db."""

from __future__ import annotations

import argparse
import json
import sqlite3
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", default="Project/project.db", help="Project SQLite DB path")
    parser.add_argument("results_json", help="NodeCore conformance result JSON path")
    return parser.parse_args()


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def init_schema(connection: sqlite3.Connection, schema_path: Path) -> None:
    with schema_path.open("r", encoding="utf-8") as handle:
        connection.executescript(handle.read())


def result_rows(payload: dict[str, Any]) -> list[dict[str, Any]]:
    aggregate_results = payload.get("results")
    if isinstance(aggregate_results, list):
        return [row for row in aggregate_results if isinstance(row, dict)]
    return [payload]


def import_results(db_path: Path, payload_path: Path) -> int:
    payload = load_json(payload_path)
    raw_json = json.dumps(payload, sort_keys=True)
    node_id = payload.get("node_id") or payload.get("implementation") or "unknown-node"
    implementation = payload.get("implementation") or "unknown"
    category = payload.get("category") or "unknown"
    repo_root = Path(__file__).resolve().parents[2]
    schema_path = repo_root / "Project" / "schema.sql"
    db_path.parent.mkdir(parents=True, exist_ok=True)

    rows = result_rows(payload)
    with sqlite3.connect(db_path) as connection:
        init_schema(connection, schema_path)
        connection.execute(
            """
            INSERT INTO nodes(node_id, implementation, language, role, repo_path, default_datadir, status, notes)
            VALUES(?, ?, '', 'conformance', ?, ?, 'active', 'imported conformance results')
            ON CONFLICT(node_id) DO UPDATE SET
              implementation = excluded.implementation,
              default_datadir = excluded.default_datadir,
              updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
            """,
            (
                node_id,
                implementation,
                str(repo_root),
                str(payload.get("datadir", "")),
            ),
        )
        for row in rows:
            row_raw = json.dumps(row, sort_keys=True)
            connection.execute(
                """
                INSERT INTO conformance_results(
                  node_id, fixture_id, category, result, validated_height,
                  validated_hash, chainstate_backend, duration_ms, failure, raw_json
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    node_id,
                    row.get("fixture_id", ""),
                    row.get("category", category),
                    row.get("result", "unknown"),
                    row.get("validated_height"),
                    row.get("validated_hash", payload.get("validated_hash", "")) or "",
                    row.get("chainstate_backend", payload.get("chainstate_backend", "")) or "",
                    row.get("duration_ms"),
                    row.get("failure", "") or "",
                    row_raw if aggregate_row_only(payload) else raw_json,
                ),
            )
    return len(rows)


def aggregate_row_only(payload: dict[str, Any]) -> bool:
    return not isinstance(payload.get("results"), list)


def main() -> int:
    args = parse_args()
    imported = import_results(Path(args.db), Path(args.results_json))
    print(f"imported_conformance_results count={imported} db={args.db}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
