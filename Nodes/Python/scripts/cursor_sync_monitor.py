#!/usr/bin/env python3
"""Read-only Cursor monitor for pybitnode native sync chunks."""

from __future__ import annotations

import argparse
import json
import subprocess
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from pybitnode.db.tracker import ProjectTracker

SENTINEL = "AGENT_LOOP_TICK_pybitnode_sync"


@dataclass(frozen=True)
class Status:
    validated_height: int
    header_height: int
    sync_status: str
    current_blocker: str
    updated_at: str


def _utc_ts() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).strftime("%H:%M:%SZ")


def read_status(state_path: Path, *, chain: str) -> Status:
    if not state_path.exists():
        return Status(0, 0, "missing_state", "", "")
    tracker = ProjectTracker(state_path)
    try:
        summary = tracker.summary(chain)
        sync = summary.get("sync", {}) if isinstance(summary.get("sync"), dict) else {}
        blocker = ""
        for event in tracker.recent_events(limit=20):
            message = str(event.get("message", ""))
            if message.startswith("Block connect failed") or message in {"Rejected invalid block", "Block unavailable from peers"}:
                blocker = str(event.get("details_json") or message)
                break
        return Status(
            validated_height=int(summary.get("validated_height", 0) or 0),
            header_height=tracker.max_header_height(),
            sync_status=str(sync.get("sync_status", "unknown")),
            current_blocker=blocker,
            updated_at=str(sync.get("updated_at", "")),
        )
    finally:
        tracker.close()


def pybitnode_sync_process_count() -> int:
    try:
        result = subprocess.run(["ps", "-ax", "-o", "pid=", "-o", "command="], check=True, capture_output=True, text=True)
    except (OSError, subprocess.CalledProcessError):
        return 0
    return sum(1 for line in result.stdout.splitlines() if "pybitnode-sync" in line and "cursor_sync_monitor.py" not in line)


def emit(status: Status, *, target: int, last_height: int, process_count: int) -> None:
    payload = {
        "ts": _utc_ts(),
        "validated_height": status.validated_height,
        "header_height": status.header_height,
        "sync_status": status.sync_status,
        "remaining": max(0, target - status.validated_height) if target else 0,
        "delta_since_last": status.validated_height - last_height if last_height else 0,
        "process_running": process_count,
        "target": target,
        "current_blocker": status.current_blocker,
        "updated_at": status.updated_at,
        "storage_backend": "rocksdb",
    }
    print(f"{SENTINEL} {json.dumps(payload, sort_keys=True)}", flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-path", type=Path, default=Path("data/chainstate-rocksdb"))
    parser.add_argument("--chain", default="testnet4")
    parser.add_argument("--target", type=int, default=0)
    parser.add_argument("--interval", type=int, default=60)
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()

    last_height = 0
    while True:
        status = read_status(args.state_path, chain=args.chain)
        emit(status, target=args.target, last_height=last_height, process_count=pybitnode_sync_process_count())
        last_height = status.validated_height
        if args.once:
            return 0
        time.sleep(max(1, args.interval))


if __name__ == "__main__":
    raise SystemExit(main())
