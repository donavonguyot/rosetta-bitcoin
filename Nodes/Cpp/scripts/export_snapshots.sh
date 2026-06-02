#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="${BUILD:-$ROOT/build}"
BIN="$BUILD/cpbitnode-export-snapshots"

if [[ ! -x "$BIN" ]]; then
  cmake -S "$ROOT" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release >/dev/null
  cmake --build "$BUILD" --target cpbitnode-export-snapshots >/dev/null
fi

exec "$BIN" "$@"
