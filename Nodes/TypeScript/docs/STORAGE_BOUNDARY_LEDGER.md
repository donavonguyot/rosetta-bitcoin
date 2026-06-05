# TypeScript Storage Boundary Ledger

TypeScript Core/native parity is a full break from historical compatibility
state. Existing `tsbitnode.db` state remains useful as handoff evidence only; it
must not be promoted into native/Core proof state.

Forward native datadirs use RocksDB-owned operational truth:

```text
chainstate-rocksdb/      metadata, headers, block index, sync state, events,
                         UTXO set, undo, validated tip, blocker state
blocks/                  raw block files
.tsbitnode_native_storage
```

`Project/project.db` remains top-level observational state. TypeScript status
exports may be imported there by Project scripts, but TypeScript sync, status,
live node, rebuild, proof, and blocker-diagnostic commands must not use a local
compatibility DB for runtime truth in native mode.

## Acceptance Target

```text
- Native TypeScript commands fail before opening a datadir that contains an
  unapproved port-local operational DB artifact.
- Fresh native datadirs create .tsbitnode_native_storage and RocksDB state.
- Headers, block index, sync state, blocker/error state, validated tip, UTXO,
  undo, events, and status fields are read from RocksDB.
- Status and proof JSON report backend_name=rocksdb, codec_version=2,
  native_storage=true, and operational_db_artifact_absent=true.
- Compatibility tooling cannot be used by native/Core proof paths.
```
