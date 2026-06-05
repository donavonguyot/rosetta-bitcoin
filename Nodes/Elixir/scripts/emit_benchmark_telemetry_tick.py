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


def parse_status(raw: str) -> dict[str, Any]:
    start = raw.find("{")
    end = raw.rfind("}")
    if start < 0 or end < start:
        return {}
    try:
        value = json.loads(raw[start : end + 1])
    except json.JSONDecodeError:
        return {}
    return value if isinstance(value, dict) else {}


def timing_buckets_ms(sync_timing: Any) -> dict[str, int]:
    buckets: dict[str, int] = {}
    if isinstance(sync_timing, dict) and isinstance(sync_timing.get("Stages"), dict):
        unit = str(sync_timing.get("Unit", "")).lower()
        total_key = "TotalMicros" if "micro" in unit else "TotalMillis"
        for stage, values in sync_timing["Stages"].items():
            if not isinstance(stage, str) or not isinstance(values, dict):
                continue
            total = int_or_none(values.get(total_key)) or 0
            buckets[stage] = max(0, round(total / 1000)) if "micro" in unit else max(0, total)
        return buckets
    if isinstance(sync_timing, dict):
        for stage, micros in sync_timing.items():
            if not isinstance(stage, str):
                continue
            total = int_or_none(micros)
            if total is not None:
                buckets[stage] = max(0, round(total / 1000))
    return buckets


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Emit benchmark.telemetry_tick JSONL from Elixir status JSON")
    parser.add_argument("--port", default=os.environ.get("BENCHMARK_PORT", "elixir"))
    parser.add_argument("--gate", default=os.environ.get("BENCHMARK_GATE", "supervisor"))
    parser.add_argument("--target-height", type=int, default=int(os.environ.get("TARGET_BLOCK_HEIGHT", os.environ.get("BLOCKS_MAX", "0")) or 0))
    parser.add_argument("--started-ms", type=int, default=int(os.environ.get("BENCHMARK_STARTED_MS", "0") or 0))
    parser.add_argument("--last-height", type=int, default=int(os.environ.get("BENCHMARK_LAST_HEIGHT", "-1") or -1))
    parser.add_argument("--poll-sec", type=float, default=float(os.environ.get("POLL_SEC", "120") or 120))
    parser.add_argument("--phase", default=os.environ.get("BENCHMARK_PHASE"))
    parser.add_argument("--process-running", default=os.environ.get("BENCHMARK_PROCESS_RUNNING"))
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    status = parse_status(sys.stdin.read())
    now_ms = int(time.time() * 1000)
    elapsed_ms = max(0, now_ms - args.started_ms) if args.started_ms > 0 else 0
    height = int_or_none(status.get("validated_height")) or 0
    target_height = args.target_height or height
    delta = max(0, height - args.last_height) if args.last_height >= 0 else 0
    elapsed_sec = elapsed_ms / 1000 if elapsed_ms > 0 else 0
    poll_sec = args.poll_sec if args.poll_sec > 0 else 1
    process_running = str(args.process_running).strip().lower() in {"1", "true", "yes", "on"}

    tick = {
        "schema": "benchmark.telemetry_tick.v1",
        "port": args.port,
        "gate": args.gate,
        "target_height": target_height,
        "height": height,
        "header_height": int_or_none(status.get("header_height")) or 0,
        "stored_block_height": int_or_none(status.get("stored_block_height")) or 0,
        "percent": round((height / target_height) * 100, 2) if target_height > 0 else 0,
        "elapsed_ms": elapsed_ms,
        "rate_recent_blocks_per_second": round(delta / poll_sec, 3),
        "rate_total_blocks_per_second": round(height / elapsed_sec, 3) if elapsed_sec > 0 else 0,
        "phase": args.phase or status.get("sync_status") or status.get("runtime_status") or "unknown",
        "utxos": int_or_none(status.get("chainstate_utxo_count") or status.get("utxo_count")),
        "last_block_ms": None,
        "timing_buckets_ms": timing_buckets_ms(status.get("sync_timing")),
        "current_blocker": status.get("current_blocker"),
        "process_running": process_running,
    }
    print(PREFIX + json.dumps(tick, separators=(",", ":"), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
