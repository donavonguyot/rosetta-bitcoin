#!/usr/bin/env python3
import argparse
import json
import os
import sys
import time
from typing import Any


PREFIX = "benchmark.telemetry_tick "


def int_or_none(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return int(value)
    if isinstance(value, str):
        try:
            return int(value)
        except ValueError:
            return None
    return None


def bool_or_none(value: Any) -> bool | None:
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        lowered = value.strip().lower()
        if lowered in {"1", "true", "yes", "on"}:
            return True
        if lowered in {"0", "false", "no", "off"}:
            return False
    return None


def derive_gate(target_height: int) -> str:
    return {
        5000: "baseline_5k",
        10000: "diagnostic_10k",
        50000: "shakedown_50k",
        100000: "performance_100k",
    }.get(target_height, "local_reference")


def timing_buckets_ms(sync_timing: Any) -> dict[str, int]:
    if not isinstance(sync_timing, dict):
        return {}
    unit = str(sync_timing.get("Unit", "")).lower()
    stages = sync_timing.get("Stages")
    if not isinstance(stages, dict):
        return {}
    total_key = "TotalMicros" if "micro" in unit else "TotalMillis"
    buckets: dict[str, int] = {}
    for stage, values in stages.items():
        if not isinstance(stage, str) or not isinstance(values, dict):
            continue
        total = int_or_none(values.get(total_key)) or 0
        buckets[stage] = max(0, round(total / 1000)) if "micro" in unit else max(0, total)
    return buckets


def newest_slow_block_ms(sync_timing: Any, height: int | None) -> int | None:
    if not isinstance(sync_timing, dict) or height is None:
        return None
    slow_blocks = sync_timing.get("SlowBlocks")
    if not isinstance(slow_blocks, list):
        return None
    for row in slow_blocks:
        if not isinstance(row, dict):
            continue
        if int_or_none(row.get("Height")) == height:
            micros = int_or_none(row.get("Micros"))
            if micros is not None:
                return max(0, round(micros / 1000))
    return None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Emit benchmark.telemetry_tick JSONL from C# status JSON")
    parser.add_argument("--port", default=os.environ.get("BENCHMARK_PORT", "csharp"))
    parser.add_argument("--gate", default=os.environ.get("BENCHMARK_GATE"))
    parser.add_argument("--target-height", type=int, default=int(os.environ.get("TARGET_BLOCK_HEIGHT", os.environ.get("BLOCKS_MAX", "0")) or 0))
    parser.add_argument("--started-ms", type=int, default=int(os.environ.get("BENCHMARK_STARTED_MS", "0") or 0))
    parser.add_argument("--last-height", type=int, default=int(os.environ.get("BENCHMARK_LAST_HEIGHT", "0") or 0))
    parser.add_argument("--poll-sec", type=float, default=float(os.environ.get("POLL_SEC", "120") or 120))
    parser.add_argument("--phase", default=os.environ.get("BENCHMARK_PHASE"))
    parser.add_argument("--process-running", default=os.environ.get("BENCHMARK_PROCESS_RUNNING"))
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        status = json.load(sys.stdin)
    except json.JSONDecodeError:
        status = {}
    if not isinstance(status, dict):
        status = {}

    now_ms = int(time.time() * 1000)
    elapsed_ms = max(0, now_ms - args.started_ms) if args.started_ms > 0 else 0
    height = int_or_none(status.get("validated_height")) or 0
    target_height = args.target_height or height
    delta = max(0, height - args.last_height)
    poll_sec = args.poll_sec if args.poll_sec > 0 else 1
    elapsed_sec = elapsed_ms / 1000 if elapsed_ms > 0 else 0
    process_running = bool_or_none(args.process_running)

    tick = {
        "schema": "benchmark.telemetry_tick.v1",
        "port": args.port,
        "gate": args.gate or derive_gate(target_height),
        "target_height": target_height,
        "height": height,
        "header_height": int_or_none(status.get("header_height")) or 0,
        "stored_block_height": int_or_none(status.get("stored_block_height")) or 0,
        "percent": round((height / target_height) * 100, 2) if target_height > 0 else 0,
        "elapsed_ms": elapsed_ms,
        "rate_recent_blocks_per_second": round(delta / poll_sec, 3),
        "rate_total_blocks_per_second": round(height / elapsed_sec, 3) if elapsed_sec > 0 else 0,
        "phase": args.phase or str(status.get("sync_status") or "unknown"),
        "utxos": int_or_none(status.get("utxo_count")),
        "last_block_ms": newest_slow_block_ms(status.get("sync_timing"), height),
        "timing_buckets_ms": timing_buckets_ms(status.get("sync_timing")),
        "current_blocker": status.get("current_blocker"),
    }
    if process_running is not None:
        tick["process_running"] = process_running
    print(PREFIX + json.dumps(tick, separators=(",", ":"), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
