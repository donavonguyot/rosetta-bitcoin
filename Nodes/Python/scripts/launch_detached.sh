#!/usr/bin/env bash
# Portable detached launch (macOS lacks setsid(1); Linux has it).
# Usage: ./scripts/launch_detached.sh <command> [args...]
set -euo pipefail
if [[ $# -lt 1 ]]; then
  echo "usage: launch_detached.sh <command> [args...]" >&2
  exit 1
fi
if command -v setsid >/dev/null 2>&1; then
  setsid nohup "$@" </dev/null &
else
  nohup "$@" </dev/null &
fi
echo $!
