# Chainstate Store Contract

`ChainstateStore` is the authoritative operational state for a node. In
Core/native mode it owns every mutable fact needed to sync, validate, resume,
diagnose blockers, and report status.

## Required Interface

Language-specific interfaces may vary, but they must provide this behavior:

```text
open(datadir, chain, mode)
metadata()
tip()
stats()

headers()
blockIndex()
syncState()
currentBlocker()
lastError()

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

## Operational State Boundary

Core/native mode must not split operational truth across a native chainstate and
any hidden operational observer store. The native store owns:

```text
headers
block index
sync state
validated tip
active UTXO set
undo records
backend metadata
generation identity
blocker/current-error state
status truth
```

Compatibility/reference backends may exist only when explicitly named and
excluded from baseline proof paths. Native entry points must not silently
instantiate any alternate store for those fields. A hybrid that stores
UTXO/tip/undo in RocksDB while leaving headers, block index, sync state, or
status truth elsewhere is not Core Node compliant.

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

Shared now requires RocksDB for serious operational ports and for the 5k
baseline. Debug/reference backends may exist, but they are not comparable
baseline evidence or the finish-line chainstate backend.
RocksDB-backed stores must use Shared Chainstate Codec v2 byte-for-byte so
storage optimizations apply uniformly across ports.

Each serious port must prove its RocksDB backend early:

```text
codec v2 vector conformance
  -> contract conformance
  -> offline replay benchmark
  -> copied-state soak when evidence is favorable
  -> operational default
```

Other storage engines are research-only until the port has already cleared the
RocksDB baseline. They do not count as comparable chainstate evidence.

## Python Full-Break Target

Python parity is a breaking migration, not a compatibility profile. The legacy
compatibility path is historical evidence only. A forward Python native/Core run
must start from an empty native datadir and use RocksDB for:

```text
headers
block index
sync state
blocker/current-error state
status truth
active UTXO set
undo records
backend metadata
validated tip
```

Python must also use native crypto for the native/Core proof path and produce
Project-importable RocksDB/native evidence before historical Python clearance can
count as current Python parity evidence.

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

- `Nodes/Java/src/main/java/com/jbitnode/db/UtxoStore.java`
- `Nodes/Java/src/main/java/com/jbitnode/db/ChainstateStore.java`
- `Nodes/Java/src/main/java/com/jbitnode/db/RocksDbChainstateStore.java`
- `Nodes/Java/src/main/java/com/jbitnode/db/RocksDbOperationalStore.java`
- `Nodes/Java/src/main/java/com/jbitnode/db/UtxoStoreFactory.java`
- `Nodes/Java/src/main/java/com/jbitnode/consensus/connect/BlockConnector.java`

The Java `UtxoStore` interface remains useful local source material, but Shared
needs the broader `ChainstateStore` concept so undo, validated tip, backend
metadata, and UTXOs cannot drift apart.
