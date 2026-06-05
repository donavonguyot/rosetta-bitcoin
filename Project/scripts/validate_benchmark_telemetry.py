#!/usr/bin/env python3
"""Validate benchmark.telemetry_tick.v1 JSONL emitted by long proof runs."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Iterable


PREFIX = "benchmark.telemetry_tick "
REQUIRED_FIELDS = (
    "schema",
    "port",
    "gate",
    "height",
    "elapsed_ms",
    "rate_recent_blocks_per_second",
    "rate_total_blocks_per_second",
    "phase",
    "utxos",
    "current_blocker",
    "timing_buckets_ms",
)
REQUIRED_BUCKETS = (
    "p2p_fetch",
    "block_parse_validate",
    "utxo_load",
    "script_verify",
    "utxo_apply",
    "commit",
    "block_connect_store_commit",
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("logs", nargs="*", type=Path, help="Log files; stdin is used when omitted")
    parser.add_argument("--min-ticks", type=int, default=1)
    parser.add_argument("--require-bounded-target", action="store_true")
    return parser.parse_args()


def iter_lines(paths: list[Path]) -> Iterable[tuple[str, str]]:
    if not paths:
        for line in sys.stdin:
            yield "stdin", line
        return
    for path in paths:
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                yield str(path), line


def parse_tick(source: str, line: str, errors: list[str]) -> dict[str, Any] | None:
    marker = line.find(PREFIX)
    if marker < 0:
        return None
    raw = line[marker + len(PREFIX) :].strip()
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as exc:
        errors.append(f"{source}: invalid telemetry JSON: {exc}")
        return None
    if not isinstance(parsed, dict):
        errors.append(f"{source}: telemetry payload must be a JSON object")
        return None
    return parsed


def validate_tick(source: str, tick: dict[str, Any], require_bounded_target: bool) -> list[str]:
    errors: list[str] = []
    if tick.get("schema") != "benchmark.telemetry_tick.v1":
        errors.append(f"{source}: schema must be benchmark.telemetry_tick.v1")
    for field in REQUIRED_FIELDS:
        if field not in tick:
            errors.append(f"{source}: missing required field {field}")
    if require_bounded_target and "target_height" not in tick:
        errors.append(f"{source}: missing target_height for bounded gate telemetry")
    buckets = tick.get("timing_buckets_ms")
    if not isinstance(buckets, dict):
        errors.append(f"{source}: timing_buckets_ms must be an object")
        return errors
    for bucket in REQUIRED_BUCKETS:
        if bucket not in buckets:
            errors.append(f"{source}: missing timing bucket {bucket}")
        elif not isinstance(buckets[bucket], (int, float)):
            errors.append(f"{source}: timing bucket {bucket} must be numeric")
    return errors


def main() -> int:
    args = parse_args()
    errors: list[str] = []
    tick_count = 0
    complete_count = 0
    for source, line in iter_lines(args.logs):
        tick = parse_tick(source, line, errors)
        if tick is None:
            continue
        tick_count += 1
        if tick.get("phase") == "complete":
            complete_count += 1
        errors.extend(validate_tick(source, tick, args.require_bounded_target))
    if tick_count < args.min_ticks:
        errors.append(f"telemetry tick count {tick_count} is below required minimum {args.min_ticks}")
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    print(
        f"benchmark_telemetry_validation ticks={tick_count} complete_ticks={complete_count} errors={len(errors)}"
    )
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
