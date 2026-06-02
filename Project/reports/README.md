# Project Reports

Reports compare ports from exported observations in `Project/project.db`.

Initial report families:

```text
height-status.md
blockers.md
conformance.md
backends.md
performance.md
binary-gate.md
```

## Report Rules

- Reports are generated from `Project/project.db`, not from live node datadirs.
- Reports must identify the captured timestamp and source run.
- Reports must distinguish active backend state from project observations.
- A port is not marked as passing the binary gate unless its exported status says
  the active chainstate validated to tip independently.

## Suggested Matrices

- per-port `validated_height`, `header_height`, `sync_status`
- blocker clearance by height and script rule
- conformance fixture pass/fail by implementation
- active backend inventory and generation status
- timing comparison by block, range, stage, and backend

## Report Specifications

### Height And Status

Source: latest `status_snapshots` per node.

Fields:

```text
implementation
chain
sync_status
binary_gate_status
header_height
stored_block_height
validated_height
chainstate_backend
chainstate_status
current_blocker_id
captured_at
```

### Blocker Matrix

Source: `blockers` plus latest status snapshots.

Rows are keyed by height and missing rule. Columns are ports. Values:

```text
cleared
blocked
implemented_unverified
not_reached
unknown
```

### Conformance Matrix

Source: latest `conformance_results` per `node_id` and `fixture_id`.

Values:

```text
passed
failed
skipped
not_run
```

### Backend Inventory

Source: latest `status_snapshots`.

Fields:

```text
implementation
chainstate_backend
chainstate_status
chainstate_generation_id
chainstate_utxo_count
validated_height
validated_hash
last_error
```

### Performance Comparison

Source: `benchmarks` and `timing_samples`.

Compare by:

```text
height
block_hash
backend
stage
elapsed_ms
settings_json
```

Use `block_connect_store_commit` as the primary throughput metric. Treat summed
parallel script timings as CPU accounting, not wall-clock throughput.

### Binary Gate

A port passes only when its latest status reports:

```text
binary_gate_status = passed
chainstate_status = usable
validated_height >= header_height
current_blocker_id is null
```

Reports should show the captured timestamp so stale success is not mistaken for
live truth.
