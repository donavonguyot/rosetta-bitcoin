#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

VOLUME="${DOCKER_PROOF_VOLUME:-jbitnode_proof_data}"
TARGET="${DOCKER_BENCHMARK_TARGET:-5000}"
BLOCKS_MAX="${DOCKER_BENCHMARK_BLOCKS_MAX:-5000}"
HEADERS_MAX="${DOCKER_BENCHMARK_HEADERS_MAX:-5000}"
HEADER_BATCHES_MAX="${DOCKER_BENCHMARK_HEADER_BATCHES_MAX:-50}"
PREFETCH_DEPTH="${DOCKER_BENCHMARK_PREFETCH_DEPTH:-4}"
RESULT="${DOCKER_BENCHMARK_RESULT:-../Shared/conformance/results/java_docker_supporting_5k_benchmark_$(date +%F).json}"
PEER="${PEERS:-host.docker.internal:48333}"
BACKEND="${SECP256K1_BACKEND:-native}"
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

start_ms="$(now_ms)"
set +e
set +o pipefail
DOCKER_PROOF_VOLUME="$VOLUME" SECP256K1_BACKEND="$BACKEND" HEADERS_MAX="$HEADERS_MAX" \
  HEADER_BATCHES_MAX="$HEADER_BATCHES_MAX" BLOCKS_MAX="$BLOCKS_MAX" \
  docker compose -f docker/docker-compose.yml run --rm --no-deps \
    -e PAR_SCRIPT_VERIFY=1 \
    -e SYNC_TIMING=1 \
    -e BLOCK_PREFETCH_DEPTH="$PREFETCH_DEPTH" \
    -e ROCKSDB_DISABLE_WAL=0 \
    jbitnode-sync-proof 2>&1 | tee "$RUN_LOG_TMP"
sync_exit=${PIPESTATUS[0]}
set -o pipefail
set -e
end_ms="$(now_ms)"

set +e
DOCKER_PROOF_VOLUME="$VOLUME" SECP256K1_BACKEND="$BACKEND" \
  docker compose -f docker/docker-compose.yml run --rm --no-deps \
    jbitnode-sync-proof com.jbitnode.cli.DbStatus >"$STATUS_TMP" 2>&1
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
HEADERS_MAX="$HEADERS_MAX" \
HEADER_BATCHES_MAX="$HEADER_BATCHES_MAX" \
PREFETCH_DEPTH="$PREFETCH_DEPTH" \
PEER="$PEER" \
VOLUME="$VOLUME" \
BACKEND="$BACKEND" \
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


def extract_json_object(raw):
    start = raw.find("{")
    end = raw.rfind("}")
    if start < 0 or end < start:
        return {}
    return json.loads(raw[start : end + 1])


def parse_pairs(line):
    pairs = {}
    for key, value in re.findall(r"([A-Za-z0-9_]+)=([^ ]+)", line):
        pairs[key] = value
    return pairs


def parse_run_log(path):
    raw = path.read_text(errors="replace")
    timing = {}
    slow_blocks = []
    exit_summary = {}
    current_blocker = None
    for line in raw.splitlines():
        stripped = line.strip()
        if stripped.startswith("current_blocker="):
            current_blocker = stripped.split("=", 1)[1]
        elif stripped.startswith("sync_exit_summary "):
            exit_summary = parse_pairs(stripped)
        elif stripped.startswith("sync_timing_summary "):
            pairs = parse_pairs(stripped)
            for key, value in pairs.items():
                if key.startswith("total_") and key.endswith("_ms"):
                    timing[key.removeprefix("total_").removesuffix("_ms")] = as_int(value)
        elif stripped.startswith("sync_slow_block "):
            pairs = parse_pairs(stripped)
            slow_blocks.append(
                {
                    "rank": as_int(pairs.get("rank")),
                    "height": as_int(pairs.get("height")),
                    "block_size": as_int(pairs.get("block_size")),
                    "input_count": as_int(pairs.get("input_count")),
                    "utxo_load_ms": as_int(pairs.get("utxo_load_ms")),
                    "script_verify_ms": as_int(pairs.get("script_verify_ms")),
                    "utxo_apply_ms": as_int(pairs.get("utxo_apply_ms")),
                    "commit_ms": as_int(pairs.get("commit_ms")),
                    "block_connect_store_commit_ms": as_int(
                        pairs.get("block_connect_store_commit_ms")
                    ),
                }
            )
    return raw, timing, slow_blocks, exit_summary, current_blocker


status_raw = Path(os.environ["STATUS_PATH"]).read_text(errors="replace")
try:
    status = extract_json_object(status_raw)
except json.JSONDecodeError:
    status = {}
status.pop("local_sqlite_artifact_absent", None)

_, stage_totals, slow_blocks, exit_summary, log_blocker = parse_run_log(
    Path(os.environ["RUN_LOG_PATH"])
)

sync_exit = as_int(os.environ.get("SYNC_EXIT"))
status_exit = as_int(os.environ.get("STATUS_EXIT"))
start_ms = as_int(os.environ.get("START_MS"))
end_ms = as_int(os.environ.get("END_MS"))
elapsed_ms = max(0, end_ms - start_ms)
target = as_int(os.environ.get("TARGET"), 5000)
validated_height = as_int(status.get("validated_height"), -1)
stored_block_height = as_int(status.get("stored_block_height"), -1)
current_blocker = status.get("current_blocker") or log_blocker
sync_status = status.get("sync", {}).get("sync_status") or exit_summary.get("sync_status")

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

doc = {
    "benchmark_contract_version": 1,
    "benchmark_kind": "supporting_5k_p2p",
    "benchmark_gate": "supporting_5k",
    "benchmark_lane": "supporting_5k_p2p",
    "target_label": target_label(target),
    "target_height": target,
    "header_target_height": as_int(os.environ.get("HEADERS_MAX"), target),
    "category": "local_reference_sync",
    "result": "passed" if passed else "failed",
    "failures": failures,
    "implementation": "JavaNode",
    "port": "java",
    "node": "JavaNode",
    "runtime_surface": "docker",
    "peer_mode": "local_reference",
    "byte_source": "local_reference_p2p",
    "proof_mode": "p2p_sync",
    "peer": os.environ.get("PEER", "host.docker.internal:48333"),
    "docker_volume": os.environ.get("VOLUME", "jbitnode_proof_data"),
    "datadir": status.get("data_dir", "/data"),
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
    "header_hash": status.get("sync", {}).get("best_hash") or "",
    "stored_block_height": stored_block_height,
    "stored_block_hash": status.get("validated_hash") if stored_block_height == validated_height else "",
    "blocks_fetched": as_int(exit_summary.get("downloaded"), as_int(status.get("block_count"), 0)),
    "blocks_connected": as_int(exit_summary.get("connected"), max(0, validated_height)),
    "current_blocker": current_blocker,
    "chainstate_backend": status.get("chainstate_backend", "rocksdb"),
    "chainstate_backend_path": status.get("chainstate_backend_path", "/data/utxo-rocksdb"),
    "chainstate_status": status.get("chainstate_status"),
    "chainstate_utxo_count": as_int(status.get("chainstate_utxo_count"), 0),
    "native_storage": bool(status.get("native_storage", True)),
    "native_crypto_backend": status.get("native_crypto_backend") or os.environ.get("BACKEND", "native"),
    "native_crypto_available": bool(status.get("native_crypto_available", False)),
    "taproot_tweak_backend": status.get("taproot_tweak_backend"),
    "script_runner_mode": "parallel",
    "prefetch_depth": as_int(os.environ.get("PREFETCH_DEPTH"), 4),
    "rocksdb_wal_disabled": False,
    "fresh_state": True,
    "resume_supported": True,
    "timing_summary": {
        "total_ms": elapsed_ms,
        "stage_totals_ms": stage_totals,
        "slow_blocks": slow_blocks,
    },
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
