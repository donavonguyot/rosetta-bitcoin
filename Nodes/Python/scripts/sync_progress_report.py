#!/usr/bin/env python3
"""Summarize sync batch progress from logs and optional native RocksDB state."""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path

from pybitnode.db.tracker import ProjectTracker

_START_RE = re.compile(r"^=== batch (?P<num>\d+) start_validated=(?P<h>\d+) (?P<ts>[^ ]+) ===\s*$")
_END_RE = re.compile(r"^=== batch (?P<num>\d+) end_validated=(?P<h>\d+) downloaded_delta=(?P<dl>\d+) exit=(?P<exit>\d+) \((?P<ts>[^)]+)\) validated_delta=(?P<vd>\d+) ===\s*$")


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
    last_start: BatchStart | None = None
    last_end: BatchEnd | None = None
    for i, raw in enumerate(lines, start=1):
        line = raw.rstrip("\n")
        if m := _START_RE.match(line):
            last_start = BatchStart(i, int(m.group("num")), int(m.group("h")), m.group("ts"))
        elif m := _END_RE.match(line):
            last_end = BatchEnd(i, int(m.group("num")), int(m.group("h")), m.group("ts"), int(m.group("vd")))
    return last_start, last_end


def validated_height_from_log(last_start: BatchStart | None, last_end: BatchEnd | None) -> int | None:
    if last_end is None and last_start is None:
        return None
    if last_end is None:
        assert last_start is not None
        return last_start.start_validated
    if last_start is None or last_start.line_no <= last_end.line_no:
        return last_end.end_validated
    return last_start.start_validated


def pct_to_target(height: int, target: int) -> float:
    if target <= 0:
        return 0.0
    return min(100.0, round(100.0 * height / target, 2))


def read_validated_height_state(state_path: Path, *, chain: str) -> int:
    if not state_path.expanduser().exists():
        return 0
    tracker = ProjectTracker(state_path)
    try:
        return tracker.get_validated_height(chain)
    finally:
        tracker.close()


def build_report(*, log_path: Path, target: int, state_path: Path | None, chain: str) -> tuple[str, ...]:
    text = log_path.read_text(encoding="utf-8", errors="replace")
    last_start, last_end = parse_batch_log_lines(text.splitlines())
    if state_path is not None:
        vh = read_validated_height_state(state_path, chain=chain)
    else:
        vh_o = validated_height_from_log(last_start, last_end)
        if vh_o is None:
            raise ValueError(f"No batch start/end markers found in {log_path}")
        vh = vh_o
    rows = [
        f"validated_height={vh}",
        f"pct_to_target={pct_to_target(vh, target)}%",
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
    parser = argparse.ArgumentParser(description="Report sync batch progress from log and optional native state.")
    parser.add_argument("--log", type=Path, default=Path("sync_batch_run.log"))
    parser.add_argument("--target", type=int, default=10_000)
    parser.add_argument("--chain", default="testnet4")
    parser.add_argument("--state-path", nargs="?", const=Path("data/chainstate-rocksdb"), default=None, type=Path)
    ns = parser.parse_args(argv)
    try:
        for line in build_report(log_path=ns.log, target=ns.target, state_path=ns.state_path, chain=ns.chain):
            print(line)
    except (OSError, ValueError, RuntimeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
