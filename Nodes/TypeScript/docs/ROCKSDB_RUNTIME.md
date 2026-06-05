# TypeScript RocksDB Runtime

TypeScript Core/native mode owns runtime truth in RocksDB.

```text
chainstate-rocksdb/      metadata, headers, block index, sync state, events,
                         UTXO set, undo, validated tip, blocker state
blocks/                  raw block files
.tsbitnode_native_storage
```

`Project/project.db` remains mission-control state. TypeScript status exports
may be imported there by Project scripts, but TypeScript sync, status, live
node, rebuild, proof, and blocker-diagnostic commands read runtime truth from
RocksDB.

## Acceptance Target

```text
- Fresh native datadirs create .tsbitnode_native_storage and RocksDB state.
- Headers, block index, sync state, blocker/error state, validated tip, UTXO,
  undo, events, and status fields are read from RocksDB.
- Status and proof JSON report chainstate_backend=rocksdb,
  runtime_truth_backend=rocksdb, rocksdb_runtime_truth=true, codec_version=2,
  and native_storage=true.
- Compatibility tooling cannot be used by native/Core proof paths.
```
