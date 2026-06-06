#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

REFERENCE_TOPOLOGY_ENV="${REFERENCE_TOPOLOGY_ENV:-../Shared/docker/reference_topology.env}"
# shellcheck source=/dev/null
. "$REFERENCE_TOPOLOGY_ENV"
DOCKER_COMPOSE=(docker compose --env-file "$REFERENCE_TOPOLOGY_ENV" -f docker/docker-compose.yml)

VOLUME="${DOCKER_PROOF_VOLUME:-tsbitnode_proof_data}"
TARGET="${DOCKER_SYNC_TARGET:-5000}"
BLOCKS_MAX="${DOCKER_SYNC_BLOCKS_MAX:-5000}"
PREFETCH_DEPTH="${DOCKER_BENCHMARK_PREFETCH_DEPTH:-4}"
RESULT="${DOCKER_BENCHMARK_RESULT:-../Shared/conformance/results/typescript_docker_baseline_5k_benchmark_$(date +%F).json}"
PEER="${PEERS:-${REFERENCE_P2P_PEER:?REFERENCE_P2P_PEER missing}}"
export PEER
BACKEND="${SECP256K1_BACKEND:-native}"
REFERENCE_START_HEIGHT="${REFERENCE_START_HEIGHT:-0}"

reference_hash() {
  docker exec rosetta-bitcoin-core-testnet4 \
    bitcoin-cli -conf=/config/bitcoin.conf getblockhash "$1" 2>/dev/null || true
}

STATUS_TMP="$(mktemp)"
LOG_TMP="$(mktemp)"
trap 'rm -f "$STATUS_TMP" "$LOG_TMP"' EXIT

now_ms() {
  python3 -c 'import time; print(int(time.time() * 1000))'
}

REFERENCE_START_HASH="${REFERENCE_START_HASH:-$(reference_hash "$REFERENCE_START_HEIGHT")}"
REFERENCE_FINISH_HEIGHT="${REFERENCE_FINISH_HEIGHT:-$TARGET}"
REFERENCE_FINISH_HASH="${REFERENCE_FINISH_HASH:-$(reference_hash "$REFERENCE_FINISH_HEIGHT")}"

start_ms="$(now_ms)"
set +e
DOCKER_PROOF_VOLUME="$VOLUME" SECP256K1_BACKEND="$BACKEND" PEERS="$PEER" SYNC_TIMING=1 \
  PARALLEL_BLOCK_DOWNLOADS="$PREFETCH_DEPTH" PAR_SCRIPT_VERIFY=1 \
  "${DOCKER_COMPOSE[@]}" run --rm --no-deps -e SYNC_TIMING=1 tsbitnode-sync-proof \
    node dist/cli/syncRunner.js \
      --datadir /data \
      --peers "$PEER" \
      --blocks-target "$TARGET" \
      --blocks-max "$BLOCKS_MAX" >"$LOG_TMP" 2>&1
sync_exit=${PIPESTATUS[0]}
set -e
end_ms="$(now_ms)"
if [ "$sync_exit" -ne 0 ]; then
  tail -n 120 "$LOG_TMP" >&2 || true
fi

set +e
DOCKER_PROOF_VOLUME="$VOLUME" SECP256K1_BACKEND="$BACKEND" PEERS="$PEER" \
  "${DOCKER_COMPOSE[@]}" run --rm --no-deps tsbitnode-sync-proof \
    node dist/cli/nativeStatus.js --datadir /data >"$STATUS_TMP"
status_exit=$?
set -e

mkdir -p "$(dirname "$RESULT")"

RESULT_PATH="$RESULT" \
STATUS_PATH="$STATUS_TMP" \
SYNC_EXIT="$sync_exit" \
STATUS_EXIT="$status_exit" \
LOG_PATH="$LOG_TMP" \
START_MS="$start_ms" \
END_MS="$end_ms" \
TARGET="$TARGET" \
BLOCKS_MAX="$BLOCKS_MAX" \
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
    return {
        5000: "baseline_5k",
        10000: "diagnostic_10k",
        50000: "shakedown_50k",
        100000: "performance_100k",
    }.get(target, "local_reference")


def supporting_p2p_kind(target):
    return {
        5000: "baseline_5k_p2p",
        10000: "diagnostic_10k_p2p",
        50000: "shakedown_50k_p2p",
        100000: "performance_100k_p2p",
    }.get(target, "local_reference_p2p")


def sync_timing_summary(log_path: Path, elapsed_ms: int) -> dict:
    stage_totals: dict[str, float] = {
        "p2p_fetch": 0,
        "block_parse_validate": 0,
        "utxo_load": 0,
        "script_verify": 0,
        "utxo_apply": 0,
        "commit": 0,
        "block_connect_store_commit": 0,
    }
    slow_blocks: list[dict] = []
    timing_count = 0
    try:
        lines = log_path.read_text(errors="replace").splitlines()
    except OSError:
        lines = []
    for line in lines:
        if "SYNC_TIMING " not in line:
            continue
        _, raw = line.split("SYNC_TIMING ", 1)
        try:
            event = json.loads(raw)
        except json.JSONDecodeError:
            continue
        timings = event.get("timings_ms")
        if not isinstance(timings, dict):
            continue
        timing_count += 1
        for stage, value in timings.items():
            if isinstance(value, (int, float)):
                stage_totals[stage] = stage_totals.get(stage, 0) + float(value)
        block_ms = timings.get("block_connect_store_commit")
        height = event.get("height")
        if isinstance(block_ms, (int, float)) and isinstance(height, int):
            slow_blocks.append(
                {
                    "height": height,
                    "ms": int(round(block_ms)),
                    "block_hash": event.get("block_hash"),
                }
            )
    connect_total = stage_totals.get("block_connect_store_commit", 0)
    if timing_count > 0:
        stage_totals["p2p_fetch"] = max(0, elapsed_ms - int(round(connect_total)))
    else:
        stage_totals["block_connect_store_commit"] = elapsed_ms
    rounded = {
        stage: int(round(value))
        for stage, value in stage_totals.items()
        if int(round(value)) != 0 or stage in {
            "p2p_fetch",
            "block_parse_validate",
            "utxo_load",
            "script_verify",
            "utxo_apply",
            "commit",
            "block_connect_store_commit",
        }
    }
    slow_blocks = sorted(slow_blocks, key=lambda item: item["ms"], reverse=True)[:10]
    return {
        "telemetry_schema": "benchmark.telemetry_tick.v1",
        "total_ms": elapsed_ms,
        "stage_totals_ms": rounded,
        "timing_event_count": timing_count,
        "slow_blocks": slow_blocks,
    }


status_path = Path(os.environ["STATUS_PATH"])
try:
    status = json.loads(status_path.read_text())
except (OSError, json.JSONDecodeError):
    status = {}


sync_exit = as_int(os.environ.get("SYNC_EXIT"))
status_exit = as_int(os.environ.get("STATUS_EXIT"))
start_ms = as_int(os.environ.get("START_MS"))
end_ms = as_int(os.environ.get("END_MS"))
elapsed_ms = max(0, end_ms - start_ms)
timing = sync_timing_summary(Path(os.environ["LOG_PATH"]), elapsed_ms)
target = as_int(os.environ.get("TARGET"), 5000)
validated_height = as_int(status.get("validated_height"), -1)
stored_block_height = as_int(status.get("stored_block_height"), -1)
current_blocker = status.get("current_blocker")

failures = []
if sync_exit != 0:
    failures.append(f"sync_exit={sync_exit}")
if status_exit != 0:
    failures.append(f"status_exit={status_exit}")
if validated_height < target:
    failures.append(f"validated_height<{target}")
if current_blocker is not None:
    failures.append("current_blocker_present")
if not os.environ.get("REFERENCE_START_HASH"):
    failures.append("reference_start_hash_missing")
if not os.environ.get("REFERENCE_FINISH_HASH"):
    failures.append("reference_finish_hash_missing")

passed = not failures
captured_at = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
block_count = as_int(status.get("block_count"), max(0, validated_height + 1))

doc = {
    "benchmark_contract_version": 1,
    "benchmark_kind": supporting_p2p_kind(target),
    "benchmark_gate": supporting_gate(target),
    "benchmark_lane": supporting_p2p_kind(target),
    "utxo_accounting_policy": "core_spendable_v1",
    "target_label": target_label(target),
    "target_height": target,
    "header_target_height": target,
    "category": "local_reference_sync",
    "result": "passed" if passed else "failed",
    "failures": failures,
    "implementation": "TypeScriptNode",
    "port": "typescript",
    "node": "TypeScriptNode",
    "runtime_surface": "docker",
    "peer_mode": "local_reference",
    "byte_source": "local_reference_p2p",
    "proof_mode": "p2p_sync",
    "peer": os.environ["PEER"],
    "docker_volume": os.environ.get("VOLUME", "tsbitnode_proof_data"),
    "datadir": "/data",
    "chain": status.get("chain", "testnet4"),
    "binary_gate_status": "not_attempted",
    "local_reference_status": "target_reached" if passed else "target_not_reached",
    "telemetry_schema": "benchmark.telemetry_tick.v1",
    "reference_start_height": as_int(os.environ.get("REFERENCE_START_HEIGHT"), 0),
    "reference_start_hash": os.environ.get("REFERENCE_START_HASH") or None,
    "reference_finish_height": as_int(os.environ.get("REFERENCE_FINISH_HEIGHT"), target),
    "reference_finish_hash": os.environ.get("REFERENCE_FINISH_HASH") or None,
    "sync_exit_code": sync_exit,
    "status_exit_code": status_exit,
    "sync_status": status.get("sync_status"),
    "validated_height": validated_height,
    "validated_hash": status.get("validated_hash"),
    "header_height": as_int(status.get("header_height"), 0),
    "header_hash": status.get("header_hash"),
    "stored_block_height": stored_block_height,
    "stored_block_hash": status.get("stored_block_hash"),
    "blocks_fetched": stored_block_height if stored_block_height >= 0 else max(0, block_count - 1),
    "blocks_connected": max(0, validated_height),
    "current_blocker": current_blocker,
    "chainstate_backend": status.get("chainstate_backend", "rocksdb"),
    "chainstate_backend_path": status.get("chainstate_backend_path", "/data/chainstate-rocksdb"),
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
    "pipeline_timing_summary": timing,
    "timing_summary": timing,
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
