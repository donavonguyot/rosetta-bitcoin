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
    if target == 5000:
        return "baseline_5k_p2p"
    if target == 50000:
        return "shakedown_50k_p2p"
    if target == 100000:
        return "performance_100k_p2p"
    return f"diagnostic_{target_label(target)}_p2p"


def benchmark_gate(target: int) -> str:
    if target == 5000:
        return "baseline_5k"
    if target == 50000:
        return "shakedown_50k"
    if target == 100000:
        return "performance_100k"
    return f"diagnostic_{target_label(target)}"


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
    run_id = f"{args.port}-{benchmark_gate(args.target)}-{int(time.time() * 1000)}"
    last_height = 0
    last_utxos = 0
    last_tick_height = 0
    last_tick_time = started
    stage_totals: dict[str, int] = {
        "p2p_fetch": 0,
        "block_parse_validate": 0,
        "utxo_load": 0,
        "script_verify": 0,
        "script_verify_worker_cpu": 0,
        "utxo_apply": 0,
        "commit": 0,
        "block_connect_store_commit": 0,
    }
    slow_blocks: deque[dict[str, Any]] = deque(maxlen=10)

    def emit_tick(
        *,
        event: str,
        phase: str,
        height: int,
        block: dict[str, Any] | None = None,
        stall_class: str = "none",
        last_ms: int = 0,
    ) -> None:
        nonlocal last_tick_height, last_tick_time
        block = block or {}
        now = time.monotonic()
        elapsed_ms = round((now - started) * 1000)
        recent_elapsed = max(now - last_tick_time, 0.001)
        recent_height_delta = height - last_tick_height
        total_elapsed = max(now - started, 0.001)
        if stall_class == "block_connect_slow":
            phase = "block_connect"
        tick = {
            "schema": "benchmark.telemetry_tick.v1",
            "port": args.port,
            "gate": benchmark_gate(args.target),
            "run_id": run_id,
            "event": event,
            "benchmark_lane": benchmark_lane(args.target),
            "target": target_label(args.target),
            "target_height": args.target,
            "height": height,
            "percent": min(100.0, 100.0 * max(0, height) / args.target),
            "hash": "",
            "tx_count": block.get("tx_count", 0),
            "elapsed_ms": elapsed_ms,
            "monotonic_ms": elapsed_ms,
            "rate_recent_blocks_per_second": recent_height_delta / recent_elapsed,
            "rate_total_blocks_per_second": max(0, height) / total_elapsed,
            "phase": phase,
            "utxos": last_utxos,
            "last_block_ms": last_ms,
            "stall_class": stall_class,
            "current_block_elapsed_ms": last_ms,
            "current_block_height": max(0, height),
            "current_block_hash": None,
            "current_block_tx_count": block.get("tx_count", 0),
            "current_block_vin_count": block.get("vin_count", 0),
            "current_block_script_input_count": block.get("script_input_count", 0),
            "slow_blocks": sorted(slow_blocks, key=lambda item: item.get("ms", 0), reverse=True),
            "current_blocker": None,
            "sync_status": "blocks_current" if height >= args.target else "syncing",
            "timing_buckets_ms": dict(sorted(stage_totals.items())),
        }
        print(f"benchmark.telemetry_tick {json.dumps(tick, sort_keys=True)}", flush=True)
        progress = {
            "chain": "testnet4",
            "sync_status": tick["sync_status"],
            "header_height": height,
            "validated_height": height,
            "validated_hash": "",
            "stored_block_height": height,
            "chainstate_utxo_count": last_utxos,
            "current_blocker": None,
            "peer": "",
            "current_block_height": max(0, height),
            "current_block_hash": None,
            "current_block_tx_count": block.get("tx_count", 0),
            "current_block_vin_count": block.get("vin_count", 0),
            "current_block_script_input_count": block.get("script_input_count", 0),
            "last_block_ms": last_ms,
            "native_crypto_backend": "libsecp256k1",
            "timing_buckets_ms": dict(sorted(stage_totals.items())),
        }
        print(f"rb.port_progress {json.dumps(progress, sort_keys=True)}", flush=True)
        last_tick_height = height
        last_tick_time = now

    emit_tick(event="run_started", phase="startup", height=0)
    emit_tick(event="container_started", phase="startup", height=0)
    emit_tick(event="node_started", phase="startup", height=0)
    first_peer_byte = False
    first_block_connected = False

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
            if not first_peer_byte:
                emit_tick(event="first_peer_byte", phase="peer_connect", height=max(0, last_height))
                first_peer_byte = True
            continue

        if not stripped.startswith("cpbitnode_sync_timing "):
            continue

        parsed = pairs(stripped)
        if parsed.get("unit") != "us":
            continue
        height = as_int(parsed.get("height"))
        if height <= 0:
            continue
        last_utxos = as_int(parsed.get("utxo_count"), last_utxos)

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
        for stage in [
            "utxo_load",
            "script_verify",
            "script_verify_worker_cpu",
            "utxo_apply",
            "commit",
            "block_connect_store_commit",
        ]:
            stage_totals[stage] = stage_totals.get(stage, 0) + ms_from_us(parsed.get(stage))

        if not first_block_connected and height > 0:
            emit_tick(event="first_block_connected", phase="block_connect", height=height, block=block, last_ms=last_ms)
            first_block_connected = True
        emit_tick(
            event="heartbeat",
            phase="heartbeat",
            height=height,
            block=block,
            stall_class="block_connect_slow" if last_ms >= 15_000 else "none",
            last_ms=last_ms,
        )
        last_height = height

    if last_height >= args.target:
        emit_tick(event="target_reached", phase="complete", height=last_height)
    emit_tick(event="run_finished", phase="complete" if last_height >= args.target else "failed", height=last_height)
    return 0 if last_height >= 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
