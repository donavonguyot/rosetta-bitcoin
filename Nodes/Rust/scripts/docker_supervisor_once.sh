#!/usr/bin/env sh
set -eu

STATUS_JSON="$(rsbitnode status --datadir "${DATA_DIR:-/data}" --runtime-surface supervisor)"

validated_height="$(printf '%s' "$STATUS_JSON" | sed -n 's/.*"validated_height": \([0-9][0-9]*\).*/\1/p' | head -1)"
header_height="$(printf '%s' "$STATUS_JSON" | sed -n 's/.*"header_height": \([0-9][0-9]*\).*/\1/p' | head -1)"
stored_block_height="$(printf '%s' "$STATUS_JSON" | sed -n 's/.*"stored_block_height": \([0-9][0-9]*\).*/\1/p' | head -1)"
sync_status="$(printf '%s' "$STATUS_JSON" | sed -n 's/.*"sync_status": "\([^"]*\)".*/\1/p' | head -1)"

printf 'AGENT_LOOP_TICK_chatreport {"phase":"smoke","runtime_surface":"supervisor","peer_mode":"none","peer":"","validated_height":%s,"header_height":%s,"stored_block_height":%s,"sync_status":"%s","delta_since_last":0,"process_running":false,"current_blocker":null}\n' \
  "${validated_height:-0}" \
  "${header_height:-0}" \
  "${stored_block_height:-0}" \
  "${sync_status:-starting}"
