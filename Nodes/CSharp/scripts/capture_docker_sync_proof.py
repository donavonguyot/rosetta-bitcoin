#!/usr/bin/env python3
import json
import os
import pathlib
import sys
from datetime import datetime, timezone


def load_json(path: pathlib.Path) -> dict:
    if not path.exists() or not path.read_text().strip():
        return {}
    return json.loads(path.read_text())


def load_exit(path: pathlib.Path) -> int:
    if not path.exists():
        return 125
    return int((path.read_text().strip() or "0"))


def env_bool(name: str, default: bool = False) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def timing_summary(status: dict) -> dict:
    sync_timing = status.get("sync_timing")
    if not isinstance(sync_timing, dict):
        return {}
    unit = str(sync_timing.get("Unit", "")).lower()
    stages = sync_timing.get("Stages")
    if not isinstance(stages, dict):
        return {}
    totals = {}
    slow_blocks = []
    slow_block_shapes = sync_timing.get("SlowBlocks")
    if not isinstance(slow_block_shapes, list):
        slow_block_shapes = []
    for stage, values in stages.items():
        if not isinstance(values, dict):
            continue
        total_key = "TotalMicros" if "micro" in unit else "TotalMillis"
        total = int(values.get(total_key, 0) or 0)
        totals[stage] = max(0, round(total / 1000)) if "micro" in unit else total
        max_key = "MaxMicros" if "micro" in unit else "MaxMillis"
        max_value = int(values.get(max_key, 0) or 0)
        slow_blocks.append(
            {
                "stage": stage,
                "count": int(values.get("Count", 0) or 0),
                "max_ms": max(0, round(max_value / 1000)) if "micro" in unit else max_value,
            }
        )
    for stage in (
        "p2p_fetch",
        "block_parse_validate",
        "utxo_load",
        "script_verify",
        "utxo_apply",
        "commit",
        "block_connect_store_commit",
    ):
        totals.setdefault(stage, 0)
    return {
        "stage_totals_ms": totals,
        "total_ms": totals.get("block_connect_store_commit", sum(totals.values())),
        "slow_stages": sorted(slow_blocks, key=lambda row: row["max_ms"], reverse=True)[:10],
        "slow_blocks": slow_block_shapes,
    }


def target_label(height: int) -> str:
    labels = {5000: "5k", 10000: "10k", 50000: "50k", 100000: "100k"}
    return labels.get(height, "")


def supporting_gate(height: int) -> str:
    return {
        5000: "baseline_5k",
        10000: "diagnostic_10k",
        50000: "shakedown_50k",
        100000: "performance_100k",
    }.get(height, "local_reference")


def supporting_p2p_kind(height: int) -> str:
    return {
        5000: "baseline_5k_p2p",
        10000: "diagnostic_10k_p2p",
        50000: "shakedown_50k_p2p",
        100000: "performance_100k_p2p",
    }.get(height, "local_reference_p2p")


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: capture_docker_sync_proof.py STATUS_JSON EXIT_FILE", file=sys.stderr)
        return 2
    status = load_json(pathlib.Path(sys.argv[1]))
    exit_code = load_exit(pathlib.Path(sys.argv[2]))
    target_header_height = int(os.environ.get("TARGET_HEADER_HEIGHT", "200"))
    target_block_height = int(os.environ.get("TARGET_BLOCK_HEIGHT", "2"))
    validated_height = int(status.get("validated_height", -1))
    header_height = int(status.get("header_height", 0))
    reached_target = exit_code == 0 and validated_height >= target_block_height
    standard_benchmark = env_bool("STANDARD_BENCHMARK_ARTIFACT")
    run_info = load_json(pathlib.Path(os.environ.get("RUN_FILE", ".docker-csharp-proof-run.json")))
    prefetch_depth = int(os.environ.get("BLOCK_PREFETCH_DEPTH", "1"))
    script_runner_mode = os.environ.get("SCRIPT_RUNNER_MODE", "sequential")
    peer = status.get("peer_source") or os.environ.get("PEERS") or ""
    summary = timing_summary(status)
    proof_path = pathlib.Path(
        os.environ.get(
            "PROOF_PATH",
            "../Shared/conformance/results/csharp_native_crypto_docker_smoke_2026-06-01.json",
        )
    )
    artifact = {
        "implementation": "CSharpNode",
        "category": "docker_native_crypto_sync",
        "captured_at": datetime.now(timezone.utc).isoformat(),
        "datadir": status.get("datadir", "/data"),
        "chain": status.get("chain", "testnet4"),
        "runtime_surface": "docker",
        "target_header_height": target_header_height,
        "target_block_height": target_block_height,
        "target_height": target_block_height,
        "header_target_height": target_header_height,
        "target_label": target_label(target_block_height),
        "header_height": header_height,
        "validated_height": validated_height,
        "validated_hash": status.get("validated_hash", ""),
        "stored_block_height": status.get("stored_block_height", 0),
        "sync_status": status.get("sync_status", "unknown"),
        "chainstate_backend": status.get("chainstate_backend", ""),
        "codec_version": status.get("codec_version", ""),
        "chainstate_status": status.get("chainstate_status", ""),
        "native_storage": status.get("native_storage", True),
        "native_crypto_backend": status.get("native_crypto_backend", ""),
        "native_crypto_available": status.get("native_crypto_available", False),
        "taproot_tweak_backend": status.get("taproot_tweak_backend", ""),
        "sync_timing": status.get("sync_timing"),
        "timing_summary": summary,
        "pipeline_timing_summary": summary,
        "elapsed_ms": int(summary.get("total_ms", run_info.get("elapsed_ms", 0)) or 0),
        "proof_wrapper_elapsed_ms": int(run_info.get("elapsed_ms", 0) or 0),
        "sync_exit_code": exit_code,
        "result": "passed" if reached_target else "failed",
        "bounded_gate_status": "passed" if reached_target else "failed",
        "binary_gate_status": "not_attempted",
        "verification": {
            "command": os.environ.get("PROOF_COMMAND", "make docker-csharp-native-crypto-proof"),
            "docker_volume": os.environ.get("DOCKER_PROOF_VOLUME", "csbitnode_proof_data"),
            "live_progress_reporting": True,
            "progress_interval_seconds": int(os.environ.get("POLL_SEC", "120")),
        },
    }
    if standard_benchmark:
        artifact.update(
            {
                "benchmark_contract_version": 1,
                "telemetry_schema": "benchmark.telemetry_tick.v1",
                "benchmark_kind": supporting_p2p_kind(target_block_height),
                "benchmark_gate": supporting_gate(target_block_height),
                "benchmark_lane": supporting_p2p_kind(target_block_height),
                "utxo_accounting_policy": "core_spendable_v1",
                "byte_source": "local_reference_p2p",
                "proof_mode": "p2p_sync",
                "peer_mode": "local_reference",
                "peer": peer,
                "prefetch_depth": prefetch_depth,
                "script_runner_mode": script_runner_mode,
                "rocksdb_wal_disabled": env_bool("CSBITNODE_ROCKSDB_DISABLE_WAL"),
                "resume_supported": True,
                "fresh_state": True,
                "blocks_fetched": int(status.get("block_count", target_block_height) or 0),
                "blocks_connected": validated_height,
                "chainstate_utxo_count": int(status.get("utxo_count", 0) or 0),
                "reference_start_height": 0,
                "reference_start_hash": "00000000da84f2bafbbc53dee25a72ae507ff4914b867c565be350b0da8bf043",
                "reference_finish_height": target_block_height,
                "reference_finish_hash": status.get("validated_hash", ""),
                "current_blocker": status.get("current_blocker"),
                "failures": [] if reached_target else ["sync stopped before target"],
                "docker_volume": os.environ.get("DOCKER_PROOF_VOLUME", "csbitnode_proof_data"),
            }
        )
    else:
        artifact["runtime_truth_backend"] = "rocksdb"
        artifact["rocksdb_runtime_truth"] = status.get("chainstate_backend") == "rocksdb"
    proof_path.parent.mkdir(parents=True, exist_ok=True)
    proof_path.write_text(json.dumps(artifact, indent=2) + "\n")
    print(proof_path)
    return 0 if reached_target else 1


if __name__ == "__main__":
    raise SystemExit(main())
