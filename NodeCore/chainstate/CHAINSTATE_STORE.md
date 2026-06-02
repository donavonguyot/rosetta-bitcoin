# Chainstate Store Contract

`ChainstateStore` is the authoritative operational state for a node. It owns the
validated tip, active UTXO set, undo records, backend metadata, and generation
identity.

## Required Interface

Language-specific interfaces may vary, but they must provide this behavior:

```text
open(datadir, chain, mode)
metadata()
tip()
stats()

getUtxo(outpoint)
beginBlock(height, block_hash, prev_hash)
spendUtxos(outpoints)
addUtxos(outputs)
writeUndo(height, entries)
commitBlock(new_tip)
abortBlock()

readUndo(height)
disconnectBlock(height)
close()
```

## Atomic Block Commit

Connecting a block is one logical mutation:

```text
validate block and transactions
load prevouts into block-local view
verify scripts
prepare undo entries
delete spent UTXOs
put created UTXOs
write undo
advance validated tip
commit
```

If commit fails, the active chainstate must not report the block as connected.

## Backend Metadata

Each backend stores:

```text
backend_name
backend_version
schema_version
chain
network
generation_id
status
tip_height
tip_hash
created_at
updated_at
```

Generation IDs prevent accidental promotion or reuse of partially rebuilt state.

## Backend Choice

NodeCore now targets RocksDB for serious operational ports. Debug/reference
backends may exist, but they are not the finish-line chainstate backend.
RocksDB-backed stores must use NodeCore Chainstate Codec v2 byte-for-byte so
storage optimizations apply uniformly across ports.

Each serious port must prove its RocksDB backend early:

```text
codec v2 vector conformance
  -> contract conformance
  -> offline replay benchmark
  -> copied-state soak when evidence is favorable
  -> operational default
```

SQLite or file stores may be bootstrap/reference backends, but they must not
become the authoritative serious-port chainstate by accident.

Java now uses RocksDB as its node-local KV storage target. Optimization work
should improve the shared RocksDB plus Codec v2 path rather than maintaining a
mixed Java storage posture or independent per-port engine selection.

## RocksDB Requirements

RocksDB ports must provide:

```text
atomic WriteBatch block commits
codec_version = 2 metadata
backend_name = rocksdb
backend_version from the linked package/library
generation_id per datadir
validated tip and undo in the same logical commit as UTXO mutations
startup invariant check before sync/status trust
checkpoint/backup story before long-running operation
compaction/tuning values surfaced in proof metadata
```

## Java Extraction Notes

Useful Java source material:

- `JavaNode/src/main/java/com/jbitnode/db/UtxoStore.java`
- `JavaNode/src/main/java/com/jbitnode/db/SqliteUtxoStore.java`
- `JavaNode/src/main/java/com/jbitnode/db/LevelDbUtxoStore.java`
- `JavaNode/src/main/java/com/jbitnode/consensus/connect/BlockConnector.java`

The Java `UtxoStore` interface is a good start, but NodeCore needs the broader
`ChainstateStore` concept so undo, validated tip, backend metadata, and UTXOs
cannot drift apart.
