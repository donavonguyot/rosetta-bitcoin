# cpbitnode (Cpp)

C++20 Bitcoin full node (`cpbitnode`), sibling to the other implementations under `../`.

## Status

Follower implementation: P2P, sync, consensus validation, mempool, metrics HTTP, and offline unit tests. **Python is the scout** — Cpp follows discovered consensus blockers with focused C++ regression tests.

Cpp's Core compliance path is **RocksDB-only**. Native mode must use RocksDB for
headers, block index, sync state, validated tip, UTXO, undo, metadata, blocker
state, and status truth. SQLite is legacy/dev only and is not allowed in the
RocksDB compliance path.

Quality bar (current):

- all normal unit tests pass (`ctest`);
- RocksDB/native secp256k1 builds pass (`CPBITNODE_USE_ROCKSDB=ON`, `CPBITNODE_USE_NATIVE_SECP256K1=ON`), with native status/sync/proof targets linked through a SQLite-free RocksDB library;
- new consensus fixes include focused regression tests;
- no silent consensus skips — stop honestly on missing rules;
- live sync progress is the primary forward gate.

Coverage is **monitored, not gated**: `./scripts/coverage_report.sh` prints gcovr line/branch totals for `src/` without failing CI. Thresholds can be ratcheted later via `THRESHOLD_LINE` / `THRESHOLD_BRANCH`.

## Requirements

- C++20 compiler (Clang 15+ or GCC 12+)
- CMake 3.20+
- SQLite 3 development library (`libsqlite3-dev` on Debian/Ubuntu) for legacy/dev builds only
- RocksDB and libsecp256k1 for Cpp Core proof builds (`librocksdb-dev`, `libsecp256k1-dev`)

Default builds keep legacy SQLite tooling available. Core Node proof builds
intentionally use RocksDB and libsecp256k1; the native `cpbitnode-db`,
`cpbitnode-sync`, and `cpbitnode-storage-proof` executables are linked through a
SQLite-free native library.

## Build

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
```

Binaries: `build/cpbitnode`, `build/cpbitnode-db`, `build/cpbitnode-healthcheck`, `build/cpbitnode-export-snapshots`, `build/cpbitnode-sync`, `build/cpbitnode_tests`.

Native proof build:

```bash
cmake -S . -B build-core-native -DCMAKE_BUILD_TYPE=Release \
  -DCPBITNODE_USE_ROCKSDB=ON \
  -DCPBITNODE_USE_NATIVE_SECP256K1=ON
cmake --build build-core-native
ctest --test-dir build-core-native --output-on-failure
```

## Test

```bash
ctest --test-dir build --output-on-failure
# or
./build/cpbitnode_tests
```

## Coverage (report-only)

Build with instrumentation, run tests, and print gcovr summary for `src/`:

```bash
./scripts/coverage_report.sh
```

Optional ratchet thresholds (defaults are report-only — thresholds `0`):

```bash
THRESHOLD_LINE=80 THRESHOLD_BRANCH=70 ./scripts/coverage_report.sh
```

CLI binaries under `cli/` are smoke-tested only and are outside the coverage report.

## Sync (local Bitcoin Core testnet4)

Use an isolated datadir (`./data-cpp` by default). **One writer per datadir** — if sync exits with "Another cpbitnode-sync holds this datadir", inspect or stop the other process before retrying.

Local reference node (Bitcoin Core testnet4):

```bash
# Peer: 127.0.0.1:48333
MAX_OUTBOUND_PEERS=1 SKIP_GETADDR=1 ./build/cpbitnode-sync \
  --datadir ./data-cpp \
  --peers 127.0.0.1:48333 \
  --blocks-target 1000 \
  --blocks-max 200
```

After headers cover your target height, add `--no-header-refresh` for block-only batches:

```bash
MAX_OUTBOUND_PEERS=1 SKIP_GETADDR=1 ./build/cpbitnode-sync \
  --datadir ./data-cpp \
  --peers 127.0.0.1:48333 \
  --blocks-target 1000 \
  --blocks-max 200 \
  --no-header-refresh
```

Check progress:

```bash
./build-core-native/cpbitnode-db --datadir ./data-cpp --chainstate-backend rocksdb
```

Connect-only pass over stored blocks (no network):

```bash
./build/cpbitnode-sync --datadir ./data-cpp --connect-only
```

### Follower posture

- Use PythonNode blocker facts (height, tx, input, missing rule, fixture) as the work queue.
- Implement the same rule independently in C++; add a focused test per blocker fix.
- Do not skip unknown script templates to increase height.

## Run (daemon stub)

```bash
./build/cpbitnode --datadir ./data-cpp
./build/cpbitnode-db --datadir ./data-cpp
./build/cpbitnode-healthcheck --datadir ./data-cpp
```

Defaults: `CHAIN=testnet4`, data dir `./data-cpp`, database `cpbitnode.db`.

## Partial Native Proofs

```bash
./build-core-native/cpbitnode-storage-proof \
  --datadir /tmp/cpbitnode-storage-proof \
  --chainstate-backend rocksdb \
  --proof-path ../../NodeCore/conformance/results/cpp_rocksdb_codec_v2_storage_2026-06-02.json

./build-core-native/cpbitnode-blocker-inspect --height 739
```

`cpbitnode-db` emits shared status contract fields, including `validated_height`,
`validated_hash`, `chainstate_backend`, `chainstate_utxo_count`,
`native_crypto_backend`, `current_blocker`, `active_writer_pid`, and
`lock_status`. In RocksDB builds, this status path reads from RocksDB state and
refuses a legacy `cpbitnode.db` artifact in the datadir.

## Docker

```bash
make docker-config
make docker-cpp-rocksdb-storage-proof
make docker-cpp-sync-supervisor
make docker-cpp-sync-status
make docker-cpp-sync-stop
make docker-cpp-sync-resume
```

## SQLite

Uses **system SQLite** via CMake for legacy/dev metadata/header/block-index state.
That path is explicitly non-compliant. Cpp Core mode is RocksDB-only, and the
RocksDB compliance executables must not open, create, or require `cpbitnode.db`.

## Intentionally limited in CI

- Live testnet4 sync (offline unit tests only)
- Full healthcheck live peer/mempool counts when node is not running (reads tracker DB)

## Schema

`SCHEMA_VERSION = 7` (canonical with PythonNode `pybitnode/db/schema.py`).
