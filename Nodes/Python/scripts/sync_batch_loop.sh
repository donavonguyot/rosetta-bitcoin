#!/usr/bin/env bash
# Wrapper: portable fcntl orchestration lives in scripts/sync_batch_loop.py (macOS lacks util-linux flock(1)).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "${PYTHON:-"$ROOT/.venv/bin/python"}" "$ROOT/scripts/sync_batch_loop.py" "$@"
