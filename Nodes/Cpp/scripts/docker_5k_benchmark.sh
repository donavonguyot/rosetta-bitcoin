#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

VOLUME="${DOCKER_PROOF_VOLUME:-cpbitnode_proof_data}"
TARGET="${DOCKER_BENCHMARK_TARGET:-5000}"
BLOCKS_MAX="${DOCKER_BENCHMARK_BLOCKS_MAX:-5000}"
PEERS="${DOCKER_BENCHMARK_PEERS:-host.docker.internal:48333}"
PREFETCH_DEPTH="${DOCKER_BENCHMARK_PREFETCH_DEPTH:-4}"
RESULT="${DOCKER_BENCHMARK_RESULT:-../Shared/conformance/results/cpp_docker_supporting_5k_benchmark_$(date +%F).json}"
REFERENCE_START_HEIGHT="${REFERENCE_START_HEIGHT:-0}"

reference_hash() {
  docker exec rosetta-bitcoin-core-testnet4 \
    bitcoin-cli -conf=/config/bitcoin.conf getblockhash "$1" 2>/dev/null || true
}

now_ms() {
  python3 -c 'import time; print(int(time.time() * 1000))'
}

RUN_LOG_TMP="$(mktemp)"
STATUS_TMP="$(mktemp)"
trap 'rm -f "$RUN_LOG_TMP" "$STATUS_TMP"' EXIT

REFERENCE_START_HASH="${REFERENCE_START_HASH:-$(reference_hash "$REFERENCE_START_HEIGHT")}"
REFERENCE_FINISH_HEIGHT="${REFERENCE_FINISH_HEIGHT:-$TARGET}"
REFERENCE_FINISH_HASH="${REFERENCE_FINISH_HASH:-$(reference_hash "$REFERENCE_FINISH_HEIGHT")}"

python3 scripts/target_readiness_check.py --target "$TARGET"

start_ms="$(now_ms)"
set +e
set +o pipefail
DOCKER_PROOF_VOLUME="$VOLUME" PEERS="$PEERS" BLOCKS_MAX="$BLOCKS_MAX" BLOCKS_TARGET="$TARGET" \
  docker compose -f docker/docker-compose.yml run --rm --no-deps \
    -e CPBITNODE_SYNC_TIMING=1 \
    -e CPBITNODE_SCRIPT_VERIFY_PARALLEL=1 \
    -e CPBITNODE_SCRIPT_VERIFY_THREADS="${CPBITNODE_SCRIPT_VERIFY_THREADS:-}" \
    -e CPBITNODE_BLOCK_PREFETCH_DEPTH="$PREFETCH_DEPTH" \
    -e PARALLEL_BLOCK_DOWNLOADS="$PREFETCH_DEPTH" \
    cpbitnode-sync-proof 2>&1 | python3 scripts/benchmark_telemetry_filter.py --target "$TARGET" --port cpp | tee "$RUN_LOG_TMP"
sync_exit=${PIPESTATUS[0]}
set -o pipefail
set -e
end_ms="$(now_ms)"

set +e
DOCKER_PROOF_VOLUME="$VOLUME" \
  docker compose -f docker/docker-compose.yml run --rm --no-deps \
    cpbitnode-sync-proof cpbitnode-db --datadir /data --chainstate-backend rocksdb >"$STATUS_TMP" 2>&1
status_exit=$?
set -e

mkdir -p "$(dirname "$RESULT")"

RESULT_PATH="$RESULT" \
RUN_LOG_PATH="$RUN_LOG_TMP" \
STATUS_PATH="$STATUS_TMP" \
SYNC_EXIT="$sync_exit" \
STATUS_EXIT="$status_exit" \
START_MS="$start_ms" \
END_MS="$end_ms" \
TARGET="$TARGET" \
BLOCKS_MAX="$BLOCKS_MAX" \
PREFETCH_DEPTH="$PREFETCH_DEPTH" \
PEERS="$PEERS" \
VOLUME="$VOLUME" \
REFERENCE_START_HEIGHT="$REFERENCE_START_HEIGHT" \
REFERENCE_START_HASH="$REFERENCE_START_HASH" \
REFERENCE_FINISH_HEIGHT="$REFERENCE_FINISH_HEIGHT" \
REFERENCE_FINISH_HASH="$REFERENCE_FINISH_HASH" \
python3 <<'PY'
import json
import os
import re
from datetime import datetime, timezone
from pathlib import Path


def as_int(value, default=0):
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def target_label(target):
    if target == 5000:
        return "5k"
    if target % 1000 == 0:
        return f"{target // 1000}k"
    return str(target)


def supporting_gate(target):
    if target == 100000:
        return "primary_100k"
    label = target_label(target)
    return f"supporting_{label}" if label else "local_reference"


def supporting_p2p_kind(target):
    if target == 100000:
        return "primary_100k_p2p"
    label = target_label(target)
    return f"supporting_{label}_p2p" if label else "local_reference_p2p"


def extract_json_object(raw):
    start = raw.find("{")
    end = raw.rfind("}")
    if start < 0 or end < start:
        return {}
    return json.loads(raw[start : end + 1])


def parse_timing_line(line):
    pairs = dict(re.findall(r"([A-Za-z0-9_]+)=([^ ]+)", line))
    if pairs.get("unit") != "us":
        return None
    height = as_int(pairs.get("height"))
    stages_us = {
        "utxo_load": as_int(pairs.get("utxo_load")),
        "script_verify": as_int(pairs.get("script_verify")),
        "script_verify_worker_cpu": as_int(pairs.get("script_verify_worker_cpu")),
        "utxo_apply": as_int(pairs.get("utxo_apply")),
        "commit": as_int(pairs.get("commit")),
        "block_connect_store_commit": as_int(pairs.get("block_connect_store_commit")),
    }
    if stages_us["block_connect_store_commit"] == 0:
        stages_us["block_connect_store_commit"] = (
            stages_us["utxo_load"]
            + stages_us["script_verify"]
            + stages_us["utxo_apply"]
            + stages_us["commit"]
        )
    return height, stages_us, pairs


def parse_run_log(path):
    raw = path.read_text(errors="replace")
    stage_totals_us = {}
    pipeline_totals_us = {}
    slow_blocks = []
    sync_summary = {}
    current_blocker = None
    pipeline_blocks_fetched = 0
    pipeline_blocks_connected = 0
    pipeline_p2p_frames_read = 0
    pipeline_p2p_bytes_read = 0
    pipeline_p2p_header_read_us = 0
    pipeline_p2p_payload_read_us = 0
    script_threads = 1
    for line in raw.splitlines():
        stripped = line.strip()
        if stripped.startswith("cpbitnode_sync_timing "):
            parsed = parse_timing_line(stripped)
            if not parsed:
                continue
            height, stages_us, pairs = parsed
            block_total_us = stages_us["block_connect_store_commit"]
            for stage, value in stages_us.items():
                stage_totals_us[stage] = stage_totals_us.get(stage, 0) + value
            slow_blocks.append(
                {
                    "height": height,
                    "block_connect_store_commit_ms": round(block_total_us / 1000),
                    "utxo_load_ms": round(stages_us["utxo_load"] / 1000),
                    "script_verify_ms": round(stages_us["script_verify"] / 1000),
                    "script_verify_worker_cpu_ms": round(stages_us["script_verify_worker_cpu"] / 1000),
                    "utxo_apply_ms": round(stages_us["utxo_apply"] / 1000),
                    "commit_ms": round(stages_us["commit"] / 1000),
                    "tx_count": as_int(pairs.get("tx_count")),
                    "vin_count": as_int(pairs.get("vin_count")),
                    "vout_count": as_int(pairs.get("vout_count")),
                    "script_input_count": as_int(pairs.get("script_input_count")),
                    "input_shape_counts": pairs.get("input_shape_counts", "none"),
                    "spent_prevout_script_types": pairs.get("spent_prevout_script_types", "none"),
                    "output_script_types": pairs.get("output_script_types", "none"),
                }
            )
        elif stripped.startswith("cpbitnode_pipeline_timing "):
            pairs = dict(re.findall(r"([A-Za-z0-9_]+)=([^ ]+)", stripped))
            if pairs.get("unit") != "us":
                continue
            for stage in [
                "total_wall",
                "block_fetch_wait",
                "block_parse_validate",
                "block_store",
                "metadata_store",
                "connect_total",
                "utxo_load",
                "prevout_batch_load",
                "script_verify",
                "script_verify_worker_cpu",
                "utxo_apply",
                "commit",
                "status_writes",
                "idle_wait",
                "script_legacy_sighash",
                "script_bip143_sighash",
                "script_taproot_sighash",
                "script_ecdsa_verify",
                "script_schnorr_verify",
                "script_interpreter_eval",
                "script_runner_wait",
                "utxo_delete_prepare",
                "utxo_put_prepare",
                "undo_put_prepare",
                "metadata_put_prepare",
                "rocksdb_write",
                "commit_batch_puts",
                "commit_batch_deletes",
                "commit_key_bytes",
                "commit_value_bytes",
                "commit_utxo_puts",
                "commit_utxo_deletes",
                "commit_undo_bytes",
                "commit_created_list_bytes",
                "commit_metadata_puts",
                "commit_block_index_bytes",
            ]:
                pipeline_totals_us[stage] = pipeline_totals_us.get(stage, 0) + as_int(pairs.get(stage))
            pipeline_blocks_fetched += as_int(pairs.get("blocks_fetched"))
            pipeline_blocks_connected += as_int(pairs.get("blocks_connected"))
            pipeline_p2p_frames_read += as_int(pairs.get("p2p_frames_read"))
            pipeline_p2p_bytes_read += as_int(pairs.get("p2p_bytes_read"))
            pipeline_p2p_header_read_us += as_int(pairs.get("p2p_header_read_us"))
            pipeline_p2p_payload_read_us += as_int(pairs.get("p2p_payload_read_us"))
            script_threads = max(script_threads, as_int(pairs.get("script_threads"), 1))
        elif "Block sync complete:" in stripped:
            pairs = dict(re.findall(r"([A-Za-z0-9_]+)=([^ ]+)", stripped))
            sync_summary = pairs
        elif "Rejected invalid block" in stripped or "Block connect failed" in stripped:
            current_blocker = stripped
    slow_blocks.sort(key=lambda item: item["block_connect_store_commit_ms"], reverse=True)
    for index, item in enumerate(slow_blocks[:10], start=1):
        item["rank"] = index
    stage_totals_ms = {stage: round(value / 1000) for stage, value in stage_totals_us.items()}
    pipeline_summary = {stage: round(value / 1000) for stage, value in pipeline_totals_us.items()}
    pipeline_summary["blocks_fetched"] = pipeline_blocks_fetched
    pipeline_summary["blocks_connected"] = pipeline_blocks_connected
    pipeline_summary["script_threads"] = script_threads
    pipeline_summary["p2p_frames_read"] = pipeline_p2p_frames_read
    pipeline_summary["p2p_bytes_read"] = pipeline_p2p_bytes_read
    pipeline_summary["p2p_header_read_us"] = pipeline_p2p_header_read_us
    pipeline_summary["p2p_payload_read_us"] = pipeline_p2p_payload_read_us
    return raw, stage_totals_ms, pipeline_summary, slow_blocks[:10], sync_summary, current_blocker


status_raw = Path(os.environ["STATUS_PATH"]).read_text(errors="replace")
try:
    status = extract_json_object(status_raw)
except json.JSONDecodeError:
    status = {}

_, stage_totals, pipeline_summary, slow_blocks, sync_summary, log_blocker = parse_run_log(Path(os.environ["RUN_LOG_PATH"]))

sync_exit = as_int(os.environ.get("SYNC_EXIT"))
status_exit = as_int(os.environ.get("STATUS_EXIT"))
start_ms = as_int(os.environ.get("START_MS"))
end_ms = as_int(os.environ.get("END_MS"))
elapsed_ms = max(0, end_ms - start_ms)
target = as_int(os.environ.get("TARGET"), 5000)
validated_height = as_int(status.get("validated_height"), -1)
stored_block_height = as_int(status.get("stored_block_height"), -1)
current_blocker = status.get("current_blocker") or log_blocker
sync_status = status.get("sync_status") or sync_summary.get("sync_status")

failures = []
if sync_exit != 0:
    failures.append(f"sync_exit={sync_exit}")
if status_exit != 0:
    failures.append(f"status_exit={status_exit}")
if validated_height < target:
    failures.append(f"validated_height<{target}")
if current_blocker:
    failures.append("current_blocker_present")
if not os.environ.get("REFERENCE_START_HASH"):
    failures.append("reference_start_hash_missing")
if not os.environ.get("REFERENCE_FINISH_HASH"):
    failures.append("reference_finish_hash_missing")

passed = not failures
captured_at = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
if not stage_totals:
    stage_totals = {"block_connect_store_commit": elapsed_ms}
if not pipeline_summary.get("total_wall"):
    pipeline_summary["total_wall"] = elapsed_ms
pipeline_summary.setdefault("block_fetch_wait", 0)
pipeline_summary.setdefault("block_parse_validate", 0)
pipeline_summary.setdefault("block_store", 0)
pipeline_summary.setdefault("metadata_store", 0)
pipeline_summary.setdefault("connect_total", stage_totals.get("block_connect_store_commit", 0))
for stage in ["utxo_load", "script_verify", "script_verify_worker_cpu", "utxo_apply", "commit"]:
    if pipeline_summary.get(stage, 0) == 0:
        pipeline_summary[stage] = stage_totals.get(stage, 0)
if pipeline_summary.get("prevout_batch_load", 0) == 0:
    pipeline_summary["prevout_batch_load"] = stage_totals.get("utxo_load", 0)
pipeline_summary.setdefault("status_writes", 0)
pipeline_summary.setdefault("idle_wait", 0)
pipeline_summary.setdefault("p2p_frames_read", 0)
pipeline_summary.setdefault("p2p_bytes_read", 0)
pipeline_summary.setdefault("p2p_header_read_us", 0)
pipeline_summary.setdefault("p2p_payload_read_us", 0)
if pipeline_summary.get("p2p_fetch", 0) == 0:
    pipeline_summary["p2p_fetch"] = pipeline_summary.get("block_fetch_wait", 0)

doc = {
    "benchmark_contract_version": 1,
    "benchmark_kind": supporting_p2p_kind(target),
    "benchmark_gate": supporting_gate(target),
    "benchmark_lane": supporting_p2p_kind(target),
    "telemetry_schema": "benchmark.telemetry_tick.v1",
    "utxo_accounting_policy": "core_spendable_v1",
    "target_label": target_label(target),
    "target_height": target,
    "header_target_height": target,
    "category": "local_reference_sync",
    "result": "passed" if passed else "failed",
    "failures": failures,
    "implementation": "Cpp",
    "port": "cpp",
    "node": "Cpp",
    "runtime_surface": "docker",
    "peer_mode": "local_reference",
    "byte_source": "local_reference_p2p",
    "proof_mode": "p2p_sync",
    "peer": os.environ.get("PEERS", "host.docker.internal:48333"),
    "docker_volume": os.environ.get("VOLUME", "cpbitnode_proof_data"),
    "datadir": "/data",
    "chain": status.get("chain", "testnet4"),
    "binary_gate_status": "not_attempted",
    "local_reference_status": "target_reached" if passed else "target_not_reached",
    "reference_start_height": as_int(os.environ.get("REFERENCE_START_HEIGHT"), 0),
    "reference_start_hash": os.environ.get("REFERENCE_START_HASH") or None,
    "reference_finish_height": as_int(os.environ.get("REFERENCE_FINISH_HEIGHT"), target),
    "reference_finish_hash": os.environ.get("REFERENCE_FINISH_HASH") or None,
    "sync_exit_code": sync_exit,
    "status_exit_code": status_exit,
    "sync_status": sync_status,
    "validated_height": validated_height,
    "validated_hash": status.get("validated_hash") or "",
    "header_height": as_int(status.get("header_height"), 0),
    "header_hash": status.get("header_hash") or "",
    "stored_block_height": stored_block_height,
    "stored_block_hash": status.get("stored_block_hash") or "",
    "blocks_fetched": as_int(sync_summary.get("downloaded"), as_int(status.get("block_count"), 0)),
    "blocks_connected": max(0, validated_height),
    "current_blocker": current_blocker,
    "chainstate_backend": status.get("chainstate_backend", "rocksdb"),
    "chainstate_backend_path": status.get("chainstate_backend_path", "/data/chainstate-rocksdb"),
    "chainstate_status": status.get("chainstate_status"),
    "chainstate_utxo_count": as_int(status.get("chainstate_utxo_count"), 0),
    "native_storage": status.get("chainstate_backend", "rocksdb") == "rocksdb",
    "native_crypto_backend": status.get("native_crypto_backend") or "libsecp256k1",
    "native_crypto_available": bool(status.get("native_crypto_available", False)),
    "taproot_tweak_backend": status.get("taproot_tweak_backend"),
    "script_runner_mode": "parallel" if pipeline_summary.get("script_threads", 1) > 1 else "sequential",
    "script_threads": as_int(pipeline_summary.get("script_threads"), 1),
    "crypto_context_mode": status.get("native_crypto_backend") or "libsecp256k1",
    "prefetch_depth": as_int(os.environ.get("PREFETCH_DEPTH"), 4),
    "rocksdb_tuning": "block_cache=512MiB,bloom=10,write_buffer=64MiB,max_write_buffers=4,max_background_jobs=4",
    "rocksdb_wal_disabled": False,
    "fresh_state": True,
    "resume_supported": True,
    "timing_summary": {
        "total_ms": elapsed_ms,
        "stage_totals_ms": stage_totals,
        "slow_blocks": slow_blocks,
    },
    "pipeline_timing_summary": pipeline_summary,
    "elapsed_ms": elapsed_ms,
    "captured_at": captured_at,
    "updated_at": captured_at,
    "status": status,
}

result_path = Path(os.environ["RESULT_PATH"])
result_path.write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n")
print(json.dumps(doc, indent=2, sort_keys=True))

if not passed:
    raise SystemExit(1)
PY
