# Java Lead Cleanup Plan

JavaNode is the lead implementation for NodeCore, but it must be cleaned into
the target architecture before followers copy it.

## Problem To Fix

Java must keep useful pieces split by role: RocksDB for node-local KV state,
flat block files for raw block bytes, and CLI status over the active stores. The
dangerous part is not having multiple files. The dangerous part is letting more
than one component claim consensus truth.

NodeCore requires Java to expose exactly one active `ChainstateStore` per
datadir.

## Target Java Shape

```text
JavaNode/data/
  operational-rocksdb/
  utxo-rocksdb/
  blocks/
    blk*.dat
  .jbitnode_native_storage
```

Project SQLite is observational only. Java runtime sync, validation, status,
block lookup, and rebuild paths must not depend on it.

## Cleanup Steps

1. Use RocksDB for both operational metadata/index state and chainstate UTXOs.
2. Keep validated tip, backend metadata, undo, and UTXO stats under that store.
3. Keep `ProjectTracker` backed by the active operational store, not Project DB.
4. Make `SyncLocalCoreService`, `LiveNodeService`, and rebuild tools open the
   same active chainstate path.
5. Make status read active chainstate metadata and fail closed on mismatch.
6. Add active backend metadata:

```text
backend_name
backend_path
generation_id
status
tip_height
tip_hash
schema_version
```

7. Add startup invariant checks before any writer connects a block.
8. Keep Java's proven performance pieces: block-local UTXO view, batched writes,
   timing buckets, bounded sync chunks, live loop, and rebuild tests.

## Migration Rule

Do not silently switch a datadir from another backend into RocksDB. A backend
switch is a rebuild/promote operation that creates a new generation and marks it
active only after verification.

## Acceptance Criteria

- Java status reports one active chainstate backend.
- Active chainstate height/hash/UTXO count come from that backend.
- Startup refuses missing, rebuilding, corrupted, or misaligned backends.
- Sync, live mode, rebuild, and status use the same backend metadata.
- Java passes NodeCore conformance before CSharpNode copies the architecture.
