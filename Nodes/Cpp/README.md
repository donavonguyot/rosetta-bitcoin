# cpbitnode (Cpp)

C++20 Bitcoin full node (`cpbitnode`), sibling to the other implementations under `../`.

## Status

Follower implementation: P2P, sync, consensus validation, mempool, metrics HTTP,
and offline unit tests. Cpp inherits known consensus work from the Shared rule
ledger and script corpus, then proves it with focused C++ regression tests and
port-owned corpus artifacts.

Cpp's Core compliance path is **RocksDB-only**. Native mode must use RocksDB for
headers, block index, sync state, validated tip, UTXO, undo, metadata, blocker
state, and status truth.

Quality bar (current):

- all normal unit tests pass (`ctest`);
- RocksDB/native secp256k1 builds pass (`CPBITNODE_USE_ROCKSDB=ON`, `CPBITNODE_USE_NATIVE_SECP256K1=ON`), with native status/sync/proof targets linked through one RocksDB library;
- known consensus rules are implemented from the Shared corpus/rule ledger before
  live-sync blocker discovery;
- new consensus fixes include focused regression tests;
- no silent consensus skips — stop honestly on missing rules;
- live sync progress is the primary forward gate.

Coverage and lane tooling are local diagnostics only. Project's cross-port test
posture starts with the normal product test suite and critical-domain evidence,
not Cpp's historical breadth or global line/branch percentages.

## Requirements

- C++20 compiler (Clang 15+ or GCC 12+)
- CMake 3.20+
- RocksDB and libsecp256k1 (`librocksdb-dev`, `libsecp256k1-dev`)

Default builds are RocksDB-native. `CPBITNODE_USE_ROCKSDB=OFF` is rejected at
configure time; `cpbitnode-db`, `cpbitnode-sync`, and
`cpbitnode-storage-proof` all read and write native state.

## Build

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
  -DCPBITNODE_USE_ROCKSDB=ON \
  -DCPBITNODE_USE_NATIVE_SECP256K1=ON
cmake --build build
```

Binaries: `build/cpbitnode`, `build/cpbitnode-db`, `build/cpbitnode-healthcheck`, `build/cpbitnode-sync`, `build/cpbitnode-storage-proof`, `build/cpbitnode-blocker-inspect`, `build/cpbitnode_tests`.

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

`make test` / full `ctest` is the normal product-node suite. Cpp also keeps
historical local lanes for maintainers who need narrower diagnostics:

```bash
make test-core      # consensus, script, native crypto, RocksDB, block connect
make test-wire      # wire primitives, messages, compact block, JSON, params
make test-runtime   # CLI/settings/transport/sync hot-path smoke

ctest --test-dir build -L core-regression --output-on-failure
ctest --test-dir build -L wire-codec --output-on-failure
ctest --test-dir build -L runtime-smoke --output-on-failure

./build/cpbitnode_tests --suite core
./build/cpbitnode_tests --suite wire
./build/cpbitnode_tests --suite runtime
```

The lane commands are not Project par and are not a template for every other
port's readiness bar.

## Optional local coverage

Coverage remains available for Cpp maintainers who need local archaeology:

```bash
./scripts/coverage_report.sh --suite core
```

```bash
./scripts/coverage_report.sh --suite all
```

Project does not auto-promote Cpp coverage commands and does not use global
Cpp line/branch thresholds as readiness. CLI binaries under `cli/` are
smoke-tested only and are outside the coverage report. Serving, mempool, and
deeper P2P manager coverage remain future runtime work, not prerequisites for
the benchmark suite.

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

Defaults: `CHAIN=testnet4`, data dir `./data-cpp`, chainstate backend `rocksdb`.

## Partial Native Proofs

```bash
./build-core-native/cpbitnode-storage-proof \
  --datadir /tmp/cpbitnode-storage-proof \
  --chainstate-backend rocksdb \
  --proof-path ../Shared/conformance/results/cpp_rocksdb_codec_v2_storage.json

./build-core-native/cpbitnode-blocker-inspect --height 739
```

`cpbitnode-db` emits shared status contract fields, including `validated_height`,
`validated_hash`, `chainstate_backend`, `chainstate_utxo_count`,
`native_crypto_backend`, `current_blocker`, `active_writer_pid`, and
`lock_status`. This status path reads from RocksDB state.

## Docker

```bash
make docker-config
make docker-warm
make docker-cpp-supporting-5k-proof
make docker-cpp-rocksdb-storage-proof
make docker-cpp-sync-supervisor
make docker-cpp-sync-status
make docker-cpp-sync-stop
make docker-cpp-sync-resume
```

`docker-cpp-supporting-5k-proof` is the Project-facing supporting 5k Docker
benchmark. It uses a fresh proof volume, local Reference Core at
`REFERENCE_P2P_PEER` from `Nodes/Shared/docker/reference_topology.env`, RocksDB-owned state, native secp256k1, WAL enabled,
and writes compact evidence under `Nodes/Shared/conformance/results/`.
`docker-cpp-rocksdb-storage-proof` remains the smaller storage/codec proof.

## Intentionally limited in CI

- Live testnet4 sync (offline unit tests only)
- Full healthcheck live peer/mempool counts when node is not running
