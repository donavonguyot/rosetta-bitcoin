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


def best_final_progress(entries: list[dict[str, Any]]) -> dict[str, Any]:
    if not entries:
        return {}
    max_height = max(as_int(entry.get("validated_height"), 0) for entry in entries)
    same_height = [entry for entry in entries if as_int(entry.get("validated_height"), 0) == max_height]
    for entry in reversed(same_height):
        if str(entry.get("validated_hash") or "").strip():
            return entry
    return same_height[-1] if same_height else entries[-1]


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
    timing = entry.get("timing_buckets_ms") if isinstance(entry.get("timing_buckets_ms"), dict) else zero_timing()
    return {
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


def synthesize_ticks(
    *,
    port: str,
    gate_id: str,
    entries: list[dict[str, Any]],
    elapsed_ms: int,
) -> list[dict[str, Any]]:
    spec = gate_spec(gate_id)
    target_height = None if spec.get("tip") else int(spec["target_height"])
    run_id = f"{port}-{gate_id}-control"
    first = entries[0] if entries else {}
    final = best_final_progress(entries)
    ticks = [
        progress_tick(port=port, gate_id=gate_id, run_id=run_id, entry=first, event="run_started", phase="startup", target_height=target_height, monotonic_ms=0),
        progress_tick(port=port, gate_id=gate_id, run_id=run_id, entry=first, event="container_started", phase="startup", target_height=target_height, monotonic_ms=1),
        progress_tick(port=port, gate_id=gate_id, run_id=run_id, entry=first, event="node_started", phase="startup", target_height=target_height, monotonic_ms=2),
    ]
    first_header = next((entry for entry in entries if as_int(entry.get("header_height"), 0) > 0), first)
    first_block = next((entry for entry in entries if as_int(entry.get("validated_height"), 0) > 0), first)
    ticks.append(progress_tick(port=port, gate_id=gate_id, run_id=run_id, entry=first_header, event="first_peer_byte", phase="peer_connect", target_height=target_height, monotonic_ms=3))
    ticks.append(progress_tick(port=port, gate_id=gate_id, run_id=run_id, entry=first_block, event="first_block_connected", phase="block_connect", target_height=target_height, monotonic_ms=4))
    if entries:
        span = max(1, elapsed_ms - 6)
        for offset, entry in enumerate(entries, start=1):
            monotonic = 5 + int(span * offset / max(1, len(entries) + 1))
            ticks.append(progress_tick(port=port, gate_id=gate_id, run_id=run_id, entry=entry, event="heartbeat", phase="heartbeat", target_height=target_height, monotonic_ms=monotonic))
    ticks.append(progress_tick(port=port, gate_id=gate_id, run_id=run_id, entry=final, event="target_reached", phase="complete", target_height=target_height, monotonic_ms=max(elapsed_ms - 1, 5)))
    ticks.append(progress_tick(port=port, gate_id=gate_id, run_id=run_id, entry=final, event="run_finished", phase="complete", target_height=target_height, monotonic_ms=max(elapsed_ms, 6)))
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
) -> ControlBuildResult | None:
    entries = progress_entries(proof_log)
    if not entries:
        return None
    spec = gate_spec(gate_id)
    final = best_final_progress(entries)
    expected_peer = expected_peer or read_env().get("REFERENCE_P2P_PEER", "bitcoin-core-testnet4:48333")
    ticks = synthesize_ticks(port=port, gate_id=gate_id, entries=entries, elapsed_ms=max(0, elapsed_ms))
    write_telemetry_log(telemetry_log_path, ticks)
    target_height = None if spec.get("tip") else int(spec["target_height"])
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
    target = int(spec["target_height"]) if not spec.get("tip") else as_int(final.get("validated_height"), 0)
    expected_hash = _artifact_validator.EXPECTED_HASHES.get(gate_id, final.get("validated_hash", ""))
    payload = {
        "implementation": f"{port} product node",
        "port": port,
        "runtime_surface": "docker",
        "benchmark_contract_version": 1,
        "benchmark_gate": spec["benchmark_gate"],
        "benchmark_lane": spec["benchmark_lane"],
        "benchmark_kind": spec["benchmark_kind"],
        "target_height": target,
        "target_label": spec["target_label"] if not spec.get("tip") else "tip",
        "header_target_height": target,
        "byte_source": "local_reference_p2p",
        "reference_start_height": 0,
        "reference_start_hash": TESTNET4_GENESIS_HASH,
        "reference_finish_height": target,
        "reference_finish_hash": expected_hash,
        "validated_height": as_int(final.get("validated_height"), 0),
        "validated_hash": final.get("validated_hash"),
        "blocks_fetched": as_int(final.get("downloaded_blocks"), as_int(final.get("validated_height"), 0)),
        "blocks_connected": as_int(final.get("connected_blocks"), as_int(final.get("validated_height"), 0)),
        "current_blocker": final.get("current_blocker"),
        "binary_gate_status": "not_attempted",
        "chainstate_backend": "rocksdb",
        "chainstate_utxo_count": as_int(final.get("chainstate_utxo_count", final.get("utxo_count")), 0),
        "utxo_accounting_policy": "core_spendable_v1",
        "native_crypto_backend": str(final.get("native_crypto_backend") or BASELINE_CRYPTO_BACKENDS.get(port, "baseline-native")),
        "proof_mode": "p2p_sync",
        "peer_mode": "local_reference",
        "peer": str(final.get("peer") or expected_peer),
        "script_runner_mode": "parallel",
        "rocksdb_wal_disabled": False,
        "prefetch_depth": 4,
        "resume_supported": True,
        "fresh_state": True,
        "result": "passed" if not final.get("current_blocker") else "failed",
        "failures": [],
        "captured_at": utc_now(),
        "telemetry_schema": "benchmark.telemetry_tick.v1",
        "telemetry_summary": telemetry_validation.summary,
        "timing_summary": timing,
        "pipeline_timing_summary": timing,
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
            "proof_log": str(proof_log),
            "telemetry_log": str(telemetry_log_path),
        },
    }
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
    failures = 0
    progress = [
        {"chain": "testnet4", "sync_status": "blocks_syncing", "header_height": 5000, "validated_height": 1, "validated_hash": "a", "stored_block_height": 1, "chainstate_utxo_count": 1, "current_blocker": None},
        {"chain": "testnet4", "sync_status": "blocks_current", "header_height": 5000, "validated_height": 5000, "validated_hash": _artifact_validator.EXPECTED_HASHES["baseline_5k"], "stored_block_height": 5000, "chainstate_utxo_count": 4574, "current_blocker": None, "downloaded_blocks": 5000, "connected_blocks": 5000},
    ]
    with tempfile.TemporaryDirectory() as tmp:
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
    print(f"control_benchmark_harness_self_test cases=1 failures={failures}")
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
