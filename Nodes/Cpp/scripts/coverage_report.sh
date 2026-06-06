#!/usr/bin/env bash
# Build with coverage, run a selected test lane, print gcovr summary for src/.
# Defaults to core-regression coverage and report-only thresholds.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/build-cov}"
GCOV_OBJECT_DIR="${GCOV_OBJECT_DIR:-$BUILD_DIR/CMakeFiles/cpbitnode_lib.dir}"
GCOVR="${GCOVR:-$ROOT/.venv-cov/bin/gcovr}"
SUITE="${SUITE:-core}"

THRESHOLD_LINE="${THRESHOLD_LINE:-0}"
THRESHOLD_BRANCH="${THRESHOLD_BRANCH:-0}"

usage() {
  cat <<'EOF'
usage: coverage_report.sh [--suite core|wire|runtime|all]

Default: --suite core. Coverage is report-only unless THRESHOLD_LINE or
THRESHOLD_BRANCH is set by the caller.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --suite)
      SUITE="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$SUITE" in
  core)
    CTEST_ARGS=(-L core-regression)
    SUITE_LABEL="core-regression"
    ;;
  wire)
    CTEST_ARGS=(-L wire-codec)
    SUITE_LABEL="wire-codec"
    ;;
  runtime)
    CTEST_ARGS=(-L runtime-smoke)
    SUITE_LABEL="runtime-smoke"
    ;;
  all)
    CTEST_ARGS=()
    SUITE_LABEL="all CTest lanes"
    ;;
  *)
    echo "error: unsupported suite '$SUITE'" >&2
    usage >&2
    exit 2
    ;;
esac

if [[ ! -x "$GCOVR" ]]; then
  python3 -m venv "$ROOT/.venv-cov"
  "$ROOT/.venv-cov/bin/pip" install -q gcovr
  GCOVR="$ROOT/.venv-cov/bin/gcovr"
fi

cmake -S "$ROOT" -B "$BUILD_DIR" \
  -DENABLE_COVERAGE=ON \
  -DCPBITNODE_USE_ROCKSDB=ON \
  -DCPBITNODE_USE_NATIVE_SECP256K1=ON \
  -DCMAKE_BUILD_TYPE=Debug
cmake --build "$BUILD_DIR" -j"$(sysctl -n hw.ncpu 2>/dev/null || nproc)"
echo "=== Running coverage suite: $SUITE_LABEL ==="
ctest --test-dir "$BUILD_DIR" "${CTEST_ARGS[@]}" --output-on-failure

echo "=== Coverage summary (src/, suite: $SUITE_LABEL) ==="
"$GCOVR" --root "$ROOT" --object-directory "$GCOV_OBJECT_DIR" \
  --merge-mode-functions merge-use-line-min \
  --gcov-ignore-errors source_not_found \
  --gcov-ignore-parse-errors all \
  --filter 'src/' \
  --txt-metric line --txt-metric branch \
  --fail-under-line "$THRESHOLD_LINE" --fail-under-branch "$THRESHOLD_BRANCH"

echo "=== Worst branch coverage (bottom 15, suite: $SUITE_LABEL) ==="
"$GCOVR" --root "$ROOT" --object-directory "$GCOV_OBJECT_DIR" \
  --merge-mode-functions merge-use-line-min \
  --gcov-ignore-errors source_not_found \
  --gcov-ignore-parse-errors all \
  --filter 'src/' --sort uncovered-percent --sort-branches --sort-reverse --txt \
  | head -20
