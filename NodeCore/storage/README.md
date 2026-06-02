# Storage Contract

NodeCore separates operational storage from project management storage.

## Operational Storage

Each node owns its own datadir:

```text
<PortName>/data/
  chainstate/
  blocks/
  locks/
```

The operational datadir contains consensus-relevant state and must have a single
writer lock. It must not share a writable database with another port.

## Raw Blocks

Ports should converge on a flat-file block store:

```text
blocks/blk00000.dat
blocks/blk00001.dat
```

The active chainstate or block index stores:

```text
height
block_hash
file_number
file_offset
block_size
```

Java source material:

- `JavaNode/src/main/java/com/jbitnode/storage/BlockStore.java`
- `JavaNode/src/main/java/com/jbitnode/storage/BlockStorage.java`
- `JavaNode/src/main/java/com/jbitnode/storage/DatadirLock.java`

## Project Storage

`Project/project.db` is not operational storage. It observes exported status,
run summaries, blocker entries, conformance results, and benchmark results. A
node must never need it to validate blocks.

## Single Writer Rule

Every operational writer must acquire the datadir lock before opening the active
chainstate for mutation. Read-only status tools may run concurrently only when
the backend supports consistent snapshots.

## Storage Gate

Follower ports must pass the storage gate before claiming broad storage
readiness. The canonical gate contract is
[`STORAGE_GATE.md`](STORAGE_GATE.md).
