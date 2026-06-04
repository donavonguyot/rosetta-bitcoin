# Cpp status — 2026-06-03 (RocksDB Codec v2 optimization)

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
| status_contract | passed | `cpbitnode-db --chainstate-backend rocksdb`; storage proof reports `chainstate_backend=rocksdb` |
| storage_gate | passed | storage proof reports `local_sqlite_artifact_absent=true`, `codec_version=2`, and `chainstate_codec_v2_vectors_run=true` |
| codec_v2_records | passed | UTXO, undo, tip, block index, header, and metadata records use NodeCore Chainstate Codec v2 binary keys/values |
| native_crypto_vectors | passed | `ctest --test-dir build-core-native --output-on-failure` |
| docker_supervisor_contract | proof_partial | `Makefile`, `docker/docker-compose.yml`, `scripts/docker_sync_supervisor.sh`; see `NodeCore/docker/PORT_DOCKER_INVENTORY.md` |
| blocker_diagnostics_contract | present | `cpbitnode-blocker-inspect --height 739` |
| project_import | observational_only | status snapshot and conformance results imported into `Project/project.db`, but imports do not prove Core compliance |

Cpp compliance is RocksDB-only. Do not accept generic native-store language for
Cpp: RocksDB must own headers, block index, sync state, blocker state, status
truth, UTXO, undo, metadata, and validated tip.

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
| datadir | `/tmp/cpbitnode-timed-739` |
| validated_height | **28432** |
| utxo_count | 261085 |
| header_count | 64889 |
| blocker | none through 28432 in persisted timed local Reference run |

## Timing Evidence

`CPBITNODE_SYNC_TIMING=1` staged local Reference run:

| Range | Blocks | utxo_load_us | script_verify_us | utxo_apply_us | commit_us |
|-------|--------|--------------|------------------|---------------|-----------|
| 1-739 | 739 | 993 | 67182 | 2106 | 31521 |
| 740-6975 | 6236 | 753950 | 7168783 | 538458 | 36218407 |
| 6976-10000 | 3025 | 89471 | 921942 | 91808 | 22459154 |
| 26655-28432 (WAL on) | 1778 | 791242 | 5896594 | 1085473 | 81461755 |
| 28433-32464 (WAL off, interrupted catch-up log only) | 4032 | 1522815 | 9840667 | 2132702 | 316333135 |

Storage commit is dominant through the persisted 28432 run. A rebuildable
catch-up attempt with `CPBITNODE_ROCKSDB_DISABLE_WAL=1` reached timing output at
32464 before interruption, but persisted state remained at the pre-run height;
that mode is evidence only unless it exits cleanly. Defer parallel script
verification and fetch/connect pipelining until the commit path is improved
further.

## Handshake (AGENTS.md)

- Post-`verack`: always `sendheaders` (fixed in `peer.cpp`).
- `feefilter` / `mempool` still deferred until `headers_current` / LISTEN paths.
- Block-only sync uses validated height for `version.start_height` via `resolveBootstrapStartHeight`.

## Python scout

- `validated_height`: ~31929+ (actively syncing)
- Next C++ target after 739 fix: continue batches toward Python frontier, then height **6975** (P2TR scout milestone).

## Next exact work

1. Reduce RocksDB commit cost now that timing shows `commit_us` dominates through 28432 and keeps rising.
2. Resume staged timed sync toward 50000 after commit-path changes.
3. Only then reconsider parallel script verification or fetch/connect pipelining.
