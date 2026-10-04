#!/usr/bin/env python3
"""Import one canonical conformance result JSON into Project/project.db."""

from __future__ import annotations

import argparse
import sqlite3
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from import_all import import_json_artifact, init_db, read_json, repo_root  # noqa: E402


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", default="Project/project.db", help="Project mission-control DB path")
    parser.add_argument("results_json", help="Shared conformance result JSON path")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = repo_root()
    db_path = root / args.db
    payload_path = root / args.results_json
    if not payload_path.exists():
        payload_path = Path(args.results_json)
    payload = read_json(payload_path)
    from provenance import validate
    validate(payload)
    db_path.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(db_path) as connection:
        connection.execute("PRAGMA foreign_keys = ON")
        init_db(connection, root / "Project/schema.sql")
        import_json_artifact(connection, root, payload_path, payload)
    print(f"imported_conformance_result db={args.db} source={payload_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
