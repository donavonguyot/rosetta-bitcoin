#!/usr/bin/env bash
# Build with coverage, run tests, print gcovr summary for src/.
# Defaults: report-only (THRESHOLD_LINE=0 THRESHOLD_BRANCH=0). Set thresholds to ratchet over time.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/build-cov}"
GCOV_OBJECT_DIR="${GCOV_OBJECT_DIR:-$BUILD_DIR/CMakeFiles/cpbitnode_lib.dir}"
GCOVR="${GCOVR:-$ROOT/.venv-cov/bin/gcovr}"

THRESHOLD_LINE="${THRESHOLD_LINE:-0}"
THRESHOLD_BRANCH="${THRESHOLD_BRANCH:-0}"

if [[ ! -x "$GCOVR" ]]; then
  python3 -m venv "$ROOT/.venv-cov"
  "$ROOT/.venv-cov/bin/pip" install -q gcovr
  GCOVR="$ROOT/.venv-cov/bin/gcovr"
fi

cmake -S "$ROOT" -B "$BUILD_DIR" -DENABLE_COVERAGE=ON -DCMAKE_BUILD_TYPE=Debug
cmake --build "$BUILD_DIR" -j"$(sysctl -n hw.ncpu 2>/dev/null || nproc)"
ctest --test-dir "$BUILD_DIR" --output-on-failure

echo "=== Coverage summary (src/) ==="
"$GCOVR" --root "$ROOT" --object-directory "$GCOV_OBJECT_DIR" \
  --merge-mode-functions merge-use-line-min \
  --gcov-ignore-errors source_not_found \
  --gcov-ignore-parse-errors all \
  --filter 'src/' \
  --txt-metric line --txt-metric branch \
  --fail-under-line "$THRESHOLD_LINE" --fail-under-branch "$THRESHOLD_BRANCH"

echo "=== Worst branch coverage (bottom 15) ==="
"$GCOVR" --root "$ROOT" --object-directory "$GCOV_OBJECT_DIR" \
  --merge-mode-functions merge-use-line-min \
  --gcov-ignore-errors source_not_found \
  --gcov-ignore-parse-errors all \
  --filter 'src/' --sort uncovered-percent --sort-branches --sort-reverse --txt \
  | head -20
