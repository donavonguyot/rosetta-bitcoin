# Benchmark Contract

RosettaBitcoin benchmarks are developer-experience infrastructure. They measure how quickly
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
| `post_100k_to_tip` | Immediate tip-readiness from canonical 100k state. | `docker_proof_post_100k_to_tip` | `post_100k_to_tip_p2p` |
| `tip_once` | One-time empty-state-to-tip credibility proof. | `docker_proof_tip_once` | `tip_once_p2p` |
| `tip_maintenance` | Operational reality near/at tip. | `docker_tip_maintenance` | `tip_maintenance_p2p` |

Retired gates such as `supporting_10k` and `tuning_50k_to_100k` remain
historical evidence only. They must not appear in default official Project
reports or acceptance prompts.

## Port Lifecycle

Project also classifies each port's current benchmark lifecycle:

| Lifecycle | Meaning |
|-----------|---------|
| `active_contender` | Keep moving through the official suite. Missing future gates are real work. |
| `active_development` | Still being built or stabilized. Baseline evidence matters, but missing long-run gates are not benchmark-table failures yet. |
| `baseline_retired` | Preserve source, tests, and valid 5k evidence; do not push through 50k/100k/tip gates unless explicitly reactivated. |
| `reference` | Bitcoin Core Reference byte source, not a follower contender. |

Lifecycle is a Project mission-control classification, not a deletion policy.
Retired ports remain useful provenance and baseline examples, but official
suite reports must not turn deliberate retirement into noisy missing-work rows.

```bash
python3 Project/scripts/report.py --db Project/project.db --section port-lifecycle
```

## Shared Official Stance

All fixed-height official lanes require:

```text
runtime_surface = docker
peer_mode = local_reference
peer = REFERENCE_P2P_PEER on REFERENCE_DOCKER_NETWORK
byte_source = local_reference_p2p
proof_mode = p2p_sync
outbound P2P sockets use TCP_NODELAY
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

`TCP_NODELAY` is baseline P2P socket hygiene, not a special benchmark
optimization. Ports should set it explicitly on outbound Bitcoin P2P sockets or
document a runtime default that already does so. This keeps local Reference
Docker proofs and real external-peer probes on the same expected node posture.

## Gate Requirements

### `baseline_5k`

Required:

- Target/header height `5000`.
- Expected hash `000000000e3cb5b92e9765ed9c80c6b06f3d0a186478b330dd5e6b274acf03e2`.
- `chainstate_utxo_count=4574`.
- Clean port-owned script corpus proof: `port.script_corpus_result.v1`,
  `fixture_count=45`, `passed=45`, `failed=0`.
- Canonical final artifact timing with `timing_summary.total_ms` and
  `timing_summary.stage_totals_ms`.
- Final artifact timing buckets: `p2p_fetch`, `block_parse_validate`,
  `utxo_load`, `script_verify`, `utxo_apply`, `commit`, and
  `block_connect_store_commit`.

Live chat telemetry is optional for 5k because the run is intentionally short.

### `shakedown_50k`

Required:

- Target/header height `50000`.
- Expected `chainstate_utxo_count=568855`.
- Clean `benchmark.telemetry_tick.v1` progress with lifecycle markers,
  15-second target heartbeats, active-block context, and
  `telemetry_summary.telemetry_quality=clean` in the final artifact.
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
- Full `benchmark.telemetry_tick.v1` progress. A port should not attempt this
  lane as current evidence until its latest `shakedown_50k` proof reports
  `telemetry_quality=clean`.
- Slow-block and script-family summaries where the port can provide them.
- Complete timing import into Project.

This is the primary performance comparison lane for optimization work.

### `post_100k_to_tip`

Required:

- Resume from the port's own durable product state at or beyond current
  `performance_100k` truth. If the observed source state is exactly height
  `100000`, it must match the expected 100k hash and
  `chainstate_utxo_count=13154991`.
- Source-state readiness is checked through the Project-visible
  `docker_status_100k` command. The check is read-only and classifies missing,
  below-100k, hash-mismatched, UTXO-mismatched, or unparseable state before any
  sync run starts.
- Project does not archive or restore state for this lane. Ports run like
  products: inspect durable state, reconnect, continue, or report failure.
- `fresh_state=false`, `source_state_origin=port_durable_state`, and
  `proof_mode=p2p_sync`.
- Finish height/hash selected from local Reference Core before the run.
- Final validated height/hash match the selected Reference finish height/hash.
- Full control-owned telemetry and timing buckets, no blocker, no skipped
  consensus rules.

This is the immediate tip-readiness lane after 100k. It is not the later
empty-state `tip_once` audit.

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

Benchmark telemetry is Project/control-plane instrumentation. Ports should expose
the product progress surface in
[`PORT_PROGRESS_CONTRACT.md`](PORT_PROGRESS_CONTRACT.md); Project converts that
surface into benchmark ticks, telemetry summaries, and canonical artifacts.
Old port-authored benchmark ticks remain import-compatible as historical
archaeology. Current active-port benchmark evidence for `baseline_5k`,
`shakedown_50k`, and `performance_100k` must be control-built from
`rb.port_progress`. New active benchmark runs must not commit port-authored
benchmark JSON under `Nodes/Shared/conformance/results/`; any local port JSON is
ignored debug output.

Long runs (`shakedown_50k`, `performance_100k`, `post_100k_to_tip`,
`tip_once`, and `tip_maintenance`) must emit lines consumable by
`Project/scripts/monitor_benchmark_telemetry.py`:

```text
benchmark.telemetry_tick {"schema":"benchmark.telemetry_tick.v1", ...}
```

Required tick fields:

```text
schema
port
gate
run_id
event
phase
height
target_height or tip mode
percent when bounded
elapsed_ms
monotonic_ms
utxos
current_blocker
stall_class
current_block_elapsed_ms
current_block_height
current_block_hash
current_block_tx_count
current_block_vin_count
current_block_script_input_count
rate_recent_blocks_per_second
rate_total_blocks_per_second
last_block_ms
timing_buckets_ms
```

Required lifecycle events:

```text
run_started
container_started
node_started
first_peer_byte
first_block_connected
target_reached
run_finished
```

Canonical phases are `startup`, `peer_connect`, `header_sync`, `block_fetch`,
`block_connect`, `commit`, `heartbeat`, `complete`, and `failed`.

Canonical stall classes are `none`, `startup_wait`, `peer_wait`,
`header_wait`, `block_wait`, `block_connect_slow`, `commit_slow`,
`process_crashed`, `validation_blocker`, and `artifact_validation_failed`.
Slow blocks are reported as `phase=block_connect` with
`stall_class=block_connect_slow`; they are not generic failures.

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
python3 Project/scripts/validate_benchmark_telemetry.py \
  --gate shakedown_50k \
  --target-height 50000 \
  --require-clean \
  <log>
```

## Project Acceptance

Project owns current benchmark truth:

```bash
python3 Nodes/Shared/conformance/tools/validate_benchmark_artifact.py --gate baseline_5k --artifact Nodes/Shared/conformance/results/<port>_*.json --strict-current
python3 Project/scripts/import_all.py --db Project/project.db --rebuild
python3 Project/scripts/report.py --db Project/project.db --section benchmark-suite
python3 Project/scripts/report.py --db Project/project.db --section leaderboard --gate shakedown_50k
python3 Project/scripts/preflight_benchmark_gate.py --db Project/project.db --gate baseline_5k --all
python3 Project/scripts/preflight_benchmark_gate.py --db Project/project.db --gate shakedown_50k --all
python3 Project/scripts/preflight_benchmark_gate.py --db Project/project.db --gate performance_100k --all
```

Historical artifacts remain in `Nodes/Shared/conformance/results/`, but the
official suite reports only the current gates above. Historical import remains
compatibility-friendly; current campaign acceptance is not. Fresh active
benchmark evidence in shared results must be Project/control-built, must pass
`validate_benchmark_artifact.py`, and must import with
`artifact_quality=canonical`. Long-run evidence must also import with
`telemetry_quality=clean`.

Heartbeat validation is an observability check, not a scheduler-jitter trap.
Emitters should target 15 seconds or better. The telemetry validator warns on
small target drift, accepts bounded jitter, and rejects repeated large gaps or
any hard gap that means operators lost useful visibility.

Long-run product progress must be writer-owned. During `shakedown_50k`,
`performance_100k`, and tip gates, progress should come from the running sync
process or from a log/progress channel written by that process. Proof wrappers
must not depend on opening live RocksDB/chainstate state from a second sidecar
process while the sync writer is active; sidecar status reads are only
appropriate after the writer exits.

Leaderboards rank only current evidence with:

```text
result=passed
comparability_status=comparable
artifact_quality=canonical
telemetry_quality=clean for shakedown_50k, performance_100k, and tip gates
```

Noncanonical evidence remains visible in `current_benchmark_results` and gate
reports so operators can see what is missing, but it does not support current
rankings.

## Self-hosted lane

`self_hosted_5k`, `self_hosted_50k`, and `self_hosted_100k` are a separate
comparability class named `self_hosted`. A row is comparable with other
`self_hosted` rows at the same gate, across ports and host or Docker runs.
`artifact_quality` for this class is `self_hosted`, not `canonical`. Default
leaderboards and the canonical gate tables do not rank these rows against
canonical rows. The suite report's Self-hosted heading is a diagnostic
cross-reference: each row's `script_verify` beside that port's own canonical
`c_binding` row at the same height. The native store reports WAL as not
applicable. The recorded backend differences are `crypto_backend=own_curve`
and `chainstate_backend=native`.

## Independent reusable crypto lanes

`own_curve`, `ecosystem_curve`, and `c_binding` are independent dependency
categories, not readiness levels. Existing official baseline/native requirements
remain the C-binding comparison surface. The reusable own-curve 5k experiment
has separate commands, validators and Project results; it never replaces a
canonical baseline artifact or its leaderboard entry.

own_curve permits standard-library hashing, utilities and big integers, but no
existing elliptic-curve implementations, direct/transitive external production
dependencies without documented exceptions, or crypto FFI. ecosystem_curve
permits declared, pinned ecosystem curves, including Zig's standard-library
curve. C wrappers are bindings. The policy applies to standalone package
production dependencies; a node's RocksDB binding remains outside that boundary.

Each package must build independently, expose only public-input verification
operations, preserve explicit encoding/error semantics and integrate through a
thin node adapter. Test-only reference builds are pinned; candidate builds must
exclude alternative crypto backends. Trace/fault-injection builds are distinct
from measured candidate-only builds. Record library source digests, arithmetic
and hashing providers, toolchains, compiler settings and actual selected backend.

Project assembles `rb.crypto_lane_result.v1` artifacts from writer progress,
selecting results by port, lane, implementation and milestone. New evidence is
queried with `python3 Project/scripts/report.py --section crypto-lanes`.
Existing historical Zig artifacts retain their original identities and do not
become new own_curve proofs. New implementations remain experimental. A 5k
proof leaves `binary_gate_status=not_attempted`.
