# Benchmark Contract

RB benchmarks are developer-experience infrastructure. They measure how quickly
and cleanly a port can prove correctness, expose bottlenecks, and reproduce
evidence during development. They are not production node bragging rights, and
they are not a permanent architecture mandate.

The baseline stack is the current measuring stick: RocksDB runtime truth,
native/baseline crypto, Docker, local Reference P2P, WAL enabled, fixed knobs,
Core-style UTXO accounting, and Project-importable compact artifacts. Future
storage or crypto experiments are welcome only when they declare their lane and
meet the same proof burden.

## Official Suite

| Gate | Purpose | Command | Official lane |
|------|---------|---------|---------------|
| `baseline_5k` | Birth certificate. Cheap enough to run often. | `docker_proof_local` | `baseline_5k_p2p` |
| `shakedown_50k` | Serious readiness and telemetry shakedown. | `docker_proof_50k` | `shakedown_50k_p2p` |
| `performance_100k` | Primary optimization and ranking lane. | `docker_proof_100k` | `performance_100k_p2p` |
| `tip_once` | One-time empty-state-to-tip credibility proof. | `docker_proof_tip_once` | `tip_once_p2p` |
| `tip_maintenance` | Operational reality near/at tip. | `docker_tip_maintenance` | `tip_maintenance_p2p` |

Retired gates such as `supporting_10k` and `tuning_50k_to_100k` remain
historical evidence only. They must not appear in default official Project
reports or acceptance prompts.

## Shared Official Stance

All fixed-height official lanes require:

```text
runtime_surface = docker
peer_mode = local_reference
peer = host.docker.internal:48333 or reference service:48333
byte_source = local_reference_p2p
proof_mode = p2p_sync
prefetch_depth = 4
script_runner_mode = parallel
rocksdb_wal_disabled = false
fresh_state = true
resume_supported = true
binary_gate_status = not_attempted
utxo_accounting_policy = core_spendable_v1
```

RPC replay, WAL-off runs, reused state, alternate stores, managed/pure crypto,
missing metadata, and non-Docker artifacts are diagnostic or experimental
evidence. Project may import them, but it must not rank them as official
comparable evidence.

## Gate Requirements

### `baseline_5k`

Required:

- Target/header height `5000`.
- Expected hash `000000000e3cb5b92e9765ed9c80c6b06f3d0a186478b330dd5e6b274acf03e2`.
- `chainstate_utxo_count=4574`.
- Clean port-owned script corpus proof: `port.script_corpus_result.v1`,
  `fixture_count=45`, `passed=45`, `failed=0`.
- Final artifact timing buckets: `utxo_load`, `script_verify`, `utxo_apply`,
  `commit`, and `block_connect_store_commit`.

Live chat telemetry is optional for 5k because the run is intentionally short.

### `shakedown_50k`

Required:

- Target/header height `50000`.
- Expected `chainstate_utxo_count=568855`.
- Parseable `benchmark.telemetry_tick.v1` progress.
- Slow-block summary.
- Long-run timing buckets: `p2p_fetch`, `block_parse_validate`, `utxo_load`,
  `script_verify`, `utxo_apply`, `commit`, and
  `block_connect_store_commit`.
- No blocker and no stale/reused state.

This is the first serious shakedown. It replaces 10k as the meaningful
post-baseline readiness gate.

### `performance_100k`

Required:

- Target/header height `100000`.
- Expected hash `0000000000524911745ab6eee9348bca9843c2c2b1b27eada246e3dc2f80b6b1`.
- `chainstate_utxo_count=13154991`.
- Full `benchmark.telemetry_tick.v1` progress.
- Slow-block and script-family summaries where the port can provide them.
- Complete timing import into Project.

This is the primary performance comparison lane for optimization work.

### `tip_once`

Required:

- Empty state to current testnet4 tip.
- Exact Reference start and finish height/hash.
- Final validated tip height/hash and status artifact.
- No skipped consensus rules.
- Telemetry summary and final Project-importable proof.

This is a one-time credibility milestone, not a routine drag race.

### `tip_maintenance`

Required:

- Start near or at tip.
- Maintain `blocks_current` through the maintenance window.
- Record peer reconnects, stalls, restart recovery, and reorg-handling posture.
- Emit health/status telemetry.

This lane proves node reality. It is not ranked by empty-sync speed.

## Telemetry Contract

Long runs (`shakedown_50k`, `performance_100k`, `tip_once`, and
`tip_maintenance`) must emit lines consumable by
`Project/scripts/monitor_benchmark_telemetry.py`:

```text
benchmark.telemetry_tick {"schema":"benchmark.telemetry_tick.v1", ...}
```

Required tick fields:

```text
schema
port
gate
target_height or tip mode
height
percent when bounded
elapsed_ms
rate_recent_blocks_per_second
rate_total_blocks_per_second
phase
utxos
last_block_ms
current_blocker
timing_buckets_ms
```

Required timing buckets inside `timing_buckets_ms`:

```text
p2p_fetch
block_parse_validate
utxo_load
script_verify
utxo_apply
commit
block_connect_store_commit
```

Validate telemetry with:

```bash
python3 Project/scripts/validate_benchmark_telemetry.py --require-bounded-target <log>
```

## Project Acceptance

Project owns current benchmark truth:

```bash
python3 Project/scripts/import_all.py --db Project/project.db --rebuild
python3 Project/scripts/report.py --db Project/project.db --section benchmark-suite
python3 Project/scripts/preflight_benchmark_gate.py --db Project/project.db --gate baseline_5k --all
python3 Project/scripts/preflight_benchmark_gate.py --db Project/project.db --gate shakedown_50k --all
python3 Project/scripts/preflight_benchmark_gate.py --db Project/project.db --gate performance_100k --all
```

Historical artifacts remain in `Nodes/Shared/conformance/results/`, but the
official suite reports only the current gates above.
