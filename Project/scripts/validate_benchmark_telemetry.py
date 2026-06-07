#!/usr/bin/env python3
"""Validate full-run benchmark.telemetry_tick.v1 streams.

This validator is intentionally stricter than Project's historical importer.
It is the current-campaign acceptance surface for bounded long runs, where a
valid block proof is not enough unless operators can also see what happened.
"""

from __future__ import annotations

import argparse
import json
import sys
import tempfile
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


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

REQUIRED_TICK_FIELDS = (
    "schema",
    "port",
    "gate",
    "run_id",
    "event",
    "phase",
    "height",
    "target_height",
    "elapsed_ms",
    "monotonic_ms",
    "utxos",
    "current_blocker",
    "stall_class",
    "current_block_elapsed_ms",
    "current_block_height",
    "current_block_hash",
    "current_block_tx_count",
    "current_block_vin_count",
    "current_block_script_input_count",
    "timing_buckets_ms",
)

CANONICAL_PHASES = {
    "startup",
    "peer_connect",
    "header_sync",
    "block_fetch",
    "block_connect",
    "commit",
    "heartbeat",
    "complete",
    "failed",
}

CANONICAL_STALL_CLASSES = {
    "none",
    "startup_wait",
    "peer_wait",
    "header_wait",
    "block_wait",
    "block_connect_slow",
    "commit_slow",
    "process_crashed",
    "validation_blocker",
    "artifact_validation_failed",
}

REQUIRED_LIFECYCLE_EVENTS = (
    "run_started",
    "container_started",
    "node_started",
    "first_peer_byte",
    "first_block_connected",
    "target_reached",
    "run_finished",
)

LONG_RUN_GATES = {"shakedown_50k", "performance_100k", "tip_once", "tip_maintenance"}


@dataclass
class TelemetryValidation:
    quality: str
    ticks: list[dict[str, Any]]
    errors: list[str]
    warnings: list[str]
    summary: dict[str, Any]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("logs", nargs="*", type=Path, help="Log files; stdin is used when omitted")
    parser.add_argument("--gate", help="Expected benchmark gate")
    parser.add_argument("--port", help="Expected port")
    parser.add_argument("--target-height", type=int, help="Expected bounded target height")
    parser.add_argument("--min-ticks", type=int, default=1)
    parser.add_argument(
        "--heartbeat-max-ms",
        type=int,
        default=15_000,
        help="Expected heartbeat target; small jitter above this is warned, not rejected.",
    )
    parser.add_argument("--heartbeat-grace-ms", type=int, default=5_000)
    parser.add_argument("--heartbeat-hard-max-ms", type=int, default=30_000)
    parser.add_argument("--require-clean", action="store_true")
    parser.add_argument("--json", action="store_true", help="Emit machine-readable summary")
    parser.add_argument("--self-test", action="store_true", help="Run built-in validator tests")
    return parser.parse_args()


def iter_lines(paths: list[Path]) -> Iterable[tuple[str, str]]:
    if not paths:
        for line in sys.stdin:
            yield "stdin", line
        return
    for path in paths:
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            for line_number, line in enumerate(handle, start=1):
                yield f"{path}:{line_number}", line


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
    parsed.setdefault("_source", source)
    return parsed


def is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def as_int(value: Any, default: int = 0) -> int:
    if isinstance(value, bool):
        return default
    if isinstance(value, (int, float)):
        return int(value)
    try:
        return int(str(value))
    except (TypeError, ValueError):
        return default


def validate_tick(tick: dict[str, Any], *, gate: str | None, port: str | None, target_height: int | None) -> list[str]:
    source = str(tick.get("_source", "<tick>"))
    errors: list[str] = []
    if tick.get("schema") != "benchmark.telemetry_tick.v1":
        errors.append(f"{source}: schema must be benchmark.telemetry_tick.v1")
    for field in REQUIRED_TICK_FIELDS:
        if field not in tick:
            errors.append(f"{source}: missing required field {field}")
    if gate and tick.get("gate") != gate:
        errors.append(f"{source}: gate={tick.get('gate')!r}; expected {gate!r}")
    if port and tick.get("port") != port:
        errors.append(f"{source}: port={tick.get('port')!r}; expected {port!r}")
    if target_height is not None and tick.get("target_height") != target_height:
        errors.append(f"{source}: target_height={tick.get('target_height')!r}; expected {target_height!r}")
    phase = tick.get("phase")
    if phase not in CANONICAL_PHASES:
        errors.append(f"{source}: invalid phase {phase!r}")
    stall_class = tick.get("stall_class")
    if stall_class not in CANONICAL_STALL_CLASSES:
        errors.append(f"{source}: invalid stall_class {stall_class!r}")
    if tick.get("current_blocker") and stall_class != "validation_blocker":
        errors.append(f"{source}: current_blocker requires stall_class=validation_blocker")
    for field in (
        "height",
        "target_height",
        "elapsed_ms",
        "monotonic_ms",
        "utxos",
        "current_block_elapsed_ms",
        "current_block_height",
        "current_block_tx_count",
        "current_block_vin_count",
        "current_block_script_input_count",
    ):
        if field in tick and not is_number(tick[field]):
            errors.append(f"{source}: {field} must be numeric")
        elif field in tick and tick[field] < 0:
            errors.append(f"{source}: {field} must be nonnegative")
    if "current_block_hash" in tick and tick["current_block_hash"] is not None:
        if not isinstance(tick["current_block_hash"], str):
            errors.append(f"{source}: current_block_hash must be string or null")
    buckets = tick.get("timing_buckets_ms")
    if not isinstance(buckets, dict):
        errors.append(f"{source}: timing_buckets_ms must be an object")
    else:
        for bucket in REQUIRED_BUCKETS:
            value = buckets.get(bucket)
            if not is_number(value) or value < 0:
                errors.append(f"{source}: timing_buckets_ms.{bucket} must be a nonnegative number")
    if stall_class == "block_connect_slow" and phase != "block_connect":
        errors.append(f"{source}: block_connect_slow must use phase=block_connect")
    if stall_class == "commit_slow" and phase != "commit":
        errors.append(f"{source}: commit_slow must use phase=commit")
    return errors


def telemetry_summary(
    ticks: list[dict[str, Any]],
    heartbeat_max_ms: int,
    heartbeat_grace_ms: int,
    heartbeat_hard_max_ms: int,
) -> dict[str, Any]:
    lifecycle: dict[str, int] = {}
    phase_counts: Counter[str] = Counter()
    stall_counts: Counter[str] = Counter()
    max_gap = 0
    last_monotonic: int | None = None
    slow_blocks: list[dict[str, Any]] = []
    for tick in ticks:
        event = str(tick.get("event", ""))
        monotonic = as_int(tick.get("monotonic_ms"), 0)
        if event and event not in lifecycle:
            lifecycle[event] = monotonic
        phase_counts[str(tick.get("phase", ""))] += 1
        stall_counts[str(tick.get("stall_class", ""))] += 1
        if last_monotonic is not None:
            max_gap = max(max_gap, monotonic - last_monotonic)
        last_monotonic = monotonic
        if tick.get("stall_class") in {"block_connect_slow", "commit_slow"}:
            slow_blocks.append(
                {
                    "height": tick.get("current_block_height"),
                    "hash": tick.get("current_block_hash"),
                    "elapsed_ms": tick.get("current_block_elapsed_ms"),
                    "tx_count": tick.get("current_block_tx_count"),
                    "vin_count": tick.get("current_block_vin_count"),
                    "script_input_count": tick.get("current_block_script_input_count"),
                    "stall_class": tick.get("stall_class"),
                }
            )
    return {
        "tick_count": len(ticks),
        "lifecycle_markers": lifecycle,
        "heartbeat_max_gap_ms": max_gap,
        "heartbeat_target_ms": heartbeat_max_ms,
        "heartbeat_grace_ms": heartbeat_grace_ms,
        "heartbeat_warning_ms": heartbeat_max_ms,
        "heartbeat_failure_ms": heartbeat_max_ms + heartbeat_grace_ms,
        "heartbeat_hard_failure_ms": heartbeat_hard_max_ms,
        "heartbeat_limit_ms": heartbeat_max_ms + heartbeat_grace_ms,
        "phase_counts": dict(sorted(phase_counts.items())),
        "stall_class_counts": dict(sorted(stall_counts.items())),
        "slow_blocks": slow_blocks[:10],
    }


def classify_quality(ticks: list[dict[str, Any]], errors: list[str], sparse: bool = False) -> str:
    if not ticks:
        return "missing"
    if errors:
        return "invalid"
    if sparse:
        return "sparse"
    return "clean"


def validate_ticks(
    ticks: list[dict[str, Any]],
    *,
    gate: str | None = None,
    port: str | None = None,
    target_height: int | None = None,
    min_ticks: int = 1,
    heartbeat_max_ms: int = 15_000,
    heartbeat_grace_ms: int = 5_000,
    heartbeat_hard_max_ms: int = 30_000,
) -> TelemetryValidation:
    errors: list[str] = []
    warnings: list[str] = []
    sparse = False
    if len(ticks) < min_ticks:
        errors.append(f"telemetry tick count {len(ticks)} is below required minimum {min_ticks}")
    for tick in ticks:
        errors.extend(validate_tick(tick, gate=gate, port=port, target_height=target_height))
    sorted_ticks = sorted(ticks, key=lambda item: (as_int(item.get("monotonic_ms"), 0), as_int(item.get("elapsed_ms"), 0)))
    last_elapsed: int | None = None
    last_monotonic: int | None = None
    max_gap = 0
    gaps_over_target: list[tuple[int, str]] = []
    gaps_over_failure: list[tuple[int, str]] = []
    gaps_over_hard: list[tuple[int, str]] = []
    heartbeat_failure_ms = heartbeat_max_ms + heartbeat_grace_ms
    for tick in sorted_ticks:
        elapsed = as_int(tick.get("elapsed_ms"), 0)
        monotonic = as_int(tick.get("monotonic_ms"), 0)
        source = str(tick.get("_source", "<tick>"))
        if last_elapsed is not None and elapsed < last_elapsed:
            errors.append(f"{source}: elapsed_ms moved backward")
        if last_monotonic is not None:
            if monotonic < last_monotonic:
                errors.append(f"{source}: monotonic_ms moved backward")
            gap = monotonic - last_monotonic
            max_gap = max(max_gap, gap)
            if gap > heartbeat_max_ms:
                gaps_over_target.append((gap, source))
            if gap > heartbeat_failure_ms:
                gaps_over_failure.append((gap, source))
            if gap > heartbeat_hard_max_ms:
                gaps_over_hard.append((gap, source))
        last_elapsed = elapsed
        last_monotonic = monotonic
    events = {str(tick.get("event", "")) for tick in ticks}
    missing_events = [event for event in REQUIRED_LIFECYCLE_EVENTS if event not in events]
    if missing_events:
        warnings.append("missing lifecycle events: " + ",".join(missing_events))
        sparse = True
    if gate in LONG_RUN_GATES:
        if gaps_over_target:
            max_jitter_gap, max_jitter_source = max(gaps_over_target, key=lambda item: item[0])
            warnings.append(
                f"heartbeat max gap {max_jitter_gap}ms exceeds target {heartbeat_max_ms}ms at {max_jitter_source}"
            )
        if gaps_over_hard:
            max_hard_gap, max_hard_source = max(gaps_over_hard, key=lambda item: item[0])
            errors.append(
                f"heartbeat max gap {max_hard_gap}ms exceeds hard limit {heartbeat_hard_max_ms}ms at {max_hard_source}"
            )
        elif len(gaps_over_failure) >= 2:
            sample = ", ".join(f"{gap}ms at {source}" for gap, source in gaps_over_failure[:3])
            errors.append(
                f"heartbeat has {len(gaps_over_failure)} gaps over failure threshold {heartbeat_failure_ms}ms: {sample}"
            )
    if target_height is not None:
        final_heights = [as_int(tick.get("height"), -1) for tick in ticks if tick.get("event") in {"target_reached", "run_finished"} or tick.get("phase") == "complete"]
        if not final_heights or max(final_heights) < target_height:
            errors.append(f"no completion tick reached target_height {target_height}")
    if "run_finished" in events and "target_reached" not in events and target_height is not None:
        errors.append("run_finished appeared without target_reached")
    summary = telemetry_summary(sorted_ticks, heartbeat_max_ms, heartbeat_grace_ms, heartbeat_hard_max_ms)
    summary["heartbeat_gaps_over_target"] = len(gaps_over_target)
    summary["heartbeat_gaps_over_failure"] = len(gaps_over_failure)
    quality = classify_quality(sorted_ticks, errors, sparse)
    summary["telemetry_quality"] = quality
    return TelemetryValidation(quality=quality, ticks=sorted_ticks, errors=errors, warnings=warnings, summary=summary)


def validate_log_paths(
    paths: list[Path],
    *,
    gate: str | None = None,
    port: str | None = None,
    target_height: int | None = None,
    min_ticks: int = 1,
    heartbeat_max_ms: int = 15_000,
    heartbeat_grace_ms: int = 5_000,
    heartbeat_hard_max_ms: int = 30_000,
) -> TelemetryValidation:
    parse_errors: list[str] = []
    ticks: list[dict[str, Any]] = []
    for source, line in iter_lines(paths):
        tick = parse_tick(source, line, parse_errors)
        if tick is not None:
            ticks.append(tick)
    validation = validate_ticks(
        ticks,
        gate=gate,
        port=port,
        target_height=target_height,
        min_ticks=min_ticks,
        heartbeat_max_ms=heartbeat_max_ms,
        heartbeat_grace_ms=heartbeat_grace_ms,
        heartbeat_hard_max_ms=heartbeat_hard_max_ms,
    )
    validation.errors[:0] = parse_errors
    if parse_errors and validation.quality == "clean":
        validation.quality = "invalid"
        validation.summary["telemetry_quality"] = "invalid"
    return validation


def _tick(**overrides: Any) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "schema": "benchmark.telemetry_tick.v1",
        "port": "rust",
        "gate": "shakedown_50k",
        "run_id": "selftest",
        "event": "heartbeat",
        "phase": "heartbeat",
        "height": 0,
        "target_height": 50000,
        "elapsed_ms": 0,
        "monotonic_ms": 0,
        "utxos": 0,
        "current_blocker": None,
        "stall_class": "none",
        "current_block_elapsed_ms": 0,
        "current_block_height": 0,
        "current_block_hash": None,
        "current_block_tx_count": 0,
        "current_block_vin_count": 0,
        "current_block_script_input_count": 0,
        "timing_buckets_ms": {bucket: 0 for bucket in REQUIRED_BUCKETS},
    }
    payload.update(overrides)
    return payload


def self_test() -> int:
    clean_ticks = [
        _tick(event="run_started", phase="startup", monotonic_ms=0, elapsed_ms=0),
        _tick(event="container_started", phase="startup", monotonic_ms=1_000, elapsed_ms=1_000),
        _tick(event="node_started", phase="startup", monotonic_ms=2_000, elapsed_ms=2_000),
        _tick(event="first_peer_byte", phase="peer_connect", monotonic_ms=3_000, elapsed_ms=3_000),
        _tick(event="first_block_connected", phase="block_connect", height=1, current_block_height=1, monotonic_ms=4_000, elapsed_ms=4_000),
        _tick(event="heartbeat", phase="heartbeat", height=25000, current_block_height=25000, monotonic_ms=14_000, elapsed_ms=14_000),
        _tick(
            event="slow_block",
            phase="block_connect",
            stall_class="block_connect_slow",
            height=30000,
            current_block_height=30000,
            current_block_elapsed_ms=16_000,
            current_block_tx_count=2,
            current_block_vin_count=6761,
            current_block_script_input_count=6761,
            monotonic_ms=24_000,
            elapsed_ms=24_000,
        ),
        _tick(event="target_reached", phase="complete", height=50000, current_block_height=50000, monotonic_ms=34_000, elapsed_ms=34_000),
        _tick(event="run_finished", phase="complete", height=50000, current_block_height=50000, monotonic_ms=35_000, elapsed_ms=35_000),
    ]
    sparse_ticks = [tick for tick in clean_ticks if tick["event"] not in {"container_started", "first_peer_byte"}]
    missing_heartbeat = [dict(tick) for tick in clean_ticks]
    missing_heartbeat[5]["monotonic_ms"] = 50_000
    jitter_ticks = [dict(tick) for tick in clean_ticks]
    jitter_ticks[5]["monotonic_ms"] = 15_057
    single_long_gap = [dict(tick) for tick in clean_ticks]
    for tick in single_long_gap[5:]:
        tick["monotonic_ms"] = as_int(tick["monotonic_ms"]) + 11_000
        tick["elapsed_ms"] = as_int(tick["elapsed_ms"]) + 11_000
    repeated_long_gap = [dict(tick) for tick in clean_ticks]
    for tick in repeated_long_gap[5:]:
        tick["monotonic_ms"] = as_int(tick["monotonic_ms"]) + 11_000
        tick["elapsed_ms"] = as_int(tick["elapsed_ms"]) + 11_000
    for tick in repeated_long_gap[6:]:
        tick["monotonic_ms"] = as_int(tick["monotonic_ms"]) + 11_000
        tick["elapsed_ms"] = as_int(tick["elapsed_ms"]) + 11_000
    bad_phase = [dict(tick) for tick in clean_ticks]
    bad_phase[1]["phase"] = "syncing"
    bad_stall = [dict(tick) for tick in clean_ticks]
    bad_stall[6]["stall_class"] = "mystery"
    cases = [
        ("clean", clean_ticks, "clean"),
        ("jitter", jitter_ticks, "clean"),
        ("single_long_gap", single_long_gap, "clean"),
        ("repeated_long_gap", repeated_long_gap, "invalid"),
        ("sparse", sparse_ticks, "sparse"),
        ("missing_heartbeat", missing_heartbeat, "invalid"),
        ("bad_phase", bad_phase, "invalid"),
        ("bad_stall", bad_stall, "invalid"),
    ]
    failures = 0
    for name, ticks, expected in cases:
        result = validate_ticks(ticks, gate="shakedown_50k", port="rust", target_height=50000, min_ticks=1)
        if result.quality != expected:
            failures += 1
            print(f"self_test {name}: quality={result.quality} expected={expected} errors={result.errors} warnings={result.warnings}")
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "clean.log"
        path.write_text("\n".join(PREFIX + json.dumps(tick) for tick in clean_ticks), encoding="utf-8")
        result = validate_log_paths([path], gate="shakedown_50k", port="rust", target_height=50000)
        if result.quality != "clean":
            failures += 1
            print(f"self_test parse_log: quality={result.quality} errors={result.errors} warnings={result.warnings}")
    print(f"benchmark_telemetry_validator_self_test cases={len(cases) + 1} failures={failures}")
    return 1 if failures else 0


def main() -> int:
    args = parse_args()
    if args.self_test:
        return self_test()
    result = validate_log_paths(
        args.logs,
        gate=args.gate,
        port=args.port,
        target_height=args.target_height,
        min_ticks=args.min_ticks,
        heartbeat_max_ms=args.heartbeat_max_ms,
        heartbeat_grace_ms=args.heartbeat_grace_ms,
        heartbeat_hard_max_ms=args.heartbeat_hard_max_ms,
    )
    if args.json:
        print(
            json.dumps(
                {
                    "quality": result.quality,
                    "errors": result.errors,
                    "warnings": result.warnings,
                    "summary": result.summary,
                },
                indent=2,
                sort_keys=True,
            )
        )
    else:
        for warning in result.warnings:
            print(f"warning: {warning}", file=sys.stderr)
        for error in result.errors:
            print(f"error: {error}", file=sys.stderr)
        print(
            f"benchmark_telemetry_validation quality={result.quality} "
            f"ticks={len(result.ticks)} errors={len(result.errors)} warnings={len(result.warnings)}"
        )
    if args.require_clean and result.quality != "clean":
        return 1
    return 1 if result.errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
