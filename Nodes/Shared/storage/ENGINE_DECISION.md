# Operational Storage Backend Proof Decision

Shared standardizes both the chainstate contract and the serious-port storage
target. Ports may keep debug/reference backends, but performance work should
converge on RocksDB plus the shared Shared binary key/value codec.

## Recommendation

Use RocksDB as the serious-port chainstate backend. A port may temporarily keep
file or in-memory stores for reference/debug work, but default operational sync
should move to RocksDB after the port passes the shared `ChainstateStore`
conformance and storage-gate proof.

```text
Shared by every serious port:
  ChainstateStore behavior
  RocksDB-backed native keyspace semantics
  Shared Chainstate Codec v2
  backend metadata
  startup invariants
  conformance fixtures
  replay benchmark metrics

Chosen per port:
  native binding/package strategy
  compaction/tuning strategy
```

## Why Mandate RocksDB Now

The earlier Java LevelDB/RocksDB replay showed RocksDB was essentially tied on
runtime and only larger on disk with the original string-heavy codec. The disk
gap is better addressed by a shared binary codec than by keeping each port on a
different engine.

The project priority is now performance and cross-port optimization. RocksDB has
credible native bindings across the serious-port set, supports atomic write
batches, snapshots/checkpoints, compaction controls, and predictable operational
tuning. Those properties are more valuable than preserving a pure-language Java
LevelDB default.

Native packaging risk is accepted for serious ports. Ports that cannot yet ship
RocksDB remain reference/debug ports until they prove an equivalent path.

## Port Starting Matrix

| Port | Initial backend posture | Native / binding risk | Required proof before promotion |
|------|--------------------------|------------------------|----------------------------------|
| JavaNode | RocksDB-exclusive node-local KV storage | `rocksdbjni` | Codec v2 proof, storage-gate proof, replay/soak |
| CppNode | Native RocksDB target | Native C++ library | Codec v2 proof, storage-gate proof |
| CSharpNode | RocksDB target for native chainstate | .NET RocksDB binding | Codec v2 proof, storage-gate proof |
| PythonNode | RocksDB target for finish-line sync | Native extension binding | Vector proof before operational use |
| ElixirNode | RocksDB target for finish-line sync | NIF/port binding | Vector proof before operational use |
| TypeScriptNode | RocksDB target if native deps are accepted | Native addon/N-API binding | Vector proof before operational use |

## Backend Proof Protocol

Each serious port needs a RocksDB proof target before serious sync work:

```text
input:
  copied quiescent datadir or exported block range
  fixed chain
  fixed block range
  same validation code

measure:
  block_connect_store_commit
  utxo_load
  utxo_apply
  commit
  database size
  rebuild time
  startup invariant check time

accept:
  conformance passes
  no backend/status mismatch
  rebuild/promote verified
  live loop can maintain tip
```

## Decision Rule

Choose RocksDB configurations and codec improvements that preserve operational
correctness first and throughput second. Tuning that complicates validated-tip
truth, generation promotion, or crash recovery loses.

Promotion order:

```text
codec v2 conformance
  -> contract conformance
  -> offline replay benchmark
  -> copied-state soak
  -> operational default
```

## Current Java Evidence

JavaNode's first LevelDB/RocksDB replay used the same stored block range and
shared native chainstate keyspace:

```text
backend  height_after  blocks_connected  utxo_count  elapsed_ms  size_bytes
leveldb  5000          5000              9232        61896       30319567
rocksdb  5000          5000              9232        62122       40784693
```

Both engines were correct for that range. RocksDB was only 0.36% slower and
34.5% larger with the original string-heavy codec. That is close enough to pivot
to RocksDB and spend optimization effort on the shared binary data model instead
of maintaining divergent backend strategies.
