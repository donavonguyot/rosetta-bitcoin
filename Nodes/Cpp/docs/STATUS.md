# Cpp status — 2026-06-02 (RocksDB-only native cutover)

## Tests

```bash
cmake -S . -B build-core-native -DCMAKE_BUILD_TYPE=Release \
  -DCPBITNODE_USE_ROCKSDB=ON \
  -DCPBITNODE_USE_NATIVE_SECP256K1=ON
cmake --build build-core-native
ctest --test-dir build-core-native --output-on-failure   # green
```

Coverage: report-only (see README).

## Core Node proof status

| Contract | Status | Evidence |
|----------|--------|----------|
| status_contract | proof_pending | `cpbitnode-db --chainstate-backend rocksdb` now reads RocksDB state and refuses legacy `cpbitnode.db`; rerun proof artifact before marking passed |
| storage_gate | proof_pending | RocksDB state now owns headers, block index, sync state, tip, UTXO, undo, metadata, wire/event facts; rerun storage proof before marking passed |
| native_crypto_vectors | passed | `ctest --test-dir build-core-native --output-on-failure` |
| docker_supervisor_contract | proof_partial | `Makefile`, `docker/docker-compose.yml`, `scripts/docker_sync_supervisor.sh`; see `NodeCore/docker/PORT_DOCKER_INVENTORY.md` |
| blocker_diagnostics_contract | present | `cpbitnode-blocker-inspect --height 739` |
| project_import | observational_only | status snapshot and conformance results imported into `Project/project.db`, but imports do not prove Core compliance |

Cpp compliance is RocksDB-only. Do not accept generic native-store language for
Cpp: RocksDB must own headers, block index, sync state, blocker state, status
truth, UTXO, undo, metadata, and validated tip without opening SQLite.

## Sync (local Core)

```bash
MAX_OUTBOUND_PEERS=1 SKIP_GETADDR=1 ./build/cpbitnode-sync \
  --datadir ./data-cpp \
  --peers 127.0.0.1:48333 \
  --blocks-target 1000 \
  --blocks-max 200 \
  --no-header-refresh
```

| Field | Value |
|-------|-------|
| peer | `127.0.0.1:48333` |
| datadir | `./data-cpp` |
| validated_height | **738** |
| utxo_count | 738 |
| header_count | 88001 |
| blocker | height 739 cleared by native fixture regression; live sync rerun still pending |

## Handshake (AGENTS.md)

- Post-`verack`: always `sendheaders` (fixed in `peer.cpp`).
- `feefilter` / `mempool` still deferred until `headers_current` / LISTEN paths.
- Block-only sync uses validated height for `version.start_height` via `resolveBootstrapStartHeight`.

## Python scout

- `validated_height`: ~31929+ (actively syncing)
- Next C++ target after 739 fix: continue batches toward Python frontier, then height **6975** (P2TR scout milestone).

## Next exact work

1. Run a live RocksDB/native sync batch against local Core and record the new runtime `validated_height`.
2. Resume staged batches toward 6975.
3. Ratchet coverage when the sync spine passes 6975+.
