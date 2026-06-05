#!/usr/bin/env python3
"""Render benchmark telemetry ticks as concise operator updates.

The monitor reads lines containing:

    benchmark.telemetry_tick {"schema":"benchmark.telemetry_tick.v1", ...}

from stdin or a log file. It does not write Project state.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path
from typing import Any, Iterable


PREFIX = "benchmark.telemetry_tick "


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--file", type=Path, help="Log file to read")
    parser.add_argument("--follow", action="store_true", help="Keep polling the log file")
    parser.add_argument("--interval-sec", type=int, default=15)
    parser.add_argument("--height-interval", type=int, default=2500)
    return parser.parse_args()


def ticks_from_lines(lines: Iterable[str]) -> Iterable[dict[str, Any]]:
    for line in lines:
        marker = line.find(PREFIX)
        if marker < 0:
            continue
        raw = line[marker + len(PREFIX) :].strip()
        try:
            tick = json.loads(raw)
        except json.JSONDecodeError:
            continue
        if isinstance(tick, dict) and tick.get("schema") == "benchmark.telemetry_tick.v1":
            yield tick


def follow_lines(path: Path) -> Iterable[str]:
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        while True:
            line = handle.readline()
            if line:
                yield line
                continue
            time.sleep(1)


def read_lines(args: argparse.Namespace) -> Iterable[str]:
    if args.file is None:
        yield from sys.stdin
        return
    if args.follow:
        yield from follow_lines(args.file)
        return
    with args.file.open("r", encoding="utf-8", errors="replace") as handle:
        yield from handle


def ms_duration(ms: int | float | None) -> str:
    if ms is None:
        return "?"
    seconds = int(ms // 1000)
    minutes, seconds = divmod(seconds, 60)
    if minutes:
        return f"{minutes}m{seconds:02d}s"
    return f"{seconds}s"


def num(value: Any, default: float = 0.0) -> float:
    if isinstance(value, (int, float)):
        return float(value)
    return default


def fmt_tick(tick: dict[str, Any]) -> str:
    buckets = tick.get("timing_buckets_ms")
    if not isinstance(buckets, dict):
        buckets = {}
    blocker = "present" if tick.get("current_blocker") else "null"
    return (
        f"[{tick.get('port', '?')} {tick.get('gate', '?')}] "
        f"{tick.get('height', '?')}/{tick.get('target_height', '?')} "
        f"{num(tick.get('percent')):.1f}% "
        f"elapsed={ms_duration(num(tick.get('elapsed_ms')))} "
        f"rate={num(tick.get('rate_recent_blocks_per_second')):.1f}/"
        f"{num(tick.get('rate_total_blocks_per_second')):.1f} blocks/s "
        f"phase={tick.get('phase', '?')} "
        f"utxos={tick.get('utxos', '?')} "
        f"last={tick.get('last_block_ms', '?')}ms "
        f"p2p={buckets.get('p2p_fetch', 0)}ms "
        f"script={buckets.get('script_verify', 0)}ms "
        f"commit={buckets.get('commit', 0)}ms "
        f"connect={buckets.get('block_connect_store_commit', 0)}ms "
        f"blocker={blocker}"
    )


def should_emit(
    tick: dict[str, Any],
    last: dict[str, Any] | None,
    interval_ms: int,
    height_interval: int,
) -> bool:
    if last is None:
        return True
    if tick.get("current_blocker"):
        return True
    if tick.get("phase") == "complete":
        return True
    height_delta = int(num(tick.get("height"))) - int(num(last.get("height")))
    elapsed_delta = int(num(tick.get("elapsed_ms"))) - int(num(last.get("elapsed_ms")))
    return height_delta >= height_interval or elapsed_delta >= interval_ms


def main() -> int:
    args = parse_args()
    emitted: dict[str, Any] | None = None
    interval_ms = args.interval_sec * 1000
    for tick in ticks_from_lines(read_lines(args)):
        if should_emit(tick, emitted, interval_ms, args.height_interval):
            print(fmt_tick(tick), flush=True)
            emitted = tick
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
