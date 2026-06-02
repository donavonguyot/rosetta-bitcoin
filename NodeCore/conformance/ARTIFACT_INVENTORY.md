# Artifact Inventory

This inventory records how generated proof/log/data artifacts are classified
before cleanup. It is not a live status report; use port status commands for
live sync truth.

## Canonical Project Evidence

Keep compact, committed proof JSON here:

```text
NodeCore/conformance/results/
```

Current canonical result files include Java, C#, and Cpp storage/native-crypto
proofs. Docker contract result JSONs are expected to use the same directory once
ports emit them.

## Cross-Port Rules

| Pattern | Classification | Action |
|---------|----------------|--------|
| `Nodes/*/docs/BLOCKER_LEDGER.md` | port durable evidence | Keep. |
| `Nodes/*/docs/STATUS.md` | port durable evidence | Keep. |
| `Nodes/*/tests/fixtures/**` | port durable evidence | Keep. |
| `Nodes/*/snapshots/*.json` | checkpoint evidence | Keep when intentionally tracked by the port. |
| `Nodes/*/data*`, `blocks/`, `chainstate-rocksdb/`, `operational-*`, `utxo-*` | runtime state | Ignore; delete only if classified as scratch or explicitly approved. |
| `*.db`, `*.db-wal`, `*.db-shm`, `*.sqlite*` | runtime state | Ignore; delete scratch copies, not active primary datadirs. |
| `*.log`, `sync_*.log`, `sync_chunk_*.log`, `sync_catchup_*.log` | generated logs | Delete stale logs after preserving compact evidence. |
| `build*/`, `target/`, `dist/`, `_build/`, `deps/`, `node_modules/`, `.venv/` | generated build output | Ignore/delete when not needed for immediate validation. |
| `*.pid`, `.batch-sync-running`, `*.lock` | runtime markers | Delete only when the corresponding process is not running. |
| nested `.git/` directories | legacy cruft | Delete; the workspace has one root Git repository. |

## Python

| Bucket | Paths / patterns | Action |
|--------|------------------|--------|
| Keep port-local | `docs/BLOCKER_LEDGER.md`, `snapshots/*.json`, `tests/fixtures/**` | Keep. |
| Keep runtime | `data/` | Keep by default; primary scout datadir. |
| Delete cruft | `connect_only_replay.log`, `forward_batch_38010.log`, `data/pybitnode.db?mode=ro` | Remove. |
| Delete if stale | `data/.batch-sync-running`, `data/.sync_fix_agent.pid`, `data/.sync_supervisor.pid`, zero-byte lock files | Remove after process check. |

## TypeScript

| Bucket | Paths / patterns | Action |
|--------|------------------|--------|
| Keep port-local | `docs/BLOCKER_LEDGER.md`, `snapshots/*.json`, `tests/fixtures/**` | Keep. |
| Keep runtime | `data-ts/` | Keep by default; primary follower datadir. |
| Preserve before delete | `data-ts/follower_ledger.md` | Move content to a durable doc if still useful. |
| Delete cruft | `data-ts-debug*`, `data-ts-bisect*`, `data-ts-light`, `data-ts-full`, `data-ts-dns`, `data-ts-defer`, `data-ts-retest`, `data-ts-mempool-debug`, `data-ts-block-test`, `data-ts-peer-test`, `data-ts-sync-test` | Remove scratch datadirs. |
| Delete cruft | `sync_batch_run.log`, `sync_batch_operational.log` | Remove stale root logs. |

## Cpp

| Bucket | Paths / patterns | Action |
|--------|------------------|--------|
| Keep port-local | `docs/BLOCKER_LEDGER.md`, `docs/STATUS.md`, `tests/fixtures/**`, intentional `snapshots/` | Keep. |
| Keep runtime | `data-cpp/` | Keep by default unless rerun from scratch is desired. |
| Delete optional generated | `build/`, `build-core-native/`, `.venv-cov/` | Remove only after validation is complete. |
| Keep central | `NodeCore/conformance/results/cpp_rocksdb_codec_v2_storage_2026-06-02.json` | Canonical Cpp RocksDB proof. |

## Java

| Bucket | Paths / patterns | Action |
|--------|------------------|--------|
| Keep port-local | `docs/BLOCKER_LEDGER.md`, test fixtures | Keep. |
| Keep runtime | `data-java/` | Keep by default; large active runtime state. |
| Preserve before delete | proof metrics in `data-java-*/` and `target/java-rocksdb-local-peer-proof-*` | Copy compact JSON to `NodeCore/conformance/results/` when it supports a current claim. |
| Delete cruft | `sync_catchup_*.log`, `sync_chunk_*.log`, `sync_perf_*.log` | Remove stale logs. |
| Delete cruft | redundant `data-java-rocksdb-*`, `data-java-native-crypto-*`, `data-java-smoke*`, replay/proof scratch dirs | Remove after preserving compact proof JSON. |

## CSharp

| Bucket | Paths / patterns | Action |
|--------|------------------|--------|
| Keep port-local | `docs/BLOCKER_LEDGER.md`, tests, fixtures | Keep. |
| Keep runtime | `data-csharp/` | Keep by default. |
| Preserve before delete | `rocksdb_replay_metrics.json`, `chainstate/*.json`, `metadata.json` in proof dirs | Copy compact JSON to `NodeCore/conformance/results/` when not already represented. |
| Delete cruft | duplicate `data-csharp-rocksdb-*`, `data-csharp-native-proof`, `data-csharp-retirement-proof`, `data-csharp-live-smoke` | Remove after evidence preservation. |

## Elixir

| Bucket | Paths / patterns | Action |
|--------|------------------|--------|
| Keep port-local | `docs/BLOCKER_LEDGER.md`, `test/fixtures/**`, source/tests | Keep. |
| Keep runtime | `data-elixir/` | Keep by default. |
| Delete generated | `_build/`, `deps/` | Remove only if rebuild cost is acceptable. |

## Reference

| Bucket | Paths / patterns | Action |
|--------|------------------|--------|
| Keep source | `README.md`, `bitcoin.conf`, `docker/docker-compose.yml` | Keep. |
| Keep runtime | `bitcoin-core-testnet4/` | Keep by default; local Reference peer data. Delete only for explicit space reclamation. |
| Delete cruft | `bitcoin-core-testnet4/**/debug.log`, internal LevelDB logs | Remove only when Reference is stopped or datadir is being reset. |

## Cleanup Guardrails

- Do not delete primary datadirs during active sync.
- Do not delete blocker ledgers, fixtures, or cited proof JSON.
- Do not commit live DBs or logs to root.
- Prefer regenerating proof JSON over preserving bulky local scratch trees.
