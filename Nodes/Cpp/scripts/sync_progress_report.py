#!/usr/bin/env python3
"""Summarize block sync batch progress from sync_batch_run.log and native RocksDB status."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

_START_RE = re.compile(
    r"^=== batch (?P<num>\d+) start_validated=(?P<h>\d+) (?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z) ===\s*$"
)
_END_RE = re.compile(
    r"^=== batch (?P<num>\d+) end_validated=(?P<h>\d+) downloaded_delta=(?P<dl>\d+) "
    r"exit=(?P<exit>\d+) \((?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)\) "
    r"validated_delta=(?P<vd>\d+) ===\s*$"
)


@dataclass(frozen=True)
class BatchStart:
    line_no: int
    batch_num: int
    start_validated: int
    timestamp: str


@dataclass(frozen=True)
class BatchEnd:
    line_no: int
    batch_num: int
    end_validated: int
    timestamp: str
    validated_delta: int


def parse_batch_log_lines(lines: list[str]) -> tuple[BatchStart | None, BatchEnd | None]:
    """Return the last batch start marker and last batch end marker in file order."""
    last_start: BatchStart | None = None
    last_end: BatchEnd | None = None
    for i, raw in enumerate(lines, start=1):
        line = raw.rstrip("\n")
        m = _START_RE.match(line)
        if m:
            last_start = BatchStart(
                line_no=i,
                batch_num=int(m.group("num")),
                start_validated=int(m.group("h")),
                timestamp=m.group("ts"),
            )
            continue
        m = _END_RE.match(line)
        if m:
            last_end = BatchEnd(
                line_no=i,
                batch_num=int(m.group("num")),
                end_validated=int(m.group("h")),
                timestamp=m.group("ts"),
                validated_delta=int(m.group("vd")),
            )
    return last_start, last_end


def validated_height_from_log(last_start: BatchStart | None, last_end: BatchEnd | None) -> int | None:
    """If the latest marker is an unfinished batch (start after last end), height is still at start."""
    if last_end is None and last_start is None:
        return None
    if last_end is None:
        assert last_start is not None
        return last_start.start_validated
    if last_start is None:
        return last_end.end_validated
    if last_start.line_no > last_end.line_no:
        return last_start.start_validated
    return last_end.end_validated


def pct_to_target(height: int, target: int) -> float:
    if target <= 0:
        return 0.0
    return min(100.0, round(100.0 * height / target, 2))


def read_validated_height_status(status_bin: Path, datadir: Path) -> int:
    proc = subprocess.run(
        [
            str(status_bin.expanduser()),
            "--datadir",
            str(datadir.expanduser()),
            "--chainstate-backend",
            "rocksdb",
        ],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    status = json.loads(proc.stdout)
    return int(status.get("validated_height", 0))


def build_report(
    *,
    log_path: Path,
    target: int,
    datadir: Path | None,
    status_bin: Path,
) -> tuple[str, ...]:
    text = log_path.read_text(encoding="utf-8", errors="replace")
    lines = text.splitlines()
    last_start, last_end = parse_batch_log_lines(lines)

    if datadir is not None:
        vh = read_validated_height_status(status_bin, datadir)
    else:
        vh_o = validated_height_from_log(last_start, last_end)
        if vh_o is None:
            raise ValueError(f"No batch start/end markers found in {log_path}")
        vh = vh_o

    pct = pct_to_target(vh, target)
    rows: list[str] = [
        f"validated_height={vh}",
        f"pct_to_target={pct}%",
        f"target_height={target}",
    ]
    if last_end is not None:
        rows.append(f"last_batch_validated_delta={last_end.validated_delta}")
        rows.append(f"last_batch_timestamp={last_end.timestamp}")
    else:
        rows.append("last_batch_validated_delta=")
        rows.append("last_batch_timestamp=")
    return tuple(rows)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Report sync batch progress from log and optional native status.")
    parser.add_argument(
        "--log",
        type=Path,
        default=Path("sync_batch_run.log"),
        help="Path to sync_batch_run.log (default: ./sync_batch_run.log)",
    )
    parser.add_argument(
        "--target",
        type=int,
        default=10_000,
        help="Target height for %% progress (default: 10000)",
    )
    parser.add_argument(
        "--datadir",
        nargs="?",
        const=Path("data-cpp"),
        default=None,
        type=Path,
        help="Read validated_height from RocksDB-native cpbitnode-db status "
        "(default path when flag is bare: ./data-cpp)",
    )
    parser.add_argument(
        "--status-bin",
        type=Path,
        default=Path("build/cpbitnode-db"),
        help="cpbitnode-db executable (default: build/cpbitnode-db)",
    )

    ns = parser.parse_args(argv)

    try:
        for line in build_report(
            log_path=ns.log,
            target=ns.target,
            datadir=ns.datadir,
            status_bin=ns.status_bin,
        ):
            print(line)
    except (OSError, ValueError, subprocess.CalledProcessError, json.JSONDecodeError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
