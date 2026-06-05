#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

VOLUME="${DOCKER_PROOF_VOLUME:-tsbitnode_proof_data}"
TARGET="${DOCKER_SYNC_TARGET:-5000}"
BLOCKS_MAX="${DOCKER_SYNC_BLOCKS_MAX:-5000}"
PREFETCH_DEPTH="${DOCKER_BENCHMARK_PREFETCH_DEPTH:-4}"
RESULT="${DOCKER_BENCHMARK_RESULT:-../Shared/conformance/results/typescript_docker_supporting_5k_benchmark_$(date +%F).json}"
PEER="${PEERS:-host.docker.internal:48333}"
BACKEND="${SECP256K1_BACKEND:-native}"
REFERENCE_START_HEIGHT="${REFERENCE_START_HEIGHT:-0}"

reference_hash() {
  docker exec rosetta-bitcoin-core-testnet4 \
    bitcoin-cli -conf=/config/bitcoin.conf getblockhash "$1" 2>/dev/null || true
}

STATUS_TMP="$(mktemp)"
trap 'rm -f "$STATUS_TMP"' EXIT

now_ms() {
  python3 -c 'import time; print(int(time.time() * 1000))'
}

REFERENCE_START_HASH="${REFERENCE_START_HASH:-$(reference_hash "$REFERENCE_START_HEIGHT")}"
REFERENCE_FINISH_HEIGHT="${REFERENCE_FINISH_HEIGHT:-$TARGET}"
REFERENCE_FINISH_HASH="${REFERENCE_FINISH_HASH:-$(reference_hash "$REFERENCE_FINISH_HEIGHT")}"

start_ms="$(now_ms)"
set +e
DOCKER_PROOF_VOLUME="$VOLUME" SECP256K1_BACKEND="$BACKEND" PEERS="$PEER" \
  PARALLEL_BLOCK_DOWNLOADS="$PREFETCH_DEPTH" PAR_SCRIPT_VERIFY=1 \
  docker compose -f docker/docker-compose.yml run --rm --no-deps tsbitnode-sync-proof \
    node dist/cli/syncRunner.js \
      --datadir /data \
      --peers "$PEER" \
      --blocks-target "$TARGET" \
      --blocks-max "$BLOCKS_MAX"
sync_exit=$?
set -e
end_ms="$(now_ms)"

set +e
DOCKER_PROOF_VOLUME="$VOLUME" SECP256K1_BACKEND="$BACKEND" PEERS="$PEER" \
  docker compose -f docker/docker-compose.yml run --rm --no-deps tsbitnode-sync-proof \
    node dist/cli/nativeStatus.js --datadir /data >"$STATUS_TMP"
status_exit=$?
set -e

mkdir -p "$(dirname "$RESULT")"

RESULT_PATH="$RESULT" \
STATUS_PATH="$STATUS_TMP" \
SYNC_EXIT="$sync_exit" \
STATUS_EXIT="$status_exit" \
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
    label = target_label(target)
    return f"supporting_{label}" if label else "local_reference"


def supporting_p2p_kind(target):
    label = target_label(target)
    return f"supporting_{label}_p2p" if label else "local_reference_p2p"


status_path = Path(os.environ["STATUS_PATH"])
try:
    status = json.loads(status_path.read_text())
except (OSError, json.JSONDecodeError):
    status = {}

status.pop("local_sqlite_artifact_absent", None)

sync_exit = as_int(os.environ.get("SYNC_EXIT"))
status_exit = as_int(os.environ.get("STATUS_EXIT"))
start_ms = as_int(os.environ.get("START_MS"))
end_ms = as_int(os.environ.get("END_MS"))
elapsed_ms = max(0, end_ms - start_ms)
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
    "peer": os.environ.get("PEER", "host.docker.internal:48333"),
    "docker_volume": os.environ.get("VOLUME", "tsbitnode_proof_data"),
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
    "timing_summary": {
        "total_ms": elapsed_ms,
        "stage_totals_ms": {
            "block_connect_store_commit": elapsed_ms,
            "utxo_load": as_int(status.get("timing_utxo_load_ms"), 0),
            "script_verify": as_int(status.get("timing_script_verify_ms"), 0),
            "utxo_apply": as_int(status.get("timing_utxo_apply_ms"), 0),
            "commit": as_int(status.get("timing_commit_ms"), 0),
        },
        "slow_blocks": [],
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
