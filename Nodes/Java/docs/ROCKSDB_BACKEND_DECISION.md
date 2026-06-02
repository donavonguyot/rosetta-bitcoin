# RocksDB Backend Decision Report

## Current Decision

Use RocksDB as the JavaNode-exclusive node-local KV backend.

RocksDB now backs both operational metadata/index state and active chainstate.
Raw block bytes remain in flat files under `blocks/`.

## Correctness

- RocksDB uses the shared native chainstate codec for active UTXOs, undo records,
  active tip, and metadata.
- Startup rejects non-RocksDB runtime backend selection.
- Startup rejects missing declared native backend paths instead of recreating an
  apparently active chainstate.

## Benchmark Harness

Run only against a quiescent, stopped source datadir. The harness copies the
source and replays stored blocks offline into a fresh RocksDB chainstate:

```bash
cd JavaNode
make java-node-chainstate-backend-benchmark \
  SOURCE_DATA_DIR=./data-java \
  WORK_DIR=./benchmark-chainstate \
  BLOCKS_MAX=500
```

The harness reads stored blocks from the source datadir and writes an isolated
RocksDB replay output under `WORK_DIR`. Keep the source datadir
quiescent or pass a copied source datadir; the harness no longer duplicates the
full source per backend. It emits CSV metrics including connected blocks,
elapsed rebuild time, directory size, and key timing averages.

## Historical Benchmark Note

Earlier comparator evidence is superseded by the NodeCore engine decision:
serious ports use RocksDB with Codec v2. New Java evidence should be collected
through the RocksDB replay proof and local-peer sync proof.

## Metrics To Fill From Runs

```text
backend:
height range:
blocks connected:
utxo_count_before:
utxo_count_after:
block_connect_store_commit_ms:
utxo_load_ms:
utxo_apply_ms:
commit_ms:
rebuild_elapsed_ms:
database_size_bytes:
startup_invariant_ms:
```

## Decision Rule

1. Correctness and recovery semantics first.
2. Throughput second.
3. Operational simplicity third.

RocksDB should become the default only if conformance stays green and copied
datadir replay shows better or simpler production behavior than LevelDB over
real JavaNode block ranges.

Current result: the decision rule is not met.

## Operational Cost

RocksDB adds a native JNI dependency through `rocksdbjni`. That is acceptable
for evaluation, but it is a production cost: platform packaging, native library
load behavior, and larger dependency artifacts must be part of the final
decision.

Because the first replay result does not show a throughput or operational
simplicity win, the added native dependency cost weighs against making RocksDB
the default now.
