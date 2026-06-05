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

There is one official comparable benchmark family:

```text
durable local-reference P2P sync to fixed target height
```

Required conditions:

- start from an empty port-owned datadir or Docker volume;
- reuse warm Docker images/build cache during a benchmark campaign unless
  `DOCKER_REBUILD=1` is explicitly requested;
- keep WAL and normal durability settings enabled;
- use local Reference Core as a P2P peer for comparable runs;
- independently parse, validate, store, and connect every block;
- connect blocks in height order;
- enforce one writer per datadir;
- preserve the datadir after the run;
- support resume from `validated_height + 1` after interruption;
- report status from maintained counters and stored metadata, not hot full
  scans;
- emit a compact JSON artifact under `Nodes/Shared/conformance/results/`;
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

## 5k Supporting Gate

The first standardized gate for port-by-port work is:

```text
supporting_5k_p2p
```

When combined with RocksDB runtime truth, native crypto, the Shared script
corpus `45/45`, and Project strict preflight, this lane is the workspace's 5k
baseline. The baseline proves readiness, comparability, and reporting discipline;
it is not a speed ranking and it is not binary-gate evidence.

Required metadata:

```text
benchmark_contract_version = 1
benchmark_kind = supporting_5k_p2p
benchmark_lane = supporting_5k_p2p
utxo_accounting_policy = core_spendable_v1
target_height = 5000
header_target_height = 5000
target_label = 5k
runtime_surface = docker
peer_mode = local_reference
peer = host.docker.internal:48333 or Reference service:48333
byte_source = local_reference_p2p
proof_mode = p2p_sync
prefetch_depth = 4
script_runner_mode = parallel
rocksdb_wal_disabled = false
fresh_state = true
resume_supported = true
binary_gate_status = not_attempted
```

The gate passes only when `validated_height >= 5000`, `current_blocker = null`,
and the final validated hash matches the port-validated block at height `5000`.
It is the official comparable readiness gate for Docker/local-reference P2P
wiring, native storage ownership, status/proof artifacts, and the first
spend/script path around block 739. It is still not binary-gate evidence.

The 5k baseline requires RocksDB and native crypto. Alternate storage engines,
managed or pure crypto proof paths, WAL-off runs, reused datadirs, partial script
corpus results, and missing timing metadata are diagnostic or research evidence,
not baseline evidence.

For this gate, `chainstate_utxo_count` must use Core-style spendable accounting:
active spendable UTXO entries only, excluding genesis coinbase and empty or
`OP_RETURN` / `0x6a` outputs. At height `5000`, hash
`000000000e3cb5b92e9765ed9c80c6b06f3d0a186478b330dd5e6b274acf03e2`, the
expected `chainstate_utxo_count` is `4574`. Raw unspent output counts are
diagnostic only.

### Replay Evidence Lane

Local Reference RPC replay remains valuable consensus and storage evidence, but
it is a separate lane:

```text
benchmark_lane = supporting_5k_rpc_replay
peer_mode = local_reference_rpc
byte_source = local_reference_rpc
proof_mode = rpc_replay
```

Replay artifacts may pass the target gate, and Project should retain them as
evidence. They must not be cross-ranked against P2P sync artifacts unless a
separate RPC replay report is requested.

Preferred Docker command surface:

```text
docker_warm
docker_proof_local
docker_proof_rpc_replay
```

Run `docker_warm` before a benchmark campaign. Use `docker_proof_local` only for
the official local Reference P2P comparable lane. Use explicit replay command
keys such as `docker_proof_rpc_replay` for RPC byte-source proof. Ports may keep
idiomatic target names, but Project records the command through
`port_command_surface` and records 5k evidence through
`benchmark_gate_matrix` and `benchmark_comparability`.

### Preflight Before Each Run

Before starting any official supporting-gate or benchmark run, preflight the
target port through Project:

```bash
python3 Project/scripts/preflight_benchmark_gate.py \
  --db Project/project.db \
  --gate supporting_5k \
  --port <port>
```

For a whole-port readiness sweep:

```bash
python3 Project/scripts/preflight_benchmark_gate.py \
  --db Project/project.db \
  --gate supporting_5k \
  --all
```

The preflight is read-only. It confirms that Project knows the preferred Docker
command, Docker contract status, local-reference P2P mode, durable proof volume,
and required artifact metadata before a run starts. It also enforces the
official WAL stance: `rocksdb_wal_disabled=false`. A missing current result is
not a preflight failure; it means that port still needs the run. A replay,
WAL-off, wrong-header-target, wrong-prefetch, single-runner, non-Docker, or
missing-fresh-state artifact is rejected as non-comparable even when it remains
valid evidence.

Strict baseline acceptance uses the composed baseline preflight:

```bash
python3 Project/scripts/preflight_port_baseline.py \
  --db Project/project.db \
  --port <port> \
  --strict
```

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
benchmark_lane
byte_source
proof_mode
benchmark_kind
target_height
header_target_height
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
utxo_accounting_policy
chainstate_utxo_count
native_crypto_backend
peer_mode
peer
script_runner_mode
rocksdb_wal_disabled
prefetch_depth
fresh_state
resume_supported
result
failures
```

Required benchmark values:

```text
benchmark_contract_version = 1
benchmark_kind = primary_100k_p2p
target_height = 100000
target_label = 100k
peer_mode = local_reference
byte_source = local_reference_p2p
proof_mode = p2p_sync
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

Use this result name for 5k supporting-gate artifacts:

```text
<port>_<surface>_supporting_5k_benchmark_<YYYY-MM-DD>.json
```

## Non-Goals

- Do not use benchmark results to claim live P2P sync.
- Do not use local Reference RPC as a validation oracle.
- Do not skip unsupported consensus rules to improve throughput.
- Do not hide WAL-off or disposable proof settings.
- Do not treat tip-height churn as a benchmark failure when a fixed target run
  passed.
