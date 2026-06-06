#!/usr/bin/env python3
import argparse
import json
import os
import sys
import time
from typing import Any


PREFIX = "benchmark.telemetry_tick "
REQUIRED_BUCKETS = (
    "p2p_fetch",
    "block_parse_validate",
    "utxo_load",
    "script_verify",
    "utxo_apply",
    "commit",
    "block_connect_store_commit",
)


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


def canonical_phase(phase: str | None, event: str, blocker: Any) -> str:
    if blocker:
        return "failed"
    text = (phase or "").strip().lower()
    if event in {"run_started", "container_started", "node_started"}:
        return "startup"
    if event == "first_peer_byte":
        return "peer_connect"
    if event == "first_block_connected":
        return "block_connect"
    if event in {"target_reached", "run_finished"}:
        return "complete"
    if text in {"startup", "peer_connect", "header_sync", "block_fetch", "block_connect", "commit", "heartbeat", "complete", "failed"}:
        return text
    if "header" in text:
        return "header_sync"
    if "commit" in text:
        return "commit"
    return "heartbeat"


def stall_class(phase: str, blocker: Any, process_running: bool | None) -> str:
    if blocker:
        return "validation_blocker"
    if phase == "startup":
        return "none"
    if process_running is False and phase not in {"complete", "failed"}:
        return "process_crashed"
    return "none"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Emit benchmark.telemetry_tick JSONL from Java status JSON")
    parser.add_argument("--port", default=os.environ.get("BENCHMARK_PORT", "java"))
    parser.add_argument("--gate", default=os.environ.get("BENCHMARK_GATE"))
    parser.add_argument("--target-height", type=int, default=int(os.environ.get("TARGET_BLOCK_HEIGHT", os.environ.get("BLOCKS_MAX", "0")) or 0))
    parser.add_argument("--started-ms", type=int, default=int(os.environ.get("BENCHMARK_STARTED_MS", "0") or 0))
    parser.add_argument("--last-height", type=int, default=int(os.environ.get("BENCHMARK_LAST_HEIGHT", "0") or 0))
    parser.add_argument("--poll-sec", type=float, default=float(os.environ.get("POLL_SEC", "15") or 15))
    parser.add_argument("--phase", default=os.environ.get("BENCHMARK_PHASE"))
    parser.add_argument("--event", default=os.environ.get("BENCHMARK_EVENT", "heartbeat"))
    parser.add_argument("--run-id", default=os.environ.get("BENCHMARK_RUN_ID"))
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
    blocker = status.get("current_blocker")
    event = args.event or "heartbeat"
    phase = canonical_phase(args.phase, event, blocker)
    sync = status.get("sync") if isinstance(status.get("sync"), dict) else {}
    tick = {
        "schema": "benchmark.telemetry_tick.v1",
        "port": args.port,
        "gate": args.gate or derive_gate(target_height),
        "run_id": args.run_id or f"{args.port}-{args.gate or derive_gate(target_height)}-{args.started_ms}",
        "event": event,
        "target_height": target_height,
        "height": height,
        "header_height": int_or_none(status.get("header_height")) or 0,
        "stored_block_height": int_or_none(status.get("stored_block_height")) or 0,
        "percent": round((height / target_height) * 100, 2) if target_height > 0 else 0,
        "elapsed_ms": elapsed_ms,
        "monotonic_ms": elapsed_ms,
        "rate_recent_blocks_per_second": round(delta / poll_sec, 3),
        "rate_total_blocks_per_second": round(height / elapsed_sec, 3) if elapsed_sec > 0 else 0,
        "phase": phase,
        "utxos": int_or_none(status.get("chainstate_utxo_count")) or int_or_none(status.get("utxo_count")) or 0,
        "last_block_ms": 0,
        "sync_status": sync.get("sync_status") or status.get("sync_status") or "",
        "timing_buckets_ms": {bucket: 0 for bucket in REQUIRED_BUCKETS},
        "current_blocker": blocker,
        "stall_class": stall_class(phase, blocker, process_running),
        "current_block_elapsed_ms": 0,
        "current_block_height": height,
        "current_block_hash": status.get("validated_hash") or None,
        "current_block_tx_count": 0,
        "current_block_vin_count": 0,
        "current_block_script_input_count": 0,
    }
    if process_running is not None:
        tick["process_running"] = process_running
    print(PREFIX + json.dumps(tick, separators=(",", ":"), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
