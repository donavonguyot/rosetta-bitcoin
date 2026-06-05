#!/usr/bin/env python3
"""Pass through C++ benchmark logs and emit shared benchmark telemetry ticks."""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
from collections import deque
from typing import Any


def as_int(value: Any, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def target_label(target: int) -> str:
    if target == 5000:
        return "5k"
    if target % 1000 == 0:
        return f"{target // 1000}k"
    return str(target)


def benchmark_lane(target: int) -> str:
    if target == 100000:
        return "performance_100k_p2p"
    return f"supporting_{target_label(target)}_p2p"


def benchmark_gate(target: int) -> str:
    if target == 100000:
        return "performance_100k"
    return f"supporting_{target_label(target)}"


def pairs(line: str) -> dict[str, str]:
    return dict(re.findall(r"([A-Za-z0-9_]+)=([^ ]+)", line))


def compact_counts(raw: str | None) -> dict[str, int]:
    if not raw or raw == "none":
        return {}
    counts: dict[str, int] = {}
    for item in raw.split(","):
        if not item:
            continue
        name, _, value = item.partition(":")
        if not name:
            continue
        counts[name] = as_int(value)
    return counts


def ms_from_us(raw: Any) -> int:
    return round(as_int(raw) / 1000)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", type=int, required=True)
    parser.add_argument("--port", default="cpp")
    args = parser.parse_args()

    started = time.monotonic()
    last_height = 0
    last_tick_height = 0
    last_tick_time = started
    stage_totals: dict[str, int] = {
        "p2p_fetch": 0,
        "utxo_load": 0,
        "script_verify": 0,
        "script_verify_worker_cpu": 0,
        "utxo_apply": 0,
        "commit": 0,
        "block_connect_store_commit": 0,
    }
    slow_blocks: deque[dict[str, Any]] = deque(maxlen=10)

    for line in sys.stdin:
        sys.stdout.write(line)
        sys.stdout.flush()
        stripped = line.strip()
        now = time.monotonic()

        if stripped.startswith("cpbitnode_pipeline_timing "):
            parsed = pairs(stripped)
            p2p_us = as_int(parsed.get("block_fetch_wait"))
            if p2p_us == 0:
                p2p_us = as_int(parsed.get("p2p_header_read_us")) + as_int(parsed.get("p2p_payload_read_us"))
            stage_totals["p2p_fetch"] = ms_from_us(p2p_us)
            continue

        if not stripped.startswith("cpbitnode_sync_timing "):
            continue

        parsed = pairs(stripped)
        if parsed.get("unit") != "us":
            continue
        height = as_int(parsed.get("height"))
        if height <= 0:
            continue

        last_ms = ms_from_us(parsed.get("block_connect_store_commit"))
        block = {
            "height": height,
            "ms": last_ms,
            "tx_count": as_int(parsed.get("tx_count")),
            "vin_count": as_int(parsed.get("vin_count")),
            "vout_count": as_int(parsed.get("vout_count")),
            "script_input_count": as_int(parsed.get("script_input_count")),
            "input_shape_counts": compact_counts(parsed.get("input_shape_counts")),
            "spent_prevout_script_types": compact_counts(parsed.get("spent_prevout_script_types")),
            "output_script_types": compact_counts(parsed.get("output_script_types")),
        }
        slow_blocks.append(block)
        slow = sorted(slow_blocks, key=lambda item: item.get("ms", 0), reverse=True)

        for stage in [
            "utxo_load",
            "script_verify",
            "script_verify_worker_cpu",
            "utxo_apply",
            "commit",
            "block_connect_store_commit",
        ]:
            stage_totals[stage] = stage_totals.get(stage, 0) + ms_from_us(parsed.get(stage))

        elapsed_ms = round((now - started) * 1000)
        recent_elapsed = max(now - last_tick_time, 0.001)
        recent_height_delta = height - last_tick_height
        total_elapsed = max(now - started, 0.001)
        tick = {
            "schema": "benchmark.telemetry_tick.v1",
            "port": args.port,
            "gate": benchmark_gate(args.target),
            "benchmark_lane": benchmark_lane(args.target),
            "target": target_label(args.target),
            "target_height": args.target,
            "height": height,
            "percent": min(100.0, 100.0 * height / args.target),
            "hash": "",
            "tx_count": block["tx_count"],
            "elapsed_ms": elapsed_ms,
            "rate_recent_blocks_per_second": recent_height_delta / recent_elapsed,
            "rate_total_blocks_per_second": height / total_elapsed,
            "phase": "p2p_sync",
            "utxos": None,
            "last_block_ms": last_ms,
            "slow_blocks": slow,
            "current_blocker": None,
            "sync_status": "blocks_current" if height >= args.target else "syncing",
            "timing_buckets_ms": dict(sorted(stage_totals.items())),
        }
        print(f"benchmark.telemetry_tick {json.dumps(tick, sort_keys=True)}", flush=True)
        last_height = height
        last_tick_height = height
        last_tick_time = now

    return 0 if last_height >= 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
