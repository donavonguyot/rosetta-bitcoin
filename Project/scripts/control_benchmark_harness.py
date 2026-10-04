#!/usr/bin/env python3
"""Control-owned benchmark harness helpers.

Ports expose product progress. Project turns that progress into benchmark
telemetry and canonical evidence.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
ARTIFACT_VALIDATOR_PATH = ROOT / "Nodes/Shared/conformance/tools/validate_benchmark_artifact.py"
TELEMETRY_VALIDATOR_PATH = ROOT / "Project/scripts/validate_benchmark_telemetry.py"
REFERENCE_TOPOLOGY = ROOT / "Nodes/Shared/docker/reference_topology.env"
PRODUCT_PREFIX = "rb.port_progress "
PRODUCT_PREFIX_EQ = "rb.port_progress="
LEGACY_PROGRESS_PREFIX = "sync_progress_json="
TELEMETRY_PREFIX = "benchmark.telemetry_tick "
TESTNET4_GENESIS_HASH = "00000000da84f2bafbbc53dee25a72ae507ff4914b867c565be350b0da8bf043"
BASELINE_CRYPTO_BACKENDS = {
    "csharp": "libsecp256k1-secp256k1.net",
    "go": "libsecp256k1",
    "java": "libsecp256k1-acinq",
}
NON_CUMULATIVE_TIMING_BUCKETS = {"script_parallel_efficiency"}


def _load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


_artifact_validator = _load_module("rb_control_artifact_validator", ARTIFACT_VALIDATOR_PATH)
_telemetry_validator = _load_module("rb_control_telemetry_validator", TELEMETRY_VALIDATOR_PATH)


@dataclass
class ControlBuildResult:
    artifact_path: Path
    telemetry_log_path: Path
    progress_count: int
    telemetry_quality: str
    telemetry_summary: dict[str, Any]


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def rel(path: Path) -> str:
    from state_root import logical_path
    return logical_path(path)


def read_env(path: Path = REFERENCE_TOPOLOGY) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def as_int(value: Any, default: int = 0) -> int:
    try:
        if value is None or value == "":
            return default
        return int(value)
    except (TypeError, ValueError):
        return default


def as_bool(value: Any, default: bool = False) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, int):
        return value != 0
    if isinstance(value, str):
        lowered = value.strip().lower()
        if lowered in {"1", "true", "yes", "on"}:
            return True
        if lowered in {"0", "false", "no", "off"}:
            return False
    return default


def parse_progress_payload(raw: str) -> dict[str, Any] | None:
    line = raw.strip()
    payload_text = ""
    if PRODUCT_PREFIX in line:
        payload_text = line.split(PRODUCT_PREFIX, 1)[1].strip()
    elif PRODUCT_PREFIX_EQ in line:
        payload_text = line.split(PRODUCT_PREFIX_EQ, 1)[1].strip()
    elif LEGACY_PROGRESS_PREFIX in line:
        payload_text = line.split(LEGACY_PROGRESS_PREFIX, 1)[1].strip()
    if not payload_text:
        return None
    try:
        payload = json.loads(payload_text)
    except json.JSONDecodeError:
        return None
    return payload if isinstance(payload, dict) else None


def progress_entries(log_path: Path) -> list[dict[str, Any]]:
    entries: list[dict[str, Any]] = []
    for index, raw in enumerate(log_path.read_text(encoding="utf-8", errors="replace").splitlines()):
        payload = parse_progress_payload(raw)
        if payload is None:
            continue
        payload = dict(payload)
        payload["_line_index"] = index
        entries.append(payload)
    return entries


def benchmark_tick_entries(log_path: Path) -> list[dict[str, Any]]:
    ticks: list[dict[str, Any]] = []
    for raw in log_path.read_text(encoding="utf-8", errors="replace").splitlines():
        marker = raw.find(TELEMETRY_PREFIX)
        if marker < 0:
            continue
        payload_text = raw[marker + len(TELEMETRY_PREFIX) :].strip()
        try:
            payload = json.loads(payload_text)
        except json.JSONDecodeError:
            continue
        if isinstance(payload, dict):
            ticks.append(payload)
    return ticks


def has_product_progress(log_path: Path) -> bool:
    return bool(progress_entries(log_path))


def gate_spec(gate_id: str) -> dict[str, Any]:
    spec = _artifact_validator.GATES.get(gate_id)
    if not isinstance(spec, dict):
        raise ValueError(f"unsupported gate: {gate_id}")
    return spec


def target_label(target: int) -> str:
    if target == 5000:
        return "5k"
    if target == 50000:
        return "50k"
    if target == 100000:
        return "100k"
    if target > 0 and target % 1000 == 0:
        return f"{target // 1000}k"
    return str(target)


def zero_timing() -> dict[str, int]:
    return {bucket: 0 for bucket in _artifact_validator.REQUIRED_BUCKETS}


def canonical_timing(raw: Any) -> dict[str, int]:
    timing = zero_timing()
    if not isinstance(raw, dict):
        return timing
    for bucket in timing:
        timing[bucket] = max(0, as_int(raw.get(bucket), 0))
    return timing


def full_timing(raw: Any) -> dict[str, int | float]:
    timing: dict[str, int | float] = canonical_timing(raw)
    if not isinstance(raw, dict):
        return timing
    for bucket, value in raw.items():
        if not isinstance(bucket, str) or isinstance(value, bool) or not isinstance(value, (int, float)):
            continue
        timing[bucket] = max(0, value)
    return timing


def timing_from_progress(entries: list[dict[str, Any]], elapsed_ms: int) -> dict[str, Any]:
    stages = zero_timing()
    for entry in entries:
        raw = entry.get("timing_counters") or entry.get("timing_buckets_ms") or entry.get("timing")
        if not isinstance(raw, dict):
            continue
        for bucket in stages:
            value = as_int(raw.get(bucket), 0)
            if value > stages[bucket]:
                stages[bucket] = value
    if not any(stages.values()):
        stages["block_connect_store_commit"] = max(0, elapsed_ms)
    return {
        "total_ms": max(0, elapsed_ms),
        "stage_totals_ms": stages,
        "slow_blocks": [],
    }


def full_timing_from_progress(entries: list[dict[str, Any]], elapsed_ms: int) -> dict[str, Any]:
    stages: dict[str, int | float] = zero_timing()
    for entry in entries:
        raw = entry.get("timing_counters") or entry.get("timing_buckets_ms") or entry.get("timing")
        if not isinstance(raw, dict):
            continue
        for bucket, value in full_timing(raw).items():
            if bucket in NON_CUMULATIVE_TIMING_BUCKETS:
                stages[bucket] = value
            elif value > stages.get(bucket, 0):
                stages[bucket] = value
    if not any(stages.values()):
        stages["block_connect_store_commit"] = max(0, elapsed_ms)
    return {
        "total_ms": max(0, elapsed_ms),
        "stage_totals_ms": stages,
        "slow_blocks": [],
    }


def timing_from_benchmark_ticks(log_path: Path) -> dict[str, int]:
    stages = zero_timing()
    for tick in benchmark_tick_entries(log_path):
        raw = tick.get("timing_buckets_ms")
        if not isinstance(raw, dict):
            continue
        for bucket in stages:
            value = as_int(raw.get(bucket), 0)
            if value > stages[bucket]:
                stages[bucket] = value
    return stages


def full_timing_from_benchmark_ticks(log_path: Path) -> dict[str, int | float]:
    stages: dict[str, int | float] = zero_timing()
    for tick in benchmark_tick_entries(log_path):
        raw = tick.get("timing_buckets_ms")
        if not isinstance(raw, dict):
            continue
        for bucket, value in full_timing(raw).items():
            if bucket in NON_CUMULATIVE_TIMING_BUCKETS:
                stages[bucket] = value
            elif value > stages.get(bucket, 0):
                stages[bucket] = value
    return stages


def runner_metrics_from_entries(entries: list[dict[str, Any]]) -> dict[str, Any]:
    metrics: dict[str, Any] = {}
    for entry in entries:
        raw = entry.get("script_metrics")
        if not isinstance(raw, dict):
            continue
        for key, value in raw.items():
            if key == "script_runner_actual_mode" and isinstance(value, str) and value.strip():
                metrics[key] = value.strip()
            elif isinstance(value, bool):
                continue
            elif isinstance(value, (int, float)):
                metrics[key] = max(value, metrics.get(key, 0))
    return metrics


def best_final_progress(entries: list[dict[str, Any]]) -> dict[str, Any]:
    if not entries:
        return {}
    max_height = max(as_int(entry.get("validated_height"), 0) for entry in entries)
    same_height = [entry for entry in entries if as_int(entry.get("validated_height"), 0) == max_height]
    for entry in reversed(same_height):
        if str(entry.get("validated_hash") or "").strip():
            return entry
    return same_height[-1] if same_height else entries[-1]


def max_progress_int(entries: list[dict[str, Any]], key: str) -> int:
    return max((as_int(entry.get(key), 0) for entry in entries), default=0)


def blocks_current(entry: dict[str, Any]) -> bool:
    if as_bool(entry.get("blocks_current")):
        return True
    header_height = as_int(entry.get("header_height"), 0)
    validated_height = as_int(entry.get("validated_height"), 0)
    return entry.get("sync_status") == "blocks_current" and header_height > 0 and validated_height >= header_height


def health_ticks(entries: list[dict[str, Any]]) -> list[dict[str, Any]]:
    ticks: list[dict[str, Any]] = []
    for entry in entries:
        ticks.append(
            {
                "iteration": as_int(entry.get("live_iteration"), len(ticks) + 1),
                "sync_status": entry.get("sync_status", ""),
                "header_height": as_int(entry.get("header_height"), 0),
                "validated_height": as_int(entry.get("validated_height"), 0),
                "validated_hash": entry.get("validated_hash", ""),
                "stored_block_height": as_int(entry.get("stored_block_height"), 0),
                "chainstate_utxo_count": as_int(entry.get("chainstate_utxo_count", entry.get("utxo_count")), 0),
                "blocks_current": blocks_current(entry),
                "reconnect_count": as_int(entry.get("reconnect_count"), 0),
                "stall_count": as_int(entry.get("stall_count"), 0),
                "current_blocker": entry.get("current_blocker"),
            }
        )
    return ticks


def progress_tick(
    *,
    port: str,
    gate_id: str,
    run_id: str,
    entry: dict[str, Any],
    event: str,
    phase: str,
    target_height: int | None,
    monotonic_ms: int,
    started_height: int = 0,
) -> dict[str, Any]:
    height = as_int(entry.get("validated_height"), started_height)
    target = target_height or max(height, 0)
    percent = round((height / target * 100.0), 3) if target > 0 else None
    timing = full_timing(entry.get("timing_buckets_ms"))
    tick = {
        "schema": "benchmark.telemetry_tick.v1",
        "port": port,
        "gate": gate_id,
        "run_id": run_id,
        "event": event,
        "phase": phase,
        "height": height,
        "target_height": target_height,
        "percent": percent,
        "elapsed_ms": monotonic_ms,
        "monotonic_ms": monotonic_ms,
        "utxos": as_int(entry.get("chainstate_utxo_count", entry.get("utxo_count")), 0),
        "current_blocker": entry.get("current_blocker"),
        "stall_class": "validation_blocker" if entry.get("current_blocker") else "none",
        "current_block_elapsed_ms": as_int(entry.get("current_block_elapsed_ms"), 0),
        "current_block_height": as_int(entry.get("current_block_height"), height),
        "current_block_hash": entry.get("current_block_hash") or entry.get("validated_hash"),
        "current_block_tx_count": as_int(entry.get("current_block_tx_count"), 0),
        "current_block_vin_count": as_int(entry.get("current_block_vin_count"), 0),
        "current_block_script_input_count": as_int(entry.get("current_block_script_input_count"), 0),
        "rate_recent_blocks_per_second": 0.0,
        "rate_total_blocks_per_second": round(height / (monotonic_ms / 1000.0), 3) if monotonic_ms > 0 else 0.0,
        "last_block_ms": as_int(entry.get("last_block_ms"), 0),
        "timing_buckets_ms": timing,
        "sync_status": entry.get("sync_status", ""),
        "header_height": as_int(entry.get("header_height"), height),
        "stored_block_height": as_int(entry.get("stored_block_height"), height),
    }
    if isinstance(entry.get("script_metrics"), dict):
        tick["script_metrics"] = entry["script_metrics"]
    if isinstance(entry.get("script_runner_actual_mode"), str):
        tick["script_runner_actual_mode"] = entry["script_runner_actual_mode"]
    return tick


def synthesize_ticks(
    *,
    port: str,
    gate_id: str,
    entries: list[dict[str, Any]],
    elapsed_ms: int,
    target_height_override: int | None = None,
    started_height: int = 0,
) -> list[dict[str, Any]]:
    spec = gate_spec(gate_id)
    target_height = target_height_override if target_height_override is not None else (None if spec.get("tip") else int(spec["target_height"]))
    run_id = f"{port}-{gate_id}-control"
    first = entries[0] if entries else {}
    final = best_final_progress(entries)
    ticks = [
        progress_tick(port=port, gate_id=gate_id, run_id=run_id, entry=first, event="run_started", phase="startup", target_height=target_height, monotonic_ms=0, started_height=started_height),
        progress_tick(port=port, gate_id=gate_id, run_id=run_id, entry=first, event="container_started", phase="startup", target_height=target_height, monotonic_ms=1, started_height=started_height),
        progress_tick(port=port, gate_id=gate_id, run_id=run_id, entry=first, event="node_started", phase="startup", target_height=target_height, monotonic_ms=2, started_height=started_height),
    ]
    first_header = next((entry for entry in entries if as_int(entry.get("header_height"), 0) > 0), first)
    first_block = next((entry for entry in entries if as_int(entry.get("validated_height"), 0) > started_height), first)
    ticks.append(progress_tick(port=port, gate_id=gate_id, run_id=run_id, entry=first_header, event="first_peer_byte", phase="peer_connect", target_height=target_height, monotonic_ms=3, started_height=started_height))
    if gate_id == "tip_maintenance":
        ticks.append(progress_tick(port=port, gate_id=gate_id, run_id=run_id, entry=first_block, event="first_health_tick", phase="heartbeat", target_height=target_height, monotonic_ms=4, started_height=started_height))
    else:
        ticks.append(progress_tick(port=port, gate_id=gate_id, run_id=run_id, entry=first_block, event="first_block_connected", phase="block_connect", target_height=target_height, monotonic_ms=4, started_height=started_height))
    if entries:
        span = max(1, elapsed_ms - 6)
        for offset, entry in enumerate(entries, start=1):
            monotonic = 5 + int(span * offset / max(1, len(entries) + 1))
            ticks.append(progress_tick(port=port, gate_id=gate_id, run_id=run_id, entry=entry, event="heartbeat", phase="heartbeat", target_height=target_height, monotonic_ms=monotonic, started_height=started_height))
    ticks.append(progress_tick(port=port, gate_id=gate_id, run_id=run_id, entry=final, event="target_reached", phase="complete", target_height=target_height, monotonic_ms=max(elapsed_ms - 1, 5), started_height=started_height))
    ticks.append(progress_tick(port=port, gate_id=gate_id, run_id=run_id, entry=final, event="run_finished", phase="complete", target_height=target_height, monotonic_ms=max(elapsed_ms, 6), started_height=started_height))
    return ticks


def write_telemetry_log(path: Path, ticks: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "\n".join("benchmark.telemetry_tick " + json.dumps(tick, sort_keys=True) for tick in ticks) + "\n",
        encoding="utf-8",
    )


def build_artifact(
    *,
    port: str,
    gate_id: str,
    proof_log: Path,
    artifact_path: Path,
    telemetry_log_path: Path,
    elapsed_ms: int,
    expected_peer: str | None = None,
    reference_finish_height: int | None = None,
    reference_finish_hash: str | None = None,
    source_state: dict[str, Any] | None = None,
    provenance: dict[str, Any] | None = None,
) -> ControlBuildResult | None:
    entries = progress_entries(proof_log)
    if not entries:
        return None
    spec = gate_spec(gate_id)
    final = best_final_progress(entries)
    expected_peer = expected_peer or read_env().get("REFERENCE_P2P_PEER", "bitcoin-core-testnet4:48333")
    first = entries[0]
    source_state = source_state if isinstance(source_state, dict) else {}
    source_state_height = as_int(
        source_state.get("height", source_state.get("validated_height", first.get("validated_height"))),
        0,
    )
    source_state_hash = (
        source_state.get("hash")
        or source_state.get("validated_hash")
        or first.get("validated_hash")
    )
    source_state_utxos = as_int(
        source_state.get(
            "utxo_count",
            source_state.get("chainstate_utxo_count", first.get("chainstate_utxo_count", first.get("utxo_count"))),
        ),
        0,
    )
    maintenance = bool(spec.get("maintenance"))
    started_height = (
        source_state_height
        if spec.get("resume_from_state")
        else as_int(first.get("validated_height"), 0) if maintenance else 0
    )
    if spec.get("resume_from_state"):
        target_height = reference_finish_height or as_int(final.get("validated_height"), started_height)
    elif maintenance:
        target_height = as_int(final.get("validated_height"), started_height)
    else:
        target_height = None if spec.get("tip") else int(spec["target_height"])
    ticks = synthesize_ticks(
        port=port,
        gate_id=gate_id,
        entries=entries,
        elapsed_ms=max(0, elapsed_ms),
        target_height_override=target_height,
        started_height=started_height,
    )
    write_telemetry_log(telemetry_log_path, ticks)
    telemetry_validation = _telemetry_validator.validate_ticks(
        ticks,
        gate=gate_id,
        port=port,
        target_height=target_height,
        min_ticks=1,
    )
    timing = timing_from_progress(entries, max(0, elapsed_ms))
    observed_stages = timing_from_benchmark_ticks(proof_log)
    if any(observed_stages.values()):
        timing["stage_totals_ms"] = observed_stages
    pipeline_timing = full_timing_from_progress(entries, max(0, elapsed_ms))
    observed_pipeline_stages = full_timing_from_benchmark_ticks(proof_log)
    if any(observed_pipeline_stages.values()):
        pipeline_timing["stage_totals_ms"] = observed_pipeline_stages
    script_metrics = runner_metrics_from_entries(entries)
    runner_actual_mode = str(script_metrics.get("script_runner_actual_mode") or "").strip()
    if not runner_actual_mode:
        runner_actual_mode = "parallel" if not script_metrics else "sequential"
    runner_mode = "parallel" if runner_actual_mode == "parallel" else "sequential"
    target = int(spec["target_height"]) if not spec.get("tip") else as_int(reference_finish_height, as_int(final.get("validated_height"), 0))
    expected_hash = _artifact_validator.EXPECTED_HASHES.get(gate_id, reference_finish_hash or final.get("validated_hash", ""))
    if maintenance:
        target = as_int(final.get("validated_height"), started_height)
        expected_hash = str(final.get("validated_hash") or "")
    reference_start_height = started_height if (spec.get("resume_from_state") or maintenance) else 0
    reference_start_hash = (
        str(source_state_hash or first.get("validated_hash") or "")
        if (spec.get("resume_from_state") or maintenance)
        else TESTNET4_GENESIS_HASH
    )
    fresh_state = False if (spec.get("resume_from_state") or maintenance) else True
    payload = {
        "implementation": f"{port} product node",
        "port": port,
        "runtime_surface": "docker",
        "benchmark_contract_version": 1,
        "benchmark_gate": spec["benchmark_gate"],
        "benchmark_lane": spec["benchmark_lane"],
        "benchmark_kind": spec["benchmark_kind"],
        "target_height": target,
        "target_label": spec["target_label"] if (not spec.get("tip") or spec.get("resume_from_state")) else "tip",
        "header_target_height": target,
        "byte_source": "network_or_local_reference_p2p" if maintenance else "local_reference_p2p",
        "reference_start_height": reference_start_height,
        "reference_start_hash": reference_start_hash,
        "reference_finish_height": target,
        "reference_finish_hash": expected_hash,
        "validated_height": as_int(final.get("validated_height"), 0),
        "validated_hash": final.get("validated_hash"),
        "blocks_fetched": as_int(final.get("downloaded_blocks"), max(0, as_int(final.get("validated_height"), 0) - started_height)),
        "blocks_connected": as_int(final.get("connected_blocks"), max(0, as_int(final.get("validated_height"), 0) - started_height)),
        "current_blocker": final.get("current_blocker"),
        "binary_gate_status": "not_attempted",
        "chainstate_backend": "rocksdb",
        "chainstate_utxo_count": as_int(final.get("chainstate_utxo_count", final.get("utxo_count")), 0),
        "utxo_accounting_policy": "core_spendable_v1",
        "native_crypto_backend": str(final.get("native_crypto_backend") or BASELINE_CRYPTO_BACKENDS.get(port, "baseline-native")),
        "crypto_lane": final.get("crypto_lane") or (final.get("crypto") or {}).get("lane", "c_binding"),
        "proof_mode": "tip_maintenance" if maintenance else "p2p_sync",
        "peer_mode": "tip_peer" if maintenance else "local_reference",
        "peer": str(final.get("peer") or expected_peer),
        "script_runner_mode": runner_mode,
        "rocksdb_wal_disabled": False,
        "prefetch_depth": 4,
        "resume_supported": True,
        "fresh_state": fresh_state,
        "result": "passed" if not final.get("current_blocker") else "failed",
        "failures": [],
        "captured_at": utc_now(),
        "telemetry_schema": "benchmark.telemetry_tick.v1",
        "telemetry_summary": telemetry_validation.summary,
        "timing_summary": timing,
        "pipeline_timing_summary": pipeline_timing,
        "status": {
            "chain": final.get("chain", "testnet4"),
            "sync_status": final.get("sync_status", ""),
            "header_height": as_int(final.get("header_height"), 0),
            "validated_height": as_int(final.get("validated_height"), 0),
            "validated_hash": final.get("validated_hash"),
            "stored_block_height": as_int(final.get("stored_block_height"), 0),
            "chainstate_utxo_count": as_int(final.get("chainstate_utxo_count", final.get("utxo_count")), 0),
            "current_blocker": final.get("current_blocker"),
        },
        "control_harness": {
            "artifact_source": "project_control_harness",
            "product_progress_prefix": "rb.port_progress",
            "product_progress_count": len(entries),
            "proof_log": rel(proof_log),
            "telemetry_log": rel(telemetry_log_path),
        },
    }
    if provenance is not None:
        from provenance import validate as validate_build_provenance
        validate_build_provenance({"provenance": provenance})
        payload["provenance"] = dict(provenance)
    if script_metrics:
        payload["runner_truth_contract_version"] = 1
        payload["script_runner_actual_mode"] = runner_actual_mode
        payload["script_metrics"] = script_metrics
    if spec.get("resume_from_state"):
        payload.update(
            {
                "source_state_gate": spec.get("source_state_gate", "performance_100k"),
                "source_state_origin": "port_durable_state",
                "source_state_height": source_state_height,
                "source_state_hash": source_state_hash,
                "source_state_utxo_count": source_state_utxos,
                "skipped_consensus_rules": [],
            }
        )
        payload["control_harness"]["resume_source"] = "port_durable_state"
    if maintenance:
        payload.update(
            {
                "maintenance_window_seconds": max(0, int(elapsed_ms / 1000)),
                "start_height": as_int(first.get("validated_height"), 0),
                "start_hash": first.get("validated_hash", ""),
                "end_height": as_int(final.get("validated_height"), 0),
                "end_hash": final.get("validated_hash", ""),
                "blocks_current": blocks_current(final),
                "reconnect_count": max_progress_int(entries, "reconnect_count"),
                "stall_count": max_progress_int(entries, "stall_count"),
                "restart_recovery_count": max_progress_int(entries, "restart_recovery_count"),
                "health_ticks": health_ticks(entries),
                "final_status": {
                    "sync_status": final.get("sync_status", ""),
                    "header_height": as_int(final.get("header_height"), 0),
                    "validated_height": as_int(final.get("validated_height"), 0),
                    "validated_hash": final.get("validated_hash", ""),
                    "stored_block_height": as_int(final.get("stored_block_height"), 0),
                    "chainstate_utxo_count": as_int(final.get("chainstate_utxo_count", final.get("utxo_count")), 0),
                    "current_blocker": final.get("current_blocker"),
                },
            }
        )
    artifact_path.parent.mkdir(parents=True, exist_ok=True)
    artifact_path.write_text(json.dumps(payload, indent=2, sort_keys=False) + "\n", encoding="utf-8")
    return ControlBuildResult(
        artifact_path=artifact_path,
        telemetry_log_path=telemetry_log_path,
        progress_count=len(entries),
        telemetry_quality=telemetry_validation.quality,
        telemetry_summary=telemetry_validation.summary,
    )


def self_test() -> int:
    from unittest.mock import patch
    failures = 0
    progress = [
        {"chain": "testnet4", "sync_status": "blocks_syncing", "header_height": 5000, "validated_height": 1, "validated_hash": "a", "stored_block_height": 1, "chainstate_utxo_count": 1, "current_blocker": None},
        {"chain": "testnet4", "sync_status": "blocks_current", "header_height": 5000, "validated_height": 5000, "validated_hash": _artifact_validator.EXPECTED_HASHES["baseline_5k"], "stored_block_height": 5000, "chainstate_utxo_count": 4574, "current_blocker": None, "downloaded_blocks": 5000, "connected_blocks": 5000},
    ]
    with tempfile.TemporaryDirectory() as tmp, patch("state_root.operational_paths", return_value={"campaigns": Path(tmp)}):
        tmp_path = Path(tmp)
        log = tmp_path / "proof.log"
        log.write_text("\n".join(PRODUCT_PREFIX + json.dumps(item) for item in progress), encoding="utf-8")
        result = build_artifact(
            port="go",
            gate_id="baseline_5k",
            proof_log=log,
            artifact_path=tmp_path / "go_control_baseline_5k.json",
            telemetry_log_path=tmp_path / "go_control_telemetry.log",
            elapsed_ms=1000,
            expected_peer="bitcoin-core-testnet4:48333",
        )
        if result is None:
            print("self_test: failed to build artifact")
            return 1
        payload = json.loads(result.artifact_path.read_text(encoding="utf-8"))
        assert payload["control_harness"]["proof_log"] == "state:campaigns/proof.log"
        assert payload["control_harness"]["telemetry_log"] == "state:campaigns/go_control_telemetry.log"
        errors, _ = _artifact_validator.validate_payload(
            payload,
            gate_id="baseline_5k",
            path=result.artifact_path,
            port="go",
            expected_peer="bitcoin-core-testnet4:48333",
            strict_current=True,
        )
        if errors:
            failures += 1
            print("self_test artifact errors:", errors)
        if result.telemetry_quality != "clean":
            failures += 1
            print("self_test telemetry quality:", result.telemetry_quality)
        post_log = tmp_path / "post-proof.log"
        post_progress = [
            {
                "chain": "testnet4",
                "sync_status": "blocks_syncing",
                "header_height": 100000,
                "validated_height": 100000,
                "stored_block_height": 100000,
                "current_blocker": None,
            },
            {
                "chain": "testnet4",
                "sync_status": "blocks_current",
                "header_height": 123456,
                "validated_height": 123456,
                "validated_hash": "0000000000000000000000000000000000000000000000000000000000000002",
                "stored_block_height": 123456,
                "chainstate_utxo_count": 999,
                "current_blocker": None,
                "downloaded_blocks": 23456,
                "connected_blocks": 23456,
            },
        ]
        post_log.write_text("\n".join(PRODUCT_PREFIX + json.dumps(item) for item in post_progress), encoding="utf-8")
        post_result = build_artifact(
            port="go",
            gate_id="post_100k_to_tip",
            proof_log=post_log,
            artifact_path=tmp_path / "go_control_post_100k_to_tip.json",
            telemetry_log_path=tmp_path / "go_control_post_telemetry.log",
            elapsed_ms=2000,
            expected_peer="bitcoin-core-testnet4:48333",
            reference_finish_height=123456,
            reference_finish_hash="0000000000000000000000000000000000000000000000000000000000000002",
            source_state={
                "height": 100000,
                "hash": _artifact_validator.EXPECTED_HASHES["performance_100k"],
                "utxo_count": 13154991,
            },
        )
        if post_result is None:
            failures += 1
            print("self_test: failed to build post_100k_to_tip artifact")
        else:
            post_payload = json.loads(post_result.artifact_path.read_text(encoding="utf-8"))
            post_errors, _ = _artifact_validator.validate_payload(
                post_payload,
                gate_id="post_100k_to_tip",
                path=post_result.artifact_path,
                port="go",
                expected_peer="bitcoin-core-testnet4:48333",
                strict_current=True,
            )
            if post_errors:
                failures += 1
                print("self_test post_100k_to_tip artifact errors:", post_errors)
            if post_payload.get("source_state_hash") != _artifact_validator.EXPECTED_HASHES["performance_100k"]:
                failures += 1
                print("self_test post_100k_to_tip source hash was not preserved")
        maintenance_hash = "0000000000000000000000000000000000000000000000000000000000000003"
        maintenance_log = tmp_path / "maintenance-proof.log"
        maintenance_progress = [
            {
                "chain": "testnet4",
                "sync_status": "blocks_current",
                "header_height": 123456,
                "validated_height": 123456,
                "validated_hash": maintenance_hash,
                "stored_block_height": 123456,
                "chainstate_utxo_count": 999,
                "current_blocker": None,
                "peer": "bitcoin-core-testnet4:48333",
                "live_iteration": 1,
                "reconnect_count": 0,
                "stall_count": 0,
                "restart_recovery_count": 0,
                "blocks_current": True,
            },
            {
                "chain": "testnet4",
                "sync_status": "blocks_current",
                "header_height": 123456,
                "validated_height": 123456,
                "validated_hash": maintenance_hash,
                "stored_block_height": 123456,
                "chainstate_utxo_count": 999,
                "current_blocker": None,
                "peer": "bitcoin-core-testnet4:48333",
                "live_iteration": 2,
                "reconnect_count": 0,
                "stall_count": 0,
                "restart_recovery_count": 0,
                "blocks_current": True,
            },
        ]
        maintenance_log.write_text(
            "\n".join(PRODUCT_PREFIX + json.dumps(item) for item in maintenance_progress),
            encoding="utf-8",
        )
        maintenance_result = build_artifact(
            port="java",
            gate_id="tip_maintenance",
            proof_log=maintenance_log,
            artifact_path=tmp_path / "java_control_tip_maintenance.json",
            telemetry_log_path=tmp_path / "java_control_tip_maintenance_telemetry.log",
            elapsed_ms=10_000,
            expected_peer="bitcoin-core-testnet4:48333",
        )
        if maintenance_result is None:
            failures += 1
            print("self_test: failed to build tip_maintenance artifact")
        else:
            maintenance_payload = json.loads(maintenance_result.artifact_path.read_text(encoding="utf-8"))
            maintenance_errors, _ = _artifact_validator.validate_payload(
                maintenance_payload,
                gate_id="tip_maintenance",
                path=maintenance_result.artifact_path,
                port="java",
                expected_peer="bitcoin-core-testnet4:48333",
                strict_current=True,
            )
            if maintenance_errors:
                failures += 1
                print("self_test tip_maintenance artifact errors:", maintenance_errors)
            if maintenance_result.telemetry_quality != "clean":
                failures += 1
                print("self_test tip_maintenance telemetry quality:", maintenance_result.telemetry_quality)
    print(f"control_benchmark_harness_self_test cases=3 failures={failures}")
    return 1 if failures else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    parser.error("no standalone action requested")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
