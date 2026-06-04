# Benchmark Contract

This contract defines the one standard cross-port benchmark for node
implementation work in this workspace.

The benchmark exists to compare realistic full-node progress across Rust, Go,
Cpp, Java, Python, TypeScript, CSharp, and Elixir without weakening the binary
gate. It is not a speed-to-tip contest and it is not a substitute for live P2P
tip maintenance.

The binary gate is unchanged: from empty local state on Bitcoin testnet4, a node
must reach and maintain tip while independently validating every stored connected
block.

## Primary Benchmark

There is one official benchmark:

```text
durable local-reference replay to height 100000
```

Required conditions:

- start from an empty port-owned datadir or Docker volume;
- keep WAL and normal durability settings enabled;
- use local Reference Core only as a block source;
- independently parse, validate, store, and connect every block;
- connect blocks in height order;
- enforce one writer per datadir;
- preserve the datadir after the run;
- support resume from `validated_height + 1` after interruption;
- report status from maintained counters and stored metadata, not hot full
  scans;
- emit a compact JSON artifact under `NodeCore/conformance/results/`;
- keep `binary_gate_status=not_attempted`.

The benchmark target is fixed at `100000` because it covers the major early
consensus blockers, the 66k-72k UTXO expansion, and the 87k-88k slow-block
region without chasing a moving tip.

## Supporting Gates

These fixed targets are useful development gates, but they are not the primary
benchmark:

| Target | Role |
|--------|------|
| `5000` | First readiness gate. Proves Docker/local-reference wiring, native storage ownership, status/proof artifacts, and the early spend/script path around block 739. |
| `10000` | Early consensus checkpoint. Extends the first gate through the first P2TR key-path region around 6975 without becoming the primary endurance benchmark. |
| `50000` | Midrange regression gate. Catches heavier block/script behavior before the largest UTXO expansion. |
| `100000` | Primary benchmark. This is the standard comparison target. |

Tip runs remain useful for milestone confidence or binary-gate-adjacent work,
but a moving tip is not the routine benchmark target. A tip artifact must record
the exact Reference height/hash at start and finish.

## Diagnostic Runs

Ports may still run disposable diagnostics while tuning, for example WAL-off
proofs, reduced targets, copied datadirs, profiler runs, or single-block heavy
block probes.

Diagnostic runs must be labeled `diagnostic`, `fast`, `wal_off`, `profile`, or
another explicit non-benchmark category. They must not be presented as the
official benchmark, and they must not be compared directly against the primary
benchmark.

## Required Artifact Fields

Primary benchmark JSON should include these top-level fields whenever
applicable:

```text
implementation
runtime_surface
benchmark_contract_version
benchmark_kind
target_height
target_label
reference_start_height
reference_start_hash
reference_finish_height
reference_finish_hash
validated_height
validated_hash
blocks_fetched
blocks_connected
current_blocker
binary_gate_status
chainstate_backend
chainstate_utxo_count
native_crypto_backend
script_runner_mode
rocksdb_wal_disabled
prefetch_depth
resume_supported
result
failures
```

Required benchmark values:

```text
benchmark_contract_version = 1
benchmark_kind = primary_100k_durable_local_reference_replay
target_height = 100000
target_label = 100k
rocksdb_wal_disabled = false
resume_supported = true
binary_gate_status = not_attempted
```

The benchmark passes only when `validated_height >= 100000`,
`current_blocker = null`, and the final validated hash matches the locally
validated block at height `100000`.

## Timing Buckets

Use stable names so ports can be compared:

| Bucket | Meaning |
|--------|---------|
| `total_wall` | End-to-end wall time for the proof command. |
| `rpc_getblockhash` | Reference RPC block-hash lookup time. |
| `rpc_getblock` | Reference RPC raw-block fetch time. |
| `block_parse_validate` | Local block parse, hash, PoW, linkage, merkle, and tx decode validation. |
| `block_store` | Raw block or block-index storage time outside chainstate connect. |
| `metadata_store` | Non-chainstate proof/progress metadata writes. |
| `connect_total` | Total local block connect time. |
| `prevout_batch_load` | External prevout batch lookup time. |
| `script_verify` | Script verification time. Label CPU-summed time if it is not wall time. |
| `utxo_apply` | UTXO/undo mutation preparation before commit. |
| `commit` | Storage commit/write-batch time. |
| `block_connect_store_commit` | Whole connect/store/commit wall-clock stage when a port reports one aggregate bucket. |

Artifacts should also record a `slow_blocks` list with at least height and
elapsed milliseconds.

## Resource Telemetry

Docker benchmark runs should record or be accompanied by:

- container name or volume name;
- CPU percent samples;
- memory usage samples;
- block IO samples;
- whether the run was fresh, resumed, interrupted, or completed cleanly.

The compact proof JSON is the canonical evidence. Long logs and live datadirs
remain generated artifacts and should not be committed unless a separate
retention rule says otherwise.

## Naming

Use this result name for primary benchmark artifacts:

```text
<port>_<surface>_primary_100k_benchmark_<YYYY-MM-DD>.json
```

Examples:

```text
rust_docker_primary_100k_benchmark_2026-06-04.json
go_docker_primary_100k_benchmark_2026-06-04.json
cpp_docker_primary_100k_benchmark_2026-06-04.json
```

Existing legacy filenames remain valid historical evidence, but new benchmark
work should use this naming shape when practical.

## Non-Goals

- Do not use benchmark results to claim live P2P sync.
- Do not use local Reference RPC as a validation oracle.
- Do not skip unsupported consensus rules to improve throughput.
- Do not hide WAL-off or disposable proof settings.
- Do not treat tip-height churn as a benchmark failure when a fixed target run
  passed.
