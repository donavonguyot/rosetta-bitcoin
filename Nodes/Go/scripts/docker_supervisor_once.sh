#!/bin/sh
set -eu

STATUS="$(gobitnode-status --datadir "${DATA_DIR:-/data}" 2>/dev/null || true)"
VALIDATED="$(printf '%s' "$STATUS" | sed -n 's/.*"validated_height": *\([0-9][0-9]*\).*/\1/p' | head -1)"
HEADER="$(printf '%s' "$STATUS" | sed -n 's/.*"header_height": *\([0-9][0-9]*\).*/\1/p' | head -1)"
STORED="$(printf '%s' "$STATUS" | sed -n 's/.*"stored_block_height": *\([0-9][0-9]*\).*/\1/p' | head -1)"
SYNC="$(printf '%s' "$STATUS" | sed -n 's/.*"sync_status": *"\([^"]*\)".*/\1/p' | head -1)"

printf 'AGENT_LOOP_TICK_chatreport {"phase":"smoke","runtime_surface":"supervisor","peer_mode":"none","peer":"","validated_height":%s,"header_height":%s,"stored_block_height":%s,"sync_status":"%s","delta_since_last":0,"process_running":false,"current_blocker":null}\n' \
  "${VALIDATED:-0}" "${HEADER:-0}" "${STORED:-0}" "${SYNC:-starting}"
