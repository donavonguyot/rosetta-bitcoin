#!/usr/bin/env python3
"""Capture Elixir Docker/local-reference 5k benchmark evidence."""

from __future__ import annotations

import datetime as dt
import json
import os
import pathlib
import re
import sys
from typing import Any


GENESIS_HASH = "00000000da84f2bafbbc53dee25a72ae507ff4914b867c565be350b0da8bf043"


def load_status(path: pathlib.Path) -> dict[str, Any]:
    raw = path.read_text(encoding="utf-8")
    start = raw.find("{")
    end = raw.rfind("}")
    if start < 0 or end < start:
        return {}
    payload = json.loads(raw[start : end + 1])
    return payload if isinstance(payload, dict) else {}


def load_exit_code(path: pathlib.Path) -> int:
    try:
        return int(path.read_text(encoding="utf-8").strip() or "0")
    except (OSError, ValueError):
        return 0


def as_int(value: Any, default: int = -1) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def parse_sync_log(path: pathlib.Path) -> dict[str, Any]:
    parsed: dict[str, Any] = {}
    if not path.exists():
        return parsed
    for raw_line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw_line.strip()
        match = re.match(r"^(downloaded_blocks|connected_blocks|sync_status|current_blocker|validated_height|utxo_count|binary_gate_status)=(.*)$", line)
        if match:
            key, value = match.groups()
            parsed[key] = value
            continue
        match = re.match(r"^sync_timing_json=(\{.*\})$", line)
        if match:
            try:
                parsed["sync_timing"] = json.loads(match.group(1))
            except json.JSONDecodeError:
                parsed["sync_timing"] = {}
    return parsed


def timing_summary(sync_timing: dict[str, Any]) -> dict[str, Any]:
    stage_totals_ms: dict[str, int] = {}
    for stage, micros in sorted(sync_timing.items()):
        stage_totals_ms[stage] = int(round(as_int(micros, 0) / 1000))
    return {
        "stage_totals_ms": stage_totals_ms,
        "total_ms": stage_totals_ms.get("block_connect_store_commit", 0),
        "slow_stages": [
            {
                "stage": stage,
                "total_ms": total_ms,
            }
            for stage, total_ms in sorted(stage_totals_ms.items(), key=lambda item: item[1], reverse=True)
        ],
    }


def main() -> int:
    if len(sys.argv) != 4:
        print(
            "usage: capture_elixir_docker_5k_benchmark.py STATUS_JSON SYNC_LOG SYNC_EXIT_FILE",
            file=sys.stderr,
        )
        return 2

    status = load_status(pathlib.Path(sys.argv[1]))
    log = parse_sync_log(pathlib.Path(sys.argv[2]))
    sync_exit_code = load_exit_code(pathlib.Path(sys.argv[3]))

    target_height = int(os.environ.get("TARGET_HEIGHT", "5000"))
    header_target_height = int(os.environ.get("HEADER_TARGET_HEIGHT", str(target_height)))
    prefetch_depth = int(os.environ.get("PREFETCH_DEPTH", "4"))
    peer = os.environ.get("PEER", "host.docker.internal:48333")
    docker_volume = os.environ.get("DOCKER_PROOF_VOLUME", "exbitnode_proof_data")

    validated_height = as_int(status.get("validated_height"))
    header_height = as_int(status.get("header_height"))
    stored_block_height = as_int(status.get("stored_block_height"))
    current_blocker = status.get("current_blocker") or log.get("current_blocker")
    last_error = status.get("last_error")
    sync_timing = log.get("sync_timing") if isinstance(log.get("sync_timing"), dict) else {}
    if not sync_timing and isinstance(status.get("sync_timing"), dict):
        sync_timing = status.get("sync_timing", {})
    timing = timing_summary(sync_timing)

    failures: list[str] = []
    if sync_exit_code != 0:
      failures.append(f"sync_exit_code={sync_exit_code}")
    if validated_height < target_height:
      failures.append(f"validated_height {validated_height} < target_height {target_height}")
    if header_height != header_target_height:
      failures.append(f"header_height {header_height} != header_target_height {header_target_height}")
    if stored_block_height < target_height:
      failures.append(f"stored_block_height {stored_block_height} < target_height {target_height}")
    if current_blocker:
      failures.append(str(current_blocker))
    if last_error:
      failures.append(str(last_error))

    passed = not failures
    labels = {5000: "5k", 10000: "10k", 50000: "50k", 100000: "100k"}
    target_label = labels.get(target_height, "")
    benchmark_gate = f"supporting_{target_label}" if target_label else "local_reference"
    benchmark_kind = f"supporting_{target_label}_p2p" if target_label else "local_reference_p2p"

    artifact = {
        "implementation": "ElixirNode",
        "node": "ElixirNode",
        "port": "elixir",
        "category": "local_reference_sync",
        "captured_at": dt.datetime.now(dt.UTC).isoformat().replace("+00:00", "Z"),
        "chain": status.get("chain", "testnet4"),
        "runtime_surface": "docker",
        "datadir": status.get("datadir", "/data"),
        "benchmark_contract_version": 1,
        "telemetry_schema": "benchmark.telemetry_tick.v1",
        "benchmark_gate": benchmark_gate,
        "benchmark_kind": benchmark_kind,
        "benchmark_lane": benchmark_kind,
        "utxo_accounting_policy": "core_spendable_v1",
        "target_height": target_height,
        "target_label": target_label,
        "header_target_height": header_target_height,
        "byte_source": "local_reference_p2p",
        "proof_mode": "p2p_sync",
        "peer_mode": "local_reference",
        "peer": peer,
        "prefetch_depth": prefetch_depth,
        "script_runner_mode": os.environ.get("SCRIPT_RUNNER_MODE", "parallel"),
        "rocksdb_wal_disabled": False,
        "resume_supported": True,
        "fresh_state": True,
        "binary_gate_status": "not_attempted",
        "result": "passed" if passed else "failed",
        "failures": failures,
        "sync_exit_code": sync_exit_code,
        "sync_status": status.get("sync_status") or log.get("sync_status"),
        "header_height": header_height,
        "header_hash": status.get("header_hash", ""),
        "validated_height": validated_height,
        "validated_hash": status.get("validated_hash", ""),
        "stored_block_height": stored_block_height,
        "stored_block_hash": status.get("stored_block_hash", ""),
        "blocks_fetched": as_int(log.get("downloaded_blocks"), max(validated_height + 1, 0)),
        "blocks_connected": as_int(log.get("connected_blocks"), max(validated_height + 1, 0)),
        "chainstate_backend": status.get("chainstate_backend", "rocksdb"),
        "chainstate_status": status.get("chainstate_status", ""),
        "chainstate_utxo_count": as_int(status.get("chainstate_utxo_count"), 0),
        "native_storage": True,
        "native_crypto_backend": status.get("native_crypto_backend", ""),
        "native_crypto_available": bool(status.get("native_crypto_available")),
        "taproot_tweak_backend": status.get("taproot_tweak_backend", ""),
        "current_blocker": current_blocker,
        "last_error": last_error,
        "reference_start_height": 0,
        "reference_start_hash": GENESIS_HASH,
        "reference_finish_height": target_height,
        "reference_finish_hash": status.get("validated_hash", ""),
        "docker_volume": docker_volume,
        "elapsed_ms": timing["total_ms"],
        "sync_timing": {
            "unit": "microseconds",
            "stages": sync_timing,
        },
        "timing_summary": timing,
        "pipeline_timing_summary": timing,
        "status": status,
        "verification": {
            "command": "make docker-proof-local",
            "docker_volume": docker_volume,
            "sync_exit_code": sync_exit_code,
        },
    }

    proof_path = pathlib.Path(
        os.environ.get(
            "PROOF_PATH",
            "Nodes/Shared/conformance/results/elixir_docker_supporting_5k_benchmark.json",
        )
    )
    proof_path.parent.mkdir(parents=True, exist_ok=True)
    proof_path.write_text(json.dumps(artifact, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(proof_path)
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
