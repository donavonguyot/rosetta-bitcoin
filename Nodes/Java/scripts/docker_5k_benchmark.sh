#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

REFERENCE_TOPOLOGY_ENV="${REFERENCE_TOPOLOGY_ENV:-../Shared/docker/reference_topology.env}"
# shellcheck source=/dev/null
. "$REFERENCE_TOPOLOGY_ENV"
DOCKER_COMPOSE=(docker compose --env-file "$REFERENCE_TOPOLOGY_ENV" -f docker/docker-compose.yml)

VOLUME="${DOCKER_PROOF_VOLUME:-jbitnode_proof_data}"
PRESERVE_PROOF_VOLUME="${PRESERVE_PROOF_VOLUME:-0}"
TARGET="${DOCKER_BENCHMARK_TARGET:-5000}"
BLOCKS_MAX="${DOCKER_BENCHMARK_BLOCKS_MAX:-5000}"
HEADERS_MAX="${DOCKER_BENCHMARK_HEADERS_MAX:-5000}"
HEADER_BATCHES_MAX="${DOCKER_BENCHMARK_HEADER_BATCHES_MAX:-50}"
PREFETCH_DEPTH="${DOCKER_BENCHMARK_PREFETCH_DEPTH:-4}"
RESULT="${DOCKER_BENCHMARK_RESULT:-.benchmark-results/java_docker_baseline_5k_benchmark_$(date +%F).json}"
PEER="${PEERS:-${REFERENCE_P2P_PEER:?REFERENCE_P2P_PEER missing}}"
export PEER
BACKEND="${SECP256K1_BACKEND:-native}"
REFERENCE_START_HEIGHT="${REFERENCE_START_HEIGHT:-0}"
POLL_SEC="${POLL_SEC:-10}"
CHECK_SEC="${CHECK_SEC:-1}"
CONTAINER_NAME="${CONTAINER_NAME:-jbitnode-sync-proof-run}"
PROGRESS_INTERVAL="${PROGRESS_INTERVAL:-250}"

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

if [[ "$PRESERVE_PROOF_VOLUME" != "1" ]]; then
  docker volume rm -f "$VOLUME" >/dev/null 2>&1 || true
fi

start_ms="$(now_ms)"
run_id="java-$(case "$TARGET" in 5000) echo baseline_5k ;; 50000) echo shakedown_50k ;; 100000) echo performance_100k ;; *) echo local_reference ;; esac)-$start_ms"

status_command_json() {
  DOCKER_PROOF_VOLUME="$VOLUME" SECP256K1_BACKEND="$BACKEND" \
    "${DOCKER_COMPOSE[@]}" run --rm --no-deps jbitnode-sync-proof com.jbitnode.cli.DbStatus 2>/dev/null || echo '{}'
}

progress_json() {
  docker logs "$CONTAINER_NAME" 2>/dev/null | python3 -c 'import json, sys
latest = None
for raw in sys.stdin:
    if "sync_progress_json=" not in raw:
        continue
    payload = raw.split("sync_progress_json=", 1)[1].strip()
    try:
        latest = json.loads(payload)
    except json.JSONDecodeError:
        continue
print(json.dumps(latest or {}))'
}

status_json() {
  if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    progress_json
  else
    status_command_json
  fi
}

field() {
  python3 -c "import json,sys; d=json.load(sys.stdin); $1" 2>/dev/null || echo "?"
}

benchmark_gate() {
  case "$TARGET" in
    5000) echo "baseline_5k" ;;
    10000) echo "diagnostic_10k" ;;
    50000) echo "shakedown_50k" ;;
    100000) echo "performance_100k" ;;
    *) echo "local_reference" ;;
  esac
}

emit_benchmark_tick() {
  local json="$1" last_height="$2" phase="$3" event="${4:-heartbeat}" process_running="${5:-1}"
  printf '%s\n' "$json" | \
    TARGET_BLOCK_HEIGHT="$TARGET" BENCHMARK_GATE="$(benchmark_gate)" \
    BENCHMARK_STARTED_MS="$start_ms" BENCHMARK_LAST_HEIGHT="$last_height" \
    BENCHMARK_PHASE="$phase" BENCHMARK_EVENT="$event" BENCHMARK_RUN_ID="$run_id" \
    BENCHMARK_PROCESS_RUNNING="$process_running" POLL_SEC="$POLL_SEC" \
    python3 scripts/emit_benchmark_telemetry_tick.py
}

log_tick() {
  local line
  line="$(emit_benchmark_tick "$@")"
  printf '%s\n' "$line" | tee -a "$RUN_LOG_TMP"
}

log_product_progress() {
  local json="$1"
  printf '%s\n' "$json" | python3 -c 'import json, sys
raw = sys.stdin.read().strip()
if not raw:
    raise SystemExit
try:
    payload = json.loads(raw)
except json.JSONDecodeError:
    raise SystemExit
if payload:
    print("rb.port_progress " + json.dumps(payload, sort_keys=True))' | tee -a "$RUN_LOG_TMP"
}

: > "$RUN_LOG_TMP"
log_tick '{}' 0 startup run_started 1
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
set +e
DOCKER_PROOF_VOLUME="$VOLUME" SECP256K1_BACKEND="$BACKEND" HEADERS_MAX="$HEADERS_MAX" \
  HEADER_BATCHES_MAX="$HEADER_BATCHES_MAX" BLOCKS_MAX="$BLOCKS_MAX" \
  TARGET_BLOCK_HEIGHT="$TARGET" \
  "${DOCKER_COMPOSE[@]}" run -d --name "$CONTAINER_NAME" --no-deps \
    -e PAR_SCRIPT_VERIFY=1 \
    -e SYNC_TIMING=1 \
    -e PROGRESS_JSON=1 \
    -e PROGRESS_INTERVAL="$PROGRESS_INTERVAL" \
    -e BLOCK_PREFETCH_DEPTH="$PREFETCH_DEPTH" \
    -e ROCKSDB_DISABLE_WAL=0 \
    jbitnode-sync-proof >/dev/null
start_exit=$?
set -e
if [[ "$start_exit" -eq 0 ]]; then
  log_tick '{}' 0 startup container_started 1
  log_tick '{}' 0 startup node_started 1
  last_height=0
  last_report="$(date +%s)"
  first_peer_byte=0
  first_block_connected=0
  while docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; do
    sleep "$CHECK_SEC"
    now_report="$(date +%s)"
    json="$(status_json)"
    h="$(echo "$json" | field "print(d.get('validated_height','?'))")"
    header="$(echo "$json" | field "print(d.get('header_height','?'))")"
    previous_height="$last_height"
    if [[ "$h" =~ ^[0-9]+$ ]]; then
      last_height="$h"
    fi
    log_product_progress "$json" || true
    if [[ "$first_peer_byte" == "0" ]] && [[ "$header" =~ ^[0-9]+$ ]] && (( header > 0 )); then
      log_tick "$json" "$previous_height" peer_connect first_peer_byte 1
      first_peer_byte=1
    fi
    if [[ "$first_block_connected" == "0" ]] && [[ "$h" =~ ^[0-9]+$ ]] && (( h > 0 )); then
      log_tick "$json" "$previous_height" block_connect first_block_connected 1
      first_block_connected=1
    fi
    if (( now_report - last_report >= POLL_SEC )); then
      log_tick "$json" "$previous_height" heartbeat heartbeat 1
      last_report="$now_report"
    fi
  done
  sync_exit="$(docker inspect "$CONTAINER_NAME" --format '{{.State.ExitCode}}' 2>/dev/null || echo 125)"
  status_command_json >"$STATUS_TMP" 2>&1
  final_json="$(cat "$STATUS_TMP")"
  final_height="$(echo "$final_json" | field "print(d.get('validated_height','?'))")"
  if [[ "$final_height" =~ ^[0-9]+$ ]] && (( final_height >= TARGET )); then
    log_tick "$final_json" "$last_height" complete target_reached 0
  fi
  log_tick "$final_json" "$last_height" complete run_finished 0
  docker logs "$CONTAINER_NAME" 2>&1 | tee -a "$RUN_LOG_TMP" || true
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
else
  sync_exit="$start_exit"
  echo '{}' >"$STATUS_TMP"
  log_tick '{}' 0 failed run_finished 0
fi
end_ms="$(now_ms)"

set +e
DOCKER_PROOF_VOLUME="$VOLUME" SECP256K1_BACKEND="$BACKEND" \
  "${DOCKER_COMPOSE[@]}" run --rm --no-deps \
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


def parse_json_map(value):
    if not value:
        return {}
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError:
        return {}
    if not isinstance(parsed, dict):
        return {}
    return {str(key): as_int(raw) for key, raw in parsed.items()}


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
                    "tx_count": as_int(pairs.get("tx_count")),
                    "vin_count": as_int(pairs.get("vin_count")),
                    "vout_count": as_int(pairs.get("vout_count")),
                    "script_input_count": as_int(pairs.get("script_input_count")),
                    "input_shape_counts": parse_json_map(pairs.get("input_shape_counts")),
                    "spent_prevout_script_types": parse_json_map(
                        pairs.get("spent_prevout_script_types")
                    ),
                    "output_script_types": parse_json_map(pairs.get("output_script_types")),
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


def telemetry_summary(path):
    ticks = []
    prefix = "benchmark.telemetry_tick "
    for raw_line in path.read_text(errors="replace").splitlines():
        marker = raw_line.find(prefix)
        if marker < 0:
            continue
        try:
            tick = json.loads(raw_line[marker + len(prefix) :])
        except json.JSONDecodeError:
            continue
        if isinstance(tick, dict):
            ticks.append(tick)
    lifecycle = {}
    phase_counts = {}
    stall_counts = {}
    max_gap = 0
    last_monotonic = None
    for tick in sorted(ticks, key=lambda item: as_int(item.get("monotonic_ms"), 0)):
        event = str(tick.get("event") or "")
        monotonic = as_int(tick.get("monotonic_ms"), 0)
        if event and event not in lifecycle:
            lifecycle[event] = monotonic
        phase = str(tick.get("phase") or "")
        stall = str(tick.get("stall_class") or "")
        phase_counts[phase] = phase_counts.get(phase, 0) + 1
        stall_counts[stall] = stall_counts.get(stall, 0) + 1
        if last_monotonic is not None:
            max_gap = max(max_gap, monotonic - last_monotonic)
        last_monotonic = monotonic
    required = {
        "run_started",
        "container_started",
        "node_started",
        "first_peer_byte",
        "first_block_connected",
        "target_reached",
        "run_finished",
    }
    quality = "clean" if ticks and required.issubset(lifecycle) else ("sparse" if ticks else "missing")
    return {
        "telemetry_quality": quality,
        "tick_count": len(ticks),
        "heartbeat_max_gap_ms": max_gap,
        "lifecycle_markers": lifecycle,
        "phase_counts": phase_counts,
        "stall_class_counts": stall_counts,
        "slow_blocks": [],
    }


status_raw = Path(os.environ["STATUS_PATH"]).read_text(errors="replace")
try:
    status = extract_json_object(status_raw)
except json.JSONDecodeError:
    status = {}

_, stage_totals, slow_blocks, exit_summary, log_blocker = parse_run_log(
    Path(os.environ["RUN_LOG_PATH"])
)
telemetry = telemetry_summary(Path(os.environ["RUN_LOG_PATH"]))

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
for stage in (
    "p2p_fetch",
    "block_parse_validate",
    "utxo_load",
    "script_verify",
    "utxo_apply",
    "commit",
    "block_connect_store_commit",
):
    stage_totals.setdefault(stage, 0)

timing_summary = {
    "total_ms": elapsed_ms,
    "stage_totals_ms": stage_totals,
    "slow_blocks": slow_blocks,
}

doc = {
    "benchmark_contract_version": 1,
    "benchmark_kind": supporting_p2p_kind(target),
    "benchmark_gate": supporting_gate(target),
    "benchmark_lane": supporting_p2p_kind(target),
    "telemetry_schema": "benchmark.telemetry_tick.v1",
    "utxo_accounting_policy": "core_spendable_v1",
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
    "peer": os.environ["PEER"],
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
    "timing_summary": timing_summary,
    "pipeline_timing_summary": timing_summary,
    "telemetry_summary": telemetry,
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
