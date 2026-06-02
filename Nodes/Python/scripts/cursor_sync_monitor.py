#!/usr/bin/env python3
"""Read-only Cursor monitor for pybitnode sync chunks.

Emits low-noise sentinel JSON lines that are easy for Cursor agents to watch.
It never starts sync, writes the DB, or removes locks.
"""

from __future__ import annotations

import argparse
import json
import sqlite3
import subprocess
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path


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


def _sqlite_ro_uri(db_path: Path) -> str:
    path = db_path.expanduser().resolve()
    sep = "&" if "?" in path.as_uri() else "?"
    return f"{path.as_uri()}{sep}mode=ro"


def _latest_blocker(conn: sqlite3.Connection) -> str:
    try:
        rows = conn.execute(
            """
            SELECT message, details_json
            FROM events
            WHERE message IN ('Rejected invalid block', 'Block unavailable from peers')
               OR message LIKE 'Block connect failed:%'
            ORDER BY id DESC
            LIMIT 1
            """
        ).fetchall()
    except sqlite3.Error:
        return ""
    if not rows:
        return ""
    message, details = rows[0]
    return str(details or message)


def read_status(db_path: Path, *, chain: str) -> Status:
    if not db_path.expanduser().is_file():
        return Status(0, 0, "missing_db", "", "")
    conn = sqlite3.connect(_sqlite_ro_uri(db_path), uri=True, timeout=1)
    try:
        tip = conn.execute(
            "SELECT validated_height, updated_at FROM chain_state WHERE chain = ? LIMIT 1",
            (chain,),
        ).fetchone()
        sync = conn.execute(
            "SELECT sync_status, updated_at FROM sync_state WHERE chain = ? LIMIT 1",
            (chain,),
        ).fetchone()
        header = conn.execute("SELECT MAX(height) FROM headers").fetchone()
        return Status(
            validated_height=int(tip[0]) if tip else 0,
            header_height=int(header[0]) if header and header[0] is not None else 0,
            sync_status=str(sync[0]) if sync else "unknown",
            current_blocker=_latest_blocker(conn),
            updated_at=str(tip[1] if tip else sync[1] if sync else ""),
        )
    finally:
        conn.close()


def pybitnode_sync_process_count() -> int:
    try:
        result = subprocess.run(
            ["ps", "-ax", "-o", "pid=", "-o", "command="],
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return 0
    count = 0
    for line in result.stdout.splitlines():
        if "pybitnode-sync" in line and "cursor_sync_monitor.py" not in line:
            count += 1
    return count


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
    }
    print(f"{SENTINEL} {json.dumps(payload, sort_keys=True)}", flush=True)


def should_emit(
    status: Status,
    *,
    previous: Status | None,
    target: int,
    delta_threshold: int,
    process_count: int,
) -> bool:
    if previous is None:
        return True
    if status.sync_status != previous.sync_status:
        return True
    if process_count == 0:
        return True
    if target and status.validated_height >= target:
        return True
    if status.current_blocker and status.current_blocker != previous.current_blocker:
        return True
    return status.validated_height - previous.validated_height >= delta_threshold


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Read-only Cursor monitor for pybitnode sync chunks")
    parser.add_argument("--datadir", type=Path, default=Path("./data"))
    parser.add_argument("--db", type=Path, default=None)
    parser.add_argument("--chain", default="testnet4")
    parser.add_argument("--target", type=int, default=0)
    parser.add_argument("--interval", type=float, default=120.0)
    parser.add_argument("--delta-threshold", type=int, default=50)
    parser.add_argument("--once", action="store_true", help="Emit one status line and exit")
    args = parser.parse_args(argv)

    db_path = args.db if args.db is not None else args.datadir / "pybitnode.db"
    previous: Status | None = None
    while True:
        status = read_status(db_path, chain=args.chain)
        process_count = pybitnode_sync_process_count()
        if should_emit(
            status,
            previous=previous,
            target=args.target,
            delta_threshold=args.delta_threshold,
            process_count=process_count,
        ):
            emit(
                status,
                target=args.target,
                last_height=previous.validated_height if previous else 0,
                process_count=process_count,
            )
        if args.once:
            return 0
        if process_count == 0 or status.sync_status in {"blocks_idle", "blocks_blocked", "blocks_current"}:
            return 0
        if args.target and status.validated_height >= args.target:
            return 0
        previous = status
        time.sleep(args.interval)


if __name__ == "__main__":
    raise SystemExit(main())
