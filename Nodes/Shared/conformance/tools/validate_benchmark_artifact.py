#!/usr/bin/env python3
"""Validate RB benchmark proof artifacts.

Project import remains compatibility-friendly for historical artifacts. This
tool is the strict current-evidence gate used by proof commands and campaign
acceptance.
"""

from __future__ import annotations

import argparse
import json
import tempfile
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[4]
REFERENCE_TOPOLOGY = ROOT / "Nodes/Shared/docker/reference_topology.env"

EXPECTED_HASHES = {
    "baseline_5k": "000000000e3cb5b92e9765ed9c80c6b06f3d0a186478b330dd5e6b274acf03e2",
    "shakedown_50k": "00000000e2c8c94ba126169a88997233f07a9769e2b009fb10cad0e893eff2cb",
    "performance_100k": "0000000000524911745ab6eee9348bca9843c2c2b1b27eada246e3dc2f80b6b1",
}
PERFORMANCE_100K_START = {
    "height": 100000,
    "hash": EXPECTED_HASHES["performance_100k"],
    "utxo_count": 13154991,
}

GATES: dict[str, dict[str, Any]] = {
    "baseline_5k": {
        "target_height": 5000,
        "target_label": "5k",
        "benchmark_gate": "baseline_5k",
        "benchmark_kind": "baseline_5k_p2p",
        "benchmark_lane": "baseline_5k_p2p",
        "utxo_count": 4574,
        "long_run": False,
        "tip": False,
    },
    "shakedown_50k": {
        "target_height": 50000,
        "target_label": "50k",
        "benchmark_gate": "shakedown_50k",
        "benchmark_kind": "shakedown_50k_p2p",
        "benchmark_lane": "shakedown_50k_p2p",
        "utxo_count": 568855,
        "long_run": True,
        "tip": False,
    },
    "performance_100k": {
        "target_height": 100000,
        "target_label": "100k",
        "benchmark_gate": "performance_100k",
        "benchmark_kind": "performance_100k_p2p",
        "benchmark_lane": "performance_100k_p2p",
        "utxo_count": 13154991,
        "long_run": True,
        "tip": False,
    },
    "post_100k_to_tip": {
        "target_height": -1,
        "target_label": "100k to tip",
        "benchmark_gate": "post_100k_to_tip",
        "benchmark_kind": "post_100k_to_tip_p2p",
        "benchmark_lane": "post_100k_to_tip_p2p",
        "utxo_count": -1,
        "long_run": True,
        "tip": True,
        "resume_from_state": True,
        "source_state_gate": "performance_100k",
    },
    "tip_once": {
        "target_height": -1,
        "target_label": "tip once",
        "benchmark_gate": "tip_once",
        "benchmark_kind": "tip_once_p2p",
        "benchmark_lane": "tip_once_p2p",
        "utxo_count": -1,
        "long_run": True,
        "tip": True,
    },
    "tip_maintenance": {
        "target_height": -1,
        "target_label": "tip maintenance",
        "benchmark_gate": "tip_maintenance",
        "benchmark_kind": "tip_maintenance_p2p",
        "benchmark_lane": "tip_maintenance_p2p",
        "utxo_count": -1,
        "long_run": True,
        "tip": True,
        "maintenance": True,
    },
}

LABEL_ALIASES = {
    "supporting_5k": "baseline_5k",
    "supporting_5k_p2p": "baseline_5k_p2p",
    "supporting_50k": "shakedown_50k",
    "supporting_50k_p2p": "shakedown_50k_p2p",
    "primary_100k": "performance_100k",
    "primary_100k_p2p": "performance_100k_p2p",
}

REQUIRED_BOUNDED_FIELDS = (
    "implementation",
    "runtime_surface",
    "benchmark_contract_version",
    "benchmark_gate",
    "benchmark_lane",
    "benchmark_kind",
    "target_height",
    "target_label",
    "header_target_height",
    "byte_source",
    "reference_start_height",
    "reference_start_hash",
    "reference_finish_height",
    "reference_finish_hash",
    "validated_height",
    "validated_hash",
    "blocks_fetched",
    "blocks_connected",
    "current_blocker",
    "binary_gate_status",
    "chainstate_backend",
    "chainstate_utxo_count",
    "utxo_accounting_policy",
    "native_crypto_backend",
    "proof_mode",
    "peer_mode",
    "peer",
    "script_runner_mode",
    "rocksdb_wal_disabled",
    "prefetch_depth",
    "resume_supported",
    "fresh_state",
    "result",
    "failures",
    "captured_at",
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

REQUIRED_TIP_FIELDS = (
    "implementation",
    "runtime_surface",
    "benchmark_contract_version",
    "benchmark_gate",
    "benchmark_lane",
    "benchmark_kind",
    "byte_source",
    "reference_start_height",
    "reference_start_hash",
    "reference_finish_height",
    "reference_finish_hash",
    "validated_height",
    "validated_hash",
    "current_blocker",
    "binary_gate_status",
    "chainstate_backend",
    "utxo_accounting_policy",
    "native_crypto_backend",
    "proof_mode",
    "peer_mode",
    "peer",
    "script_runner_mode",
    "rocksdb_wal_disabled",
    "prefetch_depth",
    "resume_supported",
    "result",
    "failures",
    "captured_at",
    "telemetry_schema",
    "telemetry_summary",
)

REQUIRED_POST_100K_TO_TIP_FIELDS = (
    "source_state_gate",
    "source_state_origin",
    "source_state_height",
    "source_state_hash",
    "source_state_utxo_count",
    "fresh_state",
)

REQUIRED_MAINTENANCE_FIELDS = (
    "maintenance_window_seconds",
    "start_height",
    "start_hash",
    "end_height",
    "end_hash",
    "blocks_current",
    "reconnect_count",
    "stall_count",
    "restart_recovery_count",
    "health_ticks",
    "final_status",
)


def read_json(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError("artifact root must be a JSON object")
    return payload


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


def canonical_label(value: Any) -> str:
    text = "" if value is None else str(value)
    return LABEL_ALIASES.get(text, text)


def as_bool(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, int):
        return value != 0
    if isinstance(value, str):
        return value.strip().lower() in {"1", "true", "yes", "on"}
    return False


def falseish(value: Any) -> bool:
    if value is None:
        return True
    if isinstance(value, bool):
        return not value
    if isinstance(value, int):
        return value == 0
    if isinstance(value, str):
        return value.strip().lower() in {"", "0", "false", "no", "off", "null"}
    return False


def as_int(value: Any, default: int | None = None) -> int | None:
    try:
        if value is None or value == "":
            return default
        return int(value)
    except (TypeError, ValueError):
        return default


def is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def canonical_timing(payload: dict[str, Any]) -> dict[str, Any] | None:
    summary = payload.get("timing_summary")
    if not isinstance(summary, dict):
        return None
    stages = summary.get("stage_totals_ms")
    if not isinstance(stages, dict):
        return None
    return summary


def compatible_timing(payload: dict[str, Any]) -> dict[str, Any] | None:
    direct = canonical_timing(payload)
    if direct is not None:
        return direct
    for key in ("pipeline_timing_summary", "canonical_timing_summary", "connect_summary"):
        candidate = payload.get(key)
        if key == "connect_summary" and isinstance(candidate, dict):
            candidate = candidate.get("timing_summary")
        if isinstance(candidate, dict) and isinstance(candidate.get("stage_totals_ms"), dict):
            return candidate
    return None


def gate_for_payload(payload: dict[str, Any]) -> str:
    gate = canonical_label(payload.get("benchmark_gate"))
    if gate in GATES:
        return gate
    kind = canonical_label(payload.get("benchmark_kind"))
    lane = canonical_label(payload.get("benchmark_lane"))
    for gate_id, spec in GATES.items():
        if kind == spec["benchmark_kind"] or lane == spec["benchmark_lane"]:
            return gate_id
    target = as_int(payload.get("target_height"), None)
    if target == 5000:
        return "baseline_5k"
    if target == 50000:
        return "shakedown_50k"
    if target == 100000:
        return "performance_100k"
    return ""


def port_matches(path: Path, payload: dict[str, Any], port: str | None) -> bool:
    if not port:
        return True
    lowered = path.name.lower()
    if lowered.startswith(f"{port}_") or lowered.startswith(f"{port}-"):
        return True
    marker = str(payload.get("port") or payload.get("implementation") or payload.get("node") or "").lower()
    return port.lower() in marker


def has_nonempty(value: Any) -> bool:
    if value is None:
        return False
    if isinstance(value, str):
        return bool(value.strip())
    if isinstance(value, (list, dict)):
        return bool(value)
    return True


def validate_payload(
    payload: dict[str, Any],
    *,
    gate_id: str,
    path: Path = Path("<artifact>"),
    port: str | None = None,
    expected_peer: str | None = None,
    strict_current: bool = True,
) -> tuple[list[str], list[str]]:
    spec = GATES[gate_id]
    errors: list[str] = []
    warnings: list[str] = []
    expected_peer = expected_peer or read_env().get("REFERENCE_P2P_PEER", "bitcoin-core-testnet4:48333")

    if not port_matches(path, payload, port):
        errors.append(f"artifact does not look port-owned by {port}")

    required = REQUIRED_TIP_FIELDS if spec.get("tip") else REQUIRED_BOUNDED_FIELDS
    for field in required:
        if field not in payload:
            errors.append(f"missing required field {field}")

    if spec.get("resume_from_state"):
        for field in REQUIRED_POST_100K_TO_TIP_FIELDS:
            if field not in payload:
                errors.append(f"missing post-100k-to-tip field {field}")

    if spec.get("maintenance"):
        for field in REQUIRED_MAINTENANCE_FIELDS:
            if field not in payload:
                errors.append(f"missing maintenance field {field}")

    if not str(payload.get("captured_at") or "").strip():
        errors.append("captured_at must be nonblank")

    label = (lambda value: value) if strict_current else canonical_label
    checks = {
        "result": "passed",
        "runtime_surface": "docker",
        "benchmark_gate": spec["benchmark_gate"],
        "benchmark_lane": spec["benchmark_lane"],
        "benchmark_kind": spec["benchmark_kind"],
        "byte_source": "local_reference_p2p" if not spec.get("maintenance") else payload.get("byte_source"),
        "proof_mode": "p2p_sync" if not spec.get("maintenance") else payload.get("proof_mode"),
        "peer_mode": "local_reference" if not spec.get("maintenance") else payload.get("peer_mode"),
        "binary_gate_status": "not_attempted",
        "chainstate_backend": "rocksdb",
        "utxo_accounting_policy": "core_spendable_v1",
        "script_runner_mode": "parallel",
        "prefetch_depth": 4,
    }
    if not spec.get("maintenance"):
        checks["peer"] = expected_peer
    for key, expected in checks.items():
        actual = payload.get(key)
        actual_cmp = label(actual) if key in {"benchmark_gate", "benchmark_kind", "benchmark_lane"} else actual
        if actual_cmp != expected:
            errors.append(f"{key}={actual!r}; expected {expected!r}")

    if not spec.get("tip"):
        target = spec["target_height"]
        bounded_checks = {
            "target_height": target,
            "header_target_height": target,
            "validated_height": target,
            "validated_hash": EXPECTED_HASHES[gate_id],
            "reference_finish_height": target,
            "reference_finish_hash": EXPECTED_HASHES[gate_id],
            "chainstate_utxo_count": spec["utxo_count"],
        }
        for key, expected in bounded_checks.items():
            if payload.get(key) != expected:
                errors.append(f"{key}={payload.get(key)!r}; expected {expected!r}")
        if str(payload.get("target_label") or "") != spec["target_label"]:
            errors.append(f"target_label={payload.get('target_label')!r}; expected {spec['target_label']!r}")
    else:
        for key in ("reference_start_height", "reference_finish_height", "validated_height"):
            if as_int(payload.get(key), -1) is None or as_int(payload.get(key), -1) < 0:
                errors.append(f"{key} must be a nonnegative integer")
        for key in ("reference_start_hash", "reference_finish_hash", "validated_hash"):
            if not str(payload.get(key) or "").strip():
                errors.append(f"{key} must be nonblank")
        if payload.get("reference_finish_hash") != payload.get("validated_hash"):
            errors.append("reference_finish_hash must match validated_hash")
        if payload.get("reference_finish_height") != payload.get("validated_height"):
            errors.append("reference_finish_height must match validated_height")
        if spec.get("resume_from_state"):
            source_height = as_int(payload.get("source_state_height"), -1)
            source_utxos = as_int(payload.get("source_state_utxo_count"), -1)
            if payload.get("source_state_gate") != "performance_100k":
                errors.append("source_state_gate must be performance_100k")
            if payload.get("source_state_origin") != "port_durable_state":
                errors.append("source_state_origin must be port_durable_state")
            if source_height is None or source_height < PERFORMANCE_100K_START["height"]:
                errors.append(f"source_state_height={payload.get('source_state_height')!r}; expected >= {PERFORMANCE_100K_START['height']!r}")
            if not str(payload.get("source_state_hash") or "").strip():
                errors.append("source_state_hash must be nonblank")
            if source_utxos is None or source_utxos <= 0:
                errors.append("source_state_utxo_count must be positive")
            if source_height == PERFORMANCE_100K_START["height"]:
                if payload.get("source_state_hash") != PERFORMANCE_100K_START["hash"]:
                    errors.append("source_state_hash must match performance_100k hash when source_state_height=100000")
                if source_utxos != PERFORMANCE_100K_START["utxo_count"]:
                    errors.append(f"source_state_utxo_count={payload.get('source_state_utxo_count')!r}; expected {PERFORMANCE_100K_START['utxo_count']!r} when source_state_height=100000")
            if payload.get("reference_start_height") != payload.get("source_state_height"):
                errors.append("reference_start_height must match source_state_height")
            if payload.get("reference_start_hash") != payload.get("source_state_hash"):
                errors.append("reference_start_hash must match source_state_hash")
            if as_bool(payload.get("fresh_state")):
                errors.append("post_100k_to_tip must report fresh_state=false")
        if payload.get("skipped_consensus_rules") not in (None, [], {}, 0):
            errors.append("skipped_consensus_rules must be empty")
        if not isinstance(payload.get("telemetry_summary"), dict):
            errors.append("telemetry_summary must be an object")

    if has_nonempty(payload.get("current_blocker")):
        errors.append(f"current_blocker must be null/empty; got {payload.get('current_blocker')!r}")
    if payload.get("failures") not in (None, [], {}, 0):
        errors.append(f"failures must be empty; got {payload.get('failures')!r}")
    if not falseish(payload.get("rocksdb_wal_disabled")):
        errors.append(f"rocksdb_wal_disabled={payload.get('rocksdb_wal_disabled')!r}; expected false")
    if not as_bool(payload.get("resume_supported")):
        errors.append(f"resume_supported={payload.get('resume_supported')!r}; expected true")
    if not spec.get("maintenance") and not spec.get("resume_from_state") and not as_bool(payload.get("fresh_state")):
        errors.append(f"fresh_state={payload.get('fresh_state')!r}; expected true")
    if not str(payload.get("native_crypto_backend") or "").strip():
        errors.append("native_crypto_backend must be present")

    timing = canonical_timing(payload) if strict_current else compatible_timing(payload)
    if timing is None:
        errors.append("timing_summary.total_ms and timing_summary.stage_totals_ms are required")
    else:
        if not is_number(timing.get("total_ms")) or timing.get("total_ms") < 0:
            errors.append("timing_summary.total_ms must be a nonnegative number")
        stages = timing.get("stage_totals_ms", {})
        for bucket in REQUIRED_BUCKETS:
            value = stages.get(bucket)
            if not is_number(value) or value < 0:
                errors.append(f"timing_summary.stage_totals_ms.{bucket} must be a nonnegative number")

    if spec["long_run"]:
        if payload.get("telemetry_schema") != "benchmark.telemetry_tick.v1":
            errors.append("long-run artifact must report telemetry_schema=benchmark.telemetry_tick.v1")
        telemetry_summary = payload.get("telemetry_summary")
        if not isinstance(telemetry_summary, dict):
            errors.append("long-run artifact must include telemetry_summary object")
        else:
            quality = telemetry_summary.get("telemetry_quality") or telemetry_summary.get("quality")
            if quality != "clean":
                errors.append(f"telemetry_summary.telemetry_quality={quality!r}; expected 'clean'")
            if as_int(telemetry_summary.get("tick_count"), 0) <= 0:
                errors.append("telemetry_summary.tick_count must be positive")
            if as_int(telemetry_summary.get("heartbeat_max_gap_ms"), -1) < 0:
                errors.append("telemetry_summary.heartbeat_max_gap_ms must be nonnegative")
            markers = telemetry_summary.get("lifecycle_markers")
            if not isinstance(markers, dict) or not markers:
                errors.append("telemetry_summary.lifecycle_markers must be a nonempty object")
        if spec.get("maintenance"):
            ticks = payload.get("health_ticks")
            if not isinstance(ticks, list) or not ticks:
                errors.append("tip maintenance must include nonempty health_ticks")
            if payload.get("blocks_current") is not True:
                errors.append("tip maintenance must report blocks_current=true")
        else:
            if "slow_blocks" not in json.dumps(payload):
                errors.append("long-run artifact must include slow_blocks summary")

    return errors, warnings


def artifact_quality(payload: dict[str, Any], path: Path = Path("<artifact>")) -> str:
    gate_id = gate_for_payload(payload)
    if gate_id not in GATES:
        return "historical"
    strict_errors, _ = validate_payload(payload, gate_id=gate_id, path=path, strict_current=True)
    if not strict_errors:
        return "canonical"
    compatible_errors, _ = validate_payload(payload, gate_id=gate_id, path=path, strict_current=False)
    if not compatible_errors:
        return "normalized"
    return "incomplete"


def validate_file(path: Path, gate_id: str, port: str | None, strict_current: bool) -> int:
    try:
        payload = read_json(path)
    except Exception as exc:
        print(f"{path}: cannot read artifact: {exc}")
        return 1
    errors, warnings = validate_payload(
        payload,
        gate_id=gate_id,
        path=path,
        port=port,
        strict_current=strict_current,
    )
    for warning in warnings:
        print(f"{path}: warning: {warning}")
    for error in errors:
        print(f"{path}: error: {error}")
    print(
        f"benchmark_artifact_validation gate={gate_id} artifact={path} "
        f"quality={artifact_quality(payload, path)} errors={len(errors)} warnings={len(warnings)}"
    )
    return 1 if errors else 0


def self_test() -> int:
    base = {
        "implementation": "RustNode",
        "runtime_surface": "docker",
        "benchmark_contract_version": 1,
        "benchmark_gate": "baseline_5k",
        "benchmark_lane": "baseline_5k_p2p",
        "benchmark_kind": "baseline_5k_p2p",
        "target_height": 5000,
        "target_label": "5k",
        "header_target_height": 5000,
        "byte_source": "local_reference_p2p",
        "reference_start_height": 0,
        "reference_start_hash": "00000000da84f2bafbbc53dee25a72ae507ff4914b867c565be350b0da8bf043",
        "reference_finish_height": 5000,
        "reference_finish_hash": EXPECTED_HASHES["baseline_5k"],
        "validated_height": 5000,
        "validated_hash": EXPECTED_HASHES["baseline_5k"],
        "blocks_fetched": 5001,
        "blocks_connected": 5000,
        "current_blocker": None,
        "binary_gate_status": "not_attempted",
        "chainstate_backend": "rocksdb",
        "chainstate_utxo_count": 4574,
        "utxo_accounting_policy": "core_spendable_v1",
        "native_crypto_backend": "libsecp256k1",
        "proof_mode": "p2p_sync",
        "peer_mode": "local_reference",
        "peer": "bitcoin-core-testnet4:48333",
        "script_runner_mode": "parallel",
        "rocksdb_wal_disabled": False,
        "prefetch_depth": 4,
        "resume_supported": True,
        "fresh_state": True,
        "result": "passed",
        "failures": [],
        "captured_at": "2026-06-06T00:00:00Z",
        "timing_summary": {
            "total_ms": 1,
            "stage_totals_ms": {bucket: 0 for bucket in REQUIRED_BUCKETS},
        },
    }
    cases: list[tuple[str, dict[str, Any], str, bool]] = [
        ("bounded_pass", base, "baseline_5k", True),
        ("missing_captured_at", {**base, "captured_at": ""}, "baseline_5k", False),
        ("wrong_peer", {**base, "peer": "host.docker.internal:48333"}, "baseline_5k", False),
        ("alias_only_lane", {**base, "benchmark_gate": "supporting_5k", "benchmark_lane": "supporting_5k_p2p"}, "baseline_5k", False),
        (
            "long_run_pass",
            {
                **base,
                "benchmark_gate": "shakedown_50k",
                "benchmark_lane": "shakedown_50k_p2p",
                "benchmark_kind": "shakedown_50k_p2p",
                "target_height": 50000,
                "target_label": "50k",
                "header_target_height": 50000,
                "reference_finish_height": 50000,
                "reference_finish_hash": EXPECTED_HASHES["shakedown_50k"],
                "validated_height": 50000,
                "validated_hash": EXPECTED_HASHES["shakedown_50k"],
                "chainstate_utxo_count": 568855,
                "telemetry_schema": "benchmark.telemetry_tick.v1",
                "telemetry_summary": {
                    "telemetry_quality": "clean",
                    "tick_count": 8,
                    "heartbeat_max_gap_ms": 1000,
                    "lifecycle_markers": {
                        "run_started": 0,
                        "container_started": 1,
                        "node_started": 2,
                        "first_peer_byte": 3,
                        "first_block_connected": 4,
                        "target_reached": 5,
                        "run_finished": 6,
                    },
                },
                "timing_summary": {
                    "total_ms": 2,
                    "stage_totals_ms": {bucket: 1 for bucket in REQUIRED_BUCKETS},
                    "slow_blocks": [{"height": 1, "ms": 1}],
                },
            },
            "shakedown_50k",
            True,
        ),
        (
            "tip_once_pass",
            {
                **base,
                "benchmark_gate": "tip_once",
                "benchmark_lane": "tip_once_p2p",
                "benchmark_kind": "tip_once_p2p",
                "target_height": -1,
                "target_label": "tip once",
                "header_target_height": -1,
                "reference_finish_height": 123456,
                "reference_finish_hash": "0000000000000000000000000000000000000000000000000000000000000001",
                "validated_height": 123456,
                "validated_hash": "0000000000000000000000000000000000000000000000000000000000000001",
                "chainstate_utxo_count": 999,
                "telemetry_schema": "benchmark.telemetry_tick.v1",
                "telemetry_summary": {
                    "telemetry_quality": "clean",
                    "tick_count": 8,
                    "heartbeat_max_gap_ms": 1000,
                    "lifecycle_markers": {
                        "run_started": 0,
                        "container_started": 1,
                        "node_started": 2,
                        "first_peer_byte": 3,
                        "first_block_connected": 4,
                        "target_reached": 5,
                        "run_finished": 6,
                    },
                },
                "skipped_consensus_rules": [],
                "timing_summary": {
                    "total_ms": 2,
                    "stage_totals_ms": {bucket: 1 for bucket in REQUIRED_BUCKETS},
                    "slow_blocks": [{"height": 1, "ms": 1}],
                },
            },
            "tip_once",
            True,
        ),
        (
            "post_100k_to_tip_pass",
            {
                **base,
                "benchmark_gate": "post_100k_to_tip",
                "benchmark_lane": "post_100k_to_tip_p2p",
                "benchmark_kind": "post_100k_to_tip_p2p",
                "target_height": 123456,
                "target_label": "100k to tip",
                "header_target_height": 123456,
                "reference_start_height": 100000,
                "reference_start_hash": EXPECTED_HASHES["performance_100k"],
                "reference_finish_height": 123456,
                "reference_finish_hash": "0000000000000000000000000000000000000000000000000000000000000002",
                "validated_height": 123456,
                "validated_hash": "0000000000000000000000000000000000000000000000000000000000000002",
                "chainstate_utxo_count": 999,
                "fresh_state": False,
                "source_state_gate": "performance_100k",
                "source_state_origin": "port_durable_state",
                "source_state_height": 100000,
                "source_state_hash": EXPECTED_HASHES["performance_100k"],
                "source_state_utxo_count": 13154991,
                "telemetry_schema": "benchmark.telemetry_tick.v1",
                "telemetry_summary": {
                    "telemetry_quality": "clean",
                    "tick_count": 8,
                    "heartbeat_max_gap_ms": 1000,
                    "lifecycle_markers": {
                        "run_started": 0,
                        "container_started": 1,
                        "node_started": 2,
                        "first_peer_byte": 3,
                        "first_block_connected": 4,
                        "target_reached": 5,
                        "run_finished": 6,
                    },
                },
                "skipped_consensus_rules": [],
                "timing_summary": {
                    "total_ms": 2,
                    "stage_totals_ms": {bucket: 1 for bucket in REQUIRED_BUCKETS},
                    "slow_blocks": [{"height": 100001, "ms": 1}],
                },
            },
            "post_100k_to_tip",
            True,
        ),
    ]
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        failures = 0
        for name, payload, gate, should_pass in cases:
            path = root / f"rust_{name}.json"
            path.write_text(json.dumps(payload), encoding="utf-8")
            errors, _ = validate_payload(payload, gate_id=gate, path=path, port="rust", strict_current=True)
            passed = not errors
            if passed != should_pass:
                failures += 1
                print(f"self_test {name} expected_pass={should_pass} errors={errors}")
    print(f"benchmark_artifact_validator_self_test cases={len(cases)} failures={failures}")
    return 1 if failures else 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gate", choices=tuple(GATES), help="Official benchmark gate")
    parser.add_argument("--artifact", type=Path, action="append", default=[], help="Artifact JSON to validate")
    parser.add_argument("--port", help="Expected port owner")
    parser.add_argument("--strict-current", action="store_true", help="Require canonical current evidence shape")
    parser.add_argument("--self-test", action="store_true", help="Run built-in validator tests")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.self_test:
        return self_test()
    if not args.gate:
        raise SystemExit("--gate is required unless --self-test is used")
    if not args.artifact:
        raise SystemExit("--artifact is required unless --self-test is used")
    failures = 0
    for path in args.artifact:
        failures += validate_file(path, args.gate, args.port, strict_current=args.strict_current)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
