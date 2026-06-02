#!/usr/bin/env bash
set -euo pipefail

# Compare LevelDB and RocksDB by replaying stored blocks from a quiescent source datadir.
# Required:
#   SOURCE_DATA_DIR=/path/to/stopped/data-java
# Optional:
#   WORK_DIR=./benchmark-chainstate
#   BLOCKS_MAX=500

SOURCE_DATA_DIR="${SOURCE_DATA_DIR:-}"
WORK_DIR="${WORK_DIR:-./benchmark-chainstate}"
BLOCKS_MAX="${BLOCKS_MAX:-500}"

if [[ -z "$SOURCE_DATA_DIR" ]]; then
  echo "error: SOURCE_DATA_DIR is required" >&2
  exit 2
fi
if [[ ! -d "$SOURCE_DATA_DIR" ]]; then
  echo "error: SOURCE_DATA_DIR is not a directory: $SOURCE_DATA_DIR" >&2
  exit 2
fi
if [[ -e "$SOURCE_DATA_DIR/.jbitnode.lock" ]]; then
  echo "error: source datadir appears locked; benchmark only quiescent copies" >&2
  exit 2
fi
mkdir -p "$WORK_DIR"

run_backend() {
  local backend="$1"
  local output_dir="$WORK_DIR/$backend-replay"
  local log="$WORK_DIR/$backend.log"
  local summary before after connected elapsed size_bytes commit_ms utxo_load_ms utxo_apply_ms commit_avg_ms

  rm -rf "$output_dir"

  SOURCE_DATA_DIR="$SOURCE_DATA_DIR" REPLAY_BACKEND="$backend" \
    REPLAY_OUTPUT_DIR="$output_dir" BLOCKS_MAX="$BLOCKS_MAX" \
    make -s java-node-chainstate-backend-replay >"$log" 2>&1 || true

  summary="$(sed -n 's/^backend=//p' "$log" | tail -1)"
  before="$(field "$summary" height_before)"
  after="$(field "$summary" height_after)"
  connected="$(field "$summary" blocks_connected)"
  elapsed="$(field "$summary" rebuild_elapsed_ms)"
  size_bytes="$(field "$summary" database_size_bytes)"
  commit_ms="$(field "$summary" block_connect_store_commit_ms)"
  utxo_load_ms="$(field "$summary" utxo_load_ms)"
  utxo_apply_ms="$(field "$summary" utxo_apply_ms)"
  commit_avg_ms="$(field "$summary" commit_ms)"
  if [[ -z "$summary" ]]; then
    before=""
    after=""
    connected=""
    elapsed=""
    size_bytes=""
  fi

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$backend" "$before" "$after" "$connected" "$elapsed" "$size_bytes" \
    "${commit_ms:-}" "${utxo_load_ms:-}" "${utxo_apply_ms:-}" "${commit_avg_ms:-}" "$log"
}

field() {
  local line="$1"
  local key="$2"
  for item in $line; do
    if [[ "$item" == "$key="* ]]; then
      printf '%s' "${item#*=}"
      return
    fi
  done
}

echo "backend,height_before,height_after,blocks_connected,rebuild_elapsed_ms,database_size_bytes,block_connect_store_commit_avg_ms,utxo_load_avg_ms,utxo_apply_avg_ms,commit_avg_ms,log"
run_backend rocksdb
