"""Shared helpers for NodeCore replay telemetry tools."""

from __future__ import annotations

import hashlib
import json
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError(f"{path} did not contain a JSON object")
    return data


def write_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def slug(value: Any) -> str:
    text = str(value or "unknown").strip().lower()
    text = re.sub(r"[^a-z0-9]+", "-", text).strip("-")
    return text or "unknown"


def infer_port(implementation: str, path: Path | None = None) -> str:
    lower = implementation.lower()
    for name in ("go", "java", "python", "typescript", "csharp", "cpp", "rust", "elixir"):
        if name in lower:
            return name
    if path:
        stem = path.name.lower()
        for name in ("go", "java", "python", "typescript", "csharp", "cpp", "rust", "elixir"):
            if stem.startswith(name) or f"_{name}_" in stem:
                return name
    return slug(implementation)


def as_int(value: Any) -> int | None:
    if value is None:
        return None
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value if value >= 0 else None
    if isinstance(value, float) and value >= 0:
        return int(value)
    if isinstance(value, str) and value.isdigit():
        return int(value)
    return None


def canonical_result(value: Any) -> str:
    text = str(value or "unknown").lower()
    if text in {"passed", "pass", "success", "succeeded"}:
        return "passed"
    if text in {"failed", "fail", "failure", "error"}:
        return "failed"
    if text in {"blocked", "blocker"}:
        return "blocked"
    return "unknown"


def first_dict(*values: Any) -> dict[str, Any]:
    for value in values:
        if isinstance(value, dict):
            return value
    return {}


def normalize_stage_totals(raw: dict[str, Any]) -> dict[str, int]:
    timing = first_dict(raw.get("timing_summary"), first_dict(raw.get("connect_summary")).get("timing_summary"))
    stages = timing.get("stage_totals_ms")
    if not isinstance(stages, dict):
        stages = raw.get("stage_totals_ms")
    if not isinstance(stages, dict):
        return {}
    normalized: dict[str, int] = {}
    for key, value in stages.items():
        parsed = as_int(value)
        if parsed is not None:
            normalized[str(key)] = parsed
    return normalized


def normalize_replay_artifact(raw: dict[str, Any], *, source_path: Path | None = None, command: list[str] | None = None) -> dict[str, Any]:
    if raw.get("artifact_kind") == "nodecore.replay_telemetry":
        return raw

    connect = first_dict(raw.get("connect_summary"), raw.get("local_reference_status"))
    sync = first_dict(raw.get("sync_summary"))
    timing = first_dict(raw.get("timing_summary"), connect.get("timing_summary"))
    implementation = str(raw.get("implementation") or connect.get("implementation") or sync.get("implementation") or "unknown")
    port = infer_port(implementation, source_path)
    runtime = str(raw.get("runtime_surface") or connect.get("runtime_surface") or sync.get("runtime_surface") or "unknown")
    replay_mode = str(raw.get("proof_mode") or connect.get("mode") or raw.get("replay_mode") or "unknown")
    target_height = as_int(raw.get("target_height") or connect.get("target_height") or sync.get("target_height")) or 0
    validated_height = as_int(raw.get("validated_height") or connect.get("validated_height") or sync.get("validated_height")) or 0
    captured_at = raw.get("captured_at") or connect.get("started_at") or sync.get("started_at")
    updated_at = raw.get("updated_at") or connect.get("updated_at") or sync.get("updated_at")
    now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    source_hint = str(source_path) if source_path else json.dumps(raw, sort_keys=True)[:200]
    digest = hashlib.sha256(source_hint.encode("utf-8")).hexdigest()[:10]
    run_id = raw.get("run_id") or f"{slug(port)}-{slug(runtime)}-{slug(replay_mode)}-{target_height}-{digest}"

    return {
        "schema_version": 1,
        "artifact_kind": "nodecore.replay_telemetry",
        "run_id": run_id,
        "implementation": implementation,
        "port": port,
        "runtime_surface": runtime,
        "replay_mode": replay_mode,
        "chain": str(raw.get("chain") or "testnet4"),
        "target_height": target_height,
        "validated_height": validated_height,
        "validated_hash": raw.get("validated_hash") or connect.get("validated_hash"),
        "stored_block_height": as_int(raw.get("stored_block_height") or connect.get("stored_block_height") or sync.get("stored_block_height")),
        "header_height": as_int(raw.get("header_height") or connect.get("header_height") or sync.get("header_height")),
        "result": canonical_result(raw.get("result") or connect.get("result")),
        "current_blocker": raw.get("current_blocker") or connect.get("current_blocker") or sync.get("current_blocker"),
        "started_at": captured_at,
        "updated_at": updated_at,
        "captured_at": raw.get("captured_at") or now,
        "elapsed_ms": as_int(timing.get("total_ms") or raw.get("elapsed_ms")),
        "stage_totals_ms": normalize_stage_totals(raw),
        "slow_blocks": timing.get("slow_blocks") if isinstance(timing.get("slow_blocks"), list) else [],
        "progress_samples": raw.get("progress_samples") if isinstance(raw.get("progress_samples"), list) else [],
        "resource_samples": raw.get("resource_samples") if isinstance(raw.get("resource_samples"), list) else [],
        "prefetch_depth": as_int(raw.get("prefetch_depth") or connect.get("prefetch_depth")),
        "script_runner_mode": raw.get("script_runner_mode") or connect.get("script_runner_mode"),
        "script_threads": as_int(raw.get("script_threads") or connect.get("script_threads")),
        "crypto_context_mode": raw.get("crypto_context_mode") or connect.get("crypto_context_mode"),
        "storage_codec_version": raw.get("storage_codec_version") or connect.get("storage_codec_version"),
        "chainstate_backend": raw.get("chainstate_backend"),
        "chainstate_utxo_count": as_int(raw.get("chainstate_utxo_count") or connect.get("chainstate_utxo_count")),
        "rocksdb_wal_disabled": raw.get("rocksdb_wal_disabled") if "rocksdb_wal_disabled" in raw else connect.get("rocksdb_wal_disabled"),
        "rocksdb_tuning": raw.get("rocksdb_tuning") or connect.get("rocksdb_tuning"),
        "peer_mode": raw.get("peer_mode") or sync.get("peer_mode"),
        "peer": raw.get("peer") or sync.get("peer"),
        "docker_volume": raw.get("docker_volume"),
        "profile_paths": raw.get("profile_paths") or connect.get("profile_paths") or {},
        "source_artifact": str(source_path) if source_path else None,
        "command": command or [],
    }
