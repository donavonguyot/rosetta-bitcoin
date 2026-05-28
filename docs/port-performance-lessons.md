# Port performance lessons

These notes turn the Java and Python catch-up work around the 52k testnet4
range into reusable guidance for future ports. They are performance patterns,
not consensus shortcuts.

The binary gate is unchanged: every connected block must be independently
validated. A faster node that skips a missing script rule or trusts another port
has failed the gate.

## Core lesson

Most node performance wins came from changing where work is measured, cached,
batched, and parallelized while preserving the validation order:

```text
instrument -> cache prevouts -> batch writes -> atomic connect
  -> parallelize pure script checks -> benchmark -> resume blocker loop
```

Java showed that SQLite itself was not the first bottleneck. The expensive shape
was per-input SQL, duplicate UTXO fetches, per-row writes, and a small cache on a
large UTXO table. After that was fixed, script verification became the wall-clock
driver on large blocks.

## Safe block-connect shape

Every port should converge on a block-local UTXO view:

| Component | Purpose |
|-----------|---------|
| `created` | Outputs created earlier in the same block. |
| `spent` | Prevouts consumed by transactions in this block. |
| `loaded` | External UTXOs fetched once from persistent storage. |
| `apply()` | Batched durable mutation after all validation succeeds. |

This shape supports same-block spends, avoids duplicate UTXO reads, gives undo
creation access to already-loaded prevouts, and keeps persistent writes out of
script verification.

## Persistence pattern

Block connect should commit atomically:

1. Validate header, merkle root, coinbase, witness commitment, and spends.
2. Build undo entries from the block-local view.
3. Batch-delete external spends.
4. Batch-insert unspent created outputs.
5. Write undo rows and the validated tip.
6. Commit once.

The durable transaction should cover undo rows, UTXO mutations, validated tip,
and any connect counters that must move together. If commit fails, the block
must not be half-connected.

## Timing fields

Ports should use common stage names so reports can be compared:

| Stage | Meaning |
|-------|---------|
| `utxo_load` | Time loading external prevouts into the block-local view. |
| `script_verify` | Time spent verifying input scripts. |
| `utxo_apply` | Time applying UTXO deletes/inserts and undo rows before commit. |
| `commit` | Storage commit time, if measurable separately. |
| `block_connect_store_commit` | Wall-clock time for the whole connect/store/commit path. |

When script verify is parallelized, summed worker CPU can exceed wall time. Use
`block_connect_store_commit` as the throughput gate and label summed worker time
as CPU time if it is recorded.

## Safe parallelism boundary

The safe first parallel step is per-transaction input verification:

1. Process transactions in block order.
2. Load all prevouts for the current transaction on the main thread.
3. Build the immutable spent-prevout list once.
4. Verify independent inputs in parallel if the transaction has enough inputs.
5. Sort failures by input index and report the first deterministic blocker.
6. Spend prevouts sequentially only after all inputs verify.

Do not parallelize UTXO writes or let multiple sync processes write one datadir.
Do not reorder transactions. Cross-transaction parallel verification is a later
research topic because it must preserve ordering and same-block dependency
rules.

## Port checklist

Use this checklist before a port starts serious catch-up:

- A single-writer datadir lock exists for sync/connect entry points.
- Block connect is atomic.
- The UTXO table/store has an index or key on `(chain, txid, vout)` or the
  backend equivalent.
- The block-local view has `created`, `spent`, and `loaded` maps.
- Undo creation reuses loaded prevouts instead of re-fetching.
- UTXO spends and creates use batch APIs.
- Storage settings are tuned for the backend and workload.
- Per-block timing events use the shared stage names above.
- Script verification has a pure single-input primitive.
- Parallel script verification, if enabled, is gated by config and keeps
  transaction order unchanged.
- Validation blockers still include height, block hash, txid, input index,
  spent scriptPubKey, failure, missing rule, fixture path, and follower notes.

## Benchmark report template

Record at least one before/after sample on a heavy stored block:

```text
port:
commit_or_branch:
datadir:
height:
block_hash:
block_size:
tx_count:
input_count:
utxo_count:

settings:
  sync_timing:
  parallel_script_verify:
  script_executor:
  script_threads:
  script_min_inputs:

timings_ms:
  utxo_load:
  script_verify:
  utxo_apply:
  commit:
  block_connect_store_commit:

tests:
validated_height_after:
next_blocker:
binary_gate_status:
notes:
```

### Safe copied-datadir benchmark workflow

Benchmark connect changes only against a copied, quiescent datadir. Do not run
timed experiments against the live `./data` or `./data-java` while a sync process
may hold the writer lock.

Minimum safe flow:

```bash
# Python example; choose a work path outside the repo or under a scratch dir.
cp -a /path/to/quiescent/PythonNode/data /tmp/pybitnode-bench-data
cd /Users/donavonguyot/Nodes/PythonNode
SYNC_TIMING=1 PAR_SCRIPT_VERIFY=1 PAR_SCRIPT_THREADS=8 \
  .venv/bin/pybitnode-sync --datadir /tmp/pybitnode-bench-data \
  --connect-only --blocks-max 1 --log-level info
.venv/bin/pybitnode-db --db /tmp/pybitnode-bench-data/pybitnode.db --events 20
```

For Java, copy `data-java` first, pass `DATA_DIR=/tmp/jbitnode-bench-data`, and
use the normal local-core or connect-only entry point available for that branch.
Record `block_connect_store_commit` as the wall-clock throughput metric.
Summed parallel `script_verify` time is useful CPU accounting, not wall clock.

Python process-worker experiments are opt-in with:

```bash
PAR_SCRIPT_EXECUTOR=process
```

Default remains `thread` until a copied-datadir benchmark shows that process
workers reduce `block_connect_store_commit` on real heavy stored blocks.

## Anti-patterns

- Migrating storage engines before measuring the access pattern.
- Running two writers on one datadir.
- Sharing one SQLite connection across script worker threads.
- Parallelizing UTXO mutation.
- Reordering block transactions.
- Treating summed parallel `script_verify` CPU time as wall-clock time.
- Treating `BLOCKS_MAX` as a performance fix instead of checkpoint hygiene.
- Skipping unsupported scripts to move the height counter.
- Reporting another port's success as local validation.

## Reference trail

Java's 52k investigation provides the clearest measured example:

- UTXO load/apply/commit dropped to sub-second scale after connect-time caching,
  batch writes, reused prepared statements, SQLite pragmas, and atomic connect.
- Remaining sequential script verification took roughly 105 seconds on a heavy
  block.
- Per-transaction input parallelism reduced wall-clock connect time to roughly
  10 seconds on the measured block.

Python is porting the same pattern as scout work reaches the same block shapes.
Follower ports should copy the pattern and benchmark locally, not copy trust.

## Cursor operating model

The JavaNode long-sync setup also proved an operational pattern that ports should
copy:

- expose one normal chunk target for agents to run;
- default long catch-up to local Reference Core (`127.0.0.1:48333`);
- enforce one writer with a datadir lock;
- keep chunks bounded and parseable;
- write terminal summaries with `validated_height`, `sync_status`,
  `current_blocker`, and `utxo_count`;
- monitor with a separate read-only sentinel loop instead of restarting sync.

PythonNode mirrors this in `PythonNode/Makefile`,
`PythonNode/scripts/cursor_sync_monitor.py`, and
`PythonNode/docs/OPERATIONS.md`.
