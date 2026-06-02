#!/usr/bin/env bash
# Wrapper: batch orchestration lives in dist/scripts/syncBatchLoop.js (portable lock + RO polls).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec node "$ROOT/dist/scripts/syncBatchLoop.js" "$@"
