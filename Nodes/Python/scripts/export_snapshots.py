#!/usr/bin/env python3
"""Export SQLite tracker state to snapshots/ for version control."""

from __future__ import annotations

import argparse
import json
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

from pybitnode.config import Settings
from pybitnode.db.tracker import ProjectTracker


def _utcnow() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def export_snapshots(*, db_path: Path, out_dir: Path, chain: str) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    tracker = ProjectTracker(db_path)
    try:
        summary = tracker.summary(chain)
        summary["exported_at"] = _utcnow()
        (out_dir / "status.json").write_text(json.dumps(summary, indent=2) + "\n")
        (out_dir / "phases.json").write_text(
            json.dumps(list(tracker.list_phases()), indent=2) + "\n"
        )
        (out_dir / "wire.json").write_text(
            json.dumps(tracker.wire_progress(), indent=2) + "\n"
        )
    finally:
        tracker.close()

    db = sqlite3.connect(db_path)
    db.row_factory = sqlite3.Row
    capabilities = [dict(row) for row in db.execute(
        "SELECT * FROM wire_capabilities ORDER BY capability_id"
    )]
    manifest = {
        "exported_at": _utcnow(),
        "db_path": str(db_path),
        "chain": chain,
        "schema_version": db.execute(
            "SELECT value FROM meta WHERE key = 'schema_version'"
        ).fetchone()[0],
        "files": ["status.json", "phases.json", "wire.json", "capabilities.json"],
    }
    (out_dir / "capabilities.json").write_text(json.dumps(capabilities, indent=2) + "\n")
    (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    db.close()


def main() -> None:
    parser = argparse.ArgumentParser(description="Export pybitnode tracker snapshots")
    parser.add_argument("--db", default=None, help="SQLite database path")
    parser.add_argument("--out", default="snapshots", help="Output directory")
    parser.add_argument("--chain", default=None)
    args = parser.parse_args()

    settings = Settings.from_env()
    if args.db:
        settings.db_path = args.db
    if args.chain:
        settings.chain = args.chain

    export_snapshots(
        db_path=Path(settings.resolved_db_path()),
        out_dir=Path(args.out),
        chain=settings.chain,
    )
    print(f"Exported snapshots to {Path(args.out).resolve()}")


if __name__ == "__main__":
    main()
