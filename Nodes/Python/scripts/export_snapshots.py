#!/usr/bin/env python3
"""Export native RocksDB tracker state to snapshots/ for version control."""

from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path

from pybitnode.config import Settings
from pybitnode.chainstate.tracker import ProjectTracker


def _utcnow() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def export_snapshots(*, state_path: Path, out_dir: Path, chain: str) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    tracker = ProjectTracker(state_path)
    try:
        summary = tracker.summary(chain)
        summary["exported_at"] = _utcnow()
        (out_dir / "status.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
        (out_dir / "phases.json").write_text(json.dumps(tracker.list_phases(), indent=2, sort_keys=True) + "\n")
        wire = tracker.wire_progress()
        (out_dir / "wire.json").write_text(json.dumps(wire, indent=2, sort_keys=True) + "\n")
        (out_dir / "capabilities.json").write_text(json.dumps(wire["capabilities"], indent=2, sort_keys=True) + "\n")
        manifest = {
            "exported_at": _utcnow(),
            "state_path": str(state_path),
            "chain": chain,
            "schema_version": tracker.get_meta("schema_version"),
            "storage_backend": "rocksdb",
            "files": ["status.json", "phases.json", "wire.json", "capabilities.json"],
        }
        (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    finally:
        tracker.close()


def main() -> None:
    parser = argparse.ArgumentParser(description="Export pybitnode native snapshots")
    parser.add_argument("--state-path", default=None, help="Native RocksDB chainstate directory")
    parser.add_argument("--out", default="snapshots", help="Output directory")
    parser.add_argument("--chain", default=None)
    args = parser.parse_args()

    settings = Settings.from_env()
    if args.state_path:
        settings.state_path = args.state_path
    if args.chain:
        settings.chain = args.chain

    export_snapshots(state_path=Path(settings.resolved_state_path()), out_dir=Path(args.out), chain=settings.chain)
    print(f"Exported snapshots to {Path(args.out).resolve()}")


if __name__ == "__main__":
    main()
