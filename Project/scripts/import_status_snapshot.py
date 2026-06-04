#!/usr/bin/env python3
"""Import one exported node status JSON into Project/project.db."""

from __future__ import annotations

import argparse
import sqlite3
import sys
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from import_all import import_json_artifact, init_db, read_json, repo_root  # noqa: E402


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", default="Project/project.db", help="Project SQLite DB path")
    parser.add_argument("--node-id", required=True, help="Node ID for the status snapshot")
    parser.add_argument("status_json", help="Status JSON emitted by a node")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = repo_root()
    db_path = root / args.db
    status_path = root / args.status_json
    if not status_path.exists():
        status_path = Path(args.status_json)
    payload: dict[str, Any] = read_json(status_path)
    payload.setdefault("node_id", args.node_id)
    db_path.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(db_path) as connection:
        connection.execute("PRAGMA foreign_keys = ON")
        init_db(connection, root / "Project/schema.sql")
        import_json_artifact(connection, root, status_path, payload)
    print(f"imported_status_snapshot node_id={args.node_id} db={args.db} source={status_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
