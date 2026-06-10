# Project Scripts

Scripts in this directory import observations into `Project/project.db` or
generate reports from it. `Project/project.db` is the tracked mission-control
database; native/Core node truth belongs in each port's approved operational
storage.

They must not mutate node operational datadirs.

Use SQLite Utils as the operator interface:

```bash
sqlite-utils tables Project/project.db --counts
sqlite-utils query Project/project.db \
  "select node_id, max(validated_height) as validated_height from status_snapshots group by node_id order by node_id"
```

## Import Current Evidence

Rebuild Project from the curated current evidence index, Docker manifests, the
Shared consensus rule ledger, selected status exports, blocker ledgers, and
seeded decisions:

```bash
python3 Project/scripts/import_all.py --db Project/project.db --rebuild
```

Current result JSON is selected by
`Nodes/Shared/conformance/current_evidence.json`. Historical result JSON remains
on disk but is not imported into current Project status by default.

The importer is deterministic and idempotent. Running it again without
`--rebuild` should leave row counts stable.

For explicit archaeology, import the full historical result archive:

```bash
python3 Project/scripts/import_all.py --db Project/project.db --rebuild --include-history
```

In a dirty workspace with active untracked port evidence, rebuild the tracked DB
from committed artifacts only:

```bash
python3 Project/scripts/import_all.py --db Project/project.db --rebuild --tracked-only
```

## Script Types

```text
import_all
import_status_snapshot
import_blocker_ledger
import_conformance_results
import_benchmark_results
generate_reports
```

Print an on-demand Markdown summary:

```bash
python3 Project/scripts/report.py --db Project/project.db --list-sections
python3 Project/scripts/report.py --db Project/project.db --section all
python3 Project/scripts/report.py --db Project/project.db --section port-status
python3 Project/scripts/report.py --db Project/project.db --section current-evidence
python3 Project/scripts/report.py --db Project/project.db --section historical-evidence-candidates
python3 Project/scripts/report.py --db Project/project.db --section command-surface
python3 Project/scripts/report.py --db Project/project.db --section test-commands
python3 Project/scripts/report.py --db Project/project.db --section test-coverage
python3 Project/scripts/report.py --db Project/project.db --section critical-test-domains
python3 Project/scripts/report.py --db Project/project.db --section blocker-matrix
python3 Project/scripts/report.py --db Project/project.db --section docker-coverage
python3 Project/scripts/report.py --db Project/project.db --section port-lifecycle
python3 Project/scripts/report.py --db Project/project.db --section benchmark-suite
python3 Project/scripts/report.py --db Project/project.db --section leaderboard
python3 Project/scripts/report.py --db Project/project.db --section leaderboard --gate shakedown_50k
python3 Project/scripts/report.py --db Project/project.db --section 50k-leaderboard
python3 Project/scripts/report.py --db Project/project.db --section benchmark-gates
python3 Project/scripts/report.py --db Project/project.db --section baseline-5k
python3 Project/scripts/report.py --db Project/project.db --section shakedown-50k
python3 Project/scripts/report.py --db Project/project.db --section performance-100k
python3 Project/scripts/report.py --db Project/project.db --section consensus-runway
```

Preflight a benchmark gate before starting a port run:

```bash
python3 Project/scripts/preflight_benchmark_gate.py \
  --db Project/project.db \
  --gate baseline_5k \
  --port go

python3 Project/scripts/preflight_benchmark_gate.py \
  --db Project/project.db \
  --gate shakedown_50k \
  --port go

python3 Project/scripts/preflight_benchmark_gate.py \
  --db Project/project.db \
  --gate performance_100k \
  --all
```

The preflight is read-only. It checks Project mission-control rows for the
preferred command surface, Docker contract posture, local-reference P2P mode,
durable proof volume, and required metadata stance such as
`rocksdb_wal_disabled=false`, the gate-specific `header_target_height`,
`prefetch_depth=4`, `script_runner_mode=parallel`, and `fresh_state=true`. It
does not fail merely because a port has no gate result yet; missing evidence
means the run still needs to happen.

The official benchmark suite is `baseline_5k`, `shakedown_50k`,
`performance_100k`, `post_100k_to_tip`, `tip_once`, and `tip_maintenance`.
Historical 10k and 50k-to-100k artifacts may still import, but they are not
official gates.
Project lifecycle rows decide whether missing future gates are active work,
active-development runway, or deliberate baseline retirement.

`post_100k_to_tip` resumes the port's own durable Docker state at or beyond
the current `performance_100k` truth. Project does not archive, restore, or
preserve benchmark-owned state for this lane. If a port has no usable durable state,
the product run must report that truthfully or rebuild state through its normal
sync path; Project only observes the product progress and validates the final
control-built artifact.

Before any unattended post-100k run, check the source state explicitly. This is
read-only: it runs each port's `docker_status_100k` command, reports the source
height/hash/UTXO count, and captures the local Reference finish height/hash
without starting sync:

```bash
python3 Project/scripts/report.py \
  --db Project/project.db \
  --section post-100k-readiness
```

Use the verbose preflight when JSON or structural command details are needed:

```bash
python3 Project/scripts/preflight_benchmark_gate.py \
  --db Project/project.db \
  --gate post_100k_to_tip \
  --all \
  --check-source-state \
  --json
```

Expected source-state statuses are `ready`, `state_missing`, `below_100k`,
`hash_mismatch`, `utxo_mismatch`, `status_unparseable`, or
`command_missing`. Missing or stale source state is a truthful `not_ready`
condition for this lane, not something Project repairs during a campaign.
`post_100k_to_tip` starts only from port-owned durable product state at or
beyond 100k; if that state is missing, below 100k, or cannot report
height/hash/UTXO truth, the port is not ready for this lane.

## Serialized Benchmark Campaigns

Use the campaign runner when a gate needs to move through several ports without
losing operator control. It is strictly serial: preflight, warm, proof, artifact
validation, Project import, then the next port. Dry-run is the default:

```bash
python3 Project/scripts/run_benchmark_campaign.py \
  --db Project/project.db \
  --gate shakedown_50k \
  --all \
  --dry-run
```

Start an actual run only when ready:

```bash
python3 Project/scripts/run_benchmark_campaign.py \
  --db Project/project.db \
  --gate shakedown_50k \
  --ports rust,go,csharp \
  --run
```

Resume a paused campaign from its ignored local state file:

```bash
python3 Project/scripts/run_benchmark_campaign.py \
  --campaign Project/.campaigns/<campaign_id>/state.json \
  --resume
```

Campaign scratch lives under ignored `Project/.campaigns/`. Logs and telemetry
tails are operational state, not committed evidence. Active ports expose product
progress with `rb.port_progress`; the Project control harness turns that into
benchmark telemetry and canonical artifacts. Old port-authored benchmark
artifacts remain import-compatible as historical archaeology, but new active
benchmark runs must not commit port-authored benchmark JSON under
`Nodes/Shared/conformance/results/`.

The runner updates `Nodes/Shared/conformance/current_evidence.json` only after
the fresh control-built artifact passes the shared benchmark artifact validator,
Project import, and anomaly checks. Compatibility artifact fallback is explicit
and historical-only by default. For `shakedown_50k`,
`performance_100k`, `post_100k_to_tip`, and tip gates, the runner also validates control-owned
telemetry with `validate_benchmark_telemetry.py` and requires
`telemetry_quality=clean`. A failed command, missing product progress or
artifact, rejected artifact, telemetry rejection, or suspicious regression
pauses the campaign instead of moving to the next port.

Long-run heartbeat validation uses a 15-second target with bounded jitter
tolerance. Small scheduling drift is reported as a warning and can still be
`telemetry_quality=clean`; repeated large gaps or any hard gap reject the run
because operators lost useful visibility.

Long-run product progress should be emitted by the sync writer or by a
writer-owned log channel. Campaign proofs should not rely on a second sidecar
process opening live RocksDB/chainstate state while the writer is active;
sidecar status reads are reserved for final post-exit status capture.

Use the progress posture report before changing emitters:

```bash
python3 Project/scripts/report.py --db Project/project.db --section port-progress-posture
```

`writer_owned` is the required steady-state product posture. Low-maintenance
direct emitters should stay direct. C# and Java may still have wrapper control
plumbing, but that wrapper work is limited to launch, benchmark control, progress
pass-through, and final status collection; it is not a separate product-progress
posture.

For long-run gates, the campaign runner also applies a startup visibility
timeout. If `first_block_connected` is not observed within the configured
window, the proof is terminated and recorded as failed before operators spend a
full 100k run on a blind supervisor path. Override with
`--startup-timeout-sec <seconds>` when intentionally testing slower startup.

For assisted evidence collection, use `--assisted --pause-on never`. Assisted
mode records failed or rejected ports, preserves candidates under the ignored
campaign directory, and continues to the next port. It still updates current
evidence only for artifacts that pass validation and Project preflight.

## Parallel Development Campaigns

Use the parallel campaign runner when the goal is fast development comparison or
single-Reference topology stress. It warms ports serially, then launches the
proof commands concurrently against the same local Reference P2P node. The
default launch order is intentionally reverse-weighted:
`ocaml,java,csharp,swift,go,cpp,zig,rust`.

Parallel campaigns are not the serial audit lane. They do not update
`Nodes/Shared/conformance/current_evidence.json`, rebuild or import
`Project/project.db`, or replace current-evidence leaderboards. Logs and JSON
summaries stay under ignored `Project/.campaigns/`.

```bash
python3 Project/scripts/run_parallel_benchmark_campaign.py \
  --gate baseline_5k \
  --dry-run

python3 Project/scripts/run_parallel_benchmark_campaign.py \
  --gate shakedown_50k \
  --run

python3 Project/scripts/run_parallel_benchmark_campaign.py \
  --gate performance_100k \
  --run \
  --compare-to Project/.campaigns/<old>/parallel_reference_performance_100k/summary.json
```

The summary schema is `benchmark.parallel_experiment`. It records field wall
time, per-port outcomes, final product progress, proof/warm log paths, and
selected timing buckets. A comparison run writes `comparison.json` with
per-port development classes such as `improved`, `regressed`, `recovered`, and
`new_failure`.

`Project/scripts/run_parallel_reference_smoke.py` remains as a compatibility
wrapper for older prompts, but new work should call
`run_parallel_benchmark_campaign.py` directly.

Validate a benchmark artifact directly:

```bash
python3 Nodes/Shared/conformance/tools/validate_benchmark_artifact.py \
  --gate shakedown_50k \
  --artifact Nodes/Shared/conformance/results/<port>_*.json \
  --strict-current
```

Validate a long-run proof log directly:

```bash
python3 Project/scripts/validate_benchmark_telemetry.py \
  --gate shakedown_50k \
  --target-height 50000 \
  --require-clean \
  Project/.campaigns/<campaign_id>/logs/<port>_proof.log
```

Historical artifacts may still import for archaeology. Current evidence used by
campaigns and leaderboards must import with `artifact_quality=canonical`; long
runs must also import with `telemetry_quality=clean`.

Preflight the full 5k baseline after importing evidence:

```bash
python3 Project/scripts/preflight_port_baseline.py \
  --db Project/project.db \
  --port go \
  --strict

python3 Project/scripts/preflight_port_baseline.py \
  --db Project/project.db \
  --all
```

The strict baseline combines the comparable 5k gate with RocksDB, native crypto,
script-corpus, UTXO accounting, timing buckets, and Docker command-surface
evidence. The `--all` form is report-only unless `--strict` is also supplied.

Validate a port-owned script-corpus artifact before importing it:

```bash
python3 Nodes/Shared/conformance/tools/validate_script_corpus_result.py \
  Nodes/Shared/conformance/results/go_script_corpus_2026-06-04.json
```

Only `schema=port.script_corpus_result.v1` artifacts count as port corpus proof.
`shared.script_fixtures.validation.v1` remains manifest validation only.

Preflight the consensus runway after importing evidence:

```bash
python3 Project/scripts/preflight_consensus_runway.py \
  --db Project/project.db \
  --port go \
  --stage corpus \
  --strict

python3 Project/scripts/preflight_consensus_runway.py \
  --db Project/project.db \
  --port go \
  --stage 5k \
  --strict
```

The runway stages are `corpus`, `5k`, `50k`, `100k`, `tip_once`, and
`tip_maintenance`. The
preflight checks Project's imported rule ledger, blocker state, port-owned
script-corpus proof, 5k baseline posture, and staged sync evidence.

Preflight test and coverage visibility without running every port suite:

```bash
python3 Project/scripts/capture_test_coverage.py \
  --db Project/project.db \
  --all \
  --dry-run

python3 Project/scripts/preflight_test_coverage.py \
  --db Project/project.db \
  --all \
  --level inventory

python3 Project/scripts/preflight_test_coverage.py \
  --db Project/project.db \
  --all \
  --level baseline-par
```

`baseline-par` checks active-contender unit-test command visibility. Coverage
metrics are optional local telemetry and are not part of default par.

Capture compact product-test telemetry only when you actually want to run port
suites:

```bash
python3 Project/scripts/capture_test_coverage.py \
  --db Project/project.db \
  --port cpp \
  --run
```

The capture script is dry-run by default. It records `test_unit` results for
active contender and active-development ports and writes curated JSON under
`Nodes/Shared/testing/results/`. Baseline-retired ports remain visible in
dry-run output and can be captured explicitly with `--port`, but `--all --run`
does not force new work onto retired ports. These artifacts use stable schemas:
`port.test_result`, `port.coverage_summary`, and `port.domain_coverage`.
Coverage capture requires `--include-coverage` and an explicitly supported
command. Benchmark correctness stays in benchmark preflights, not port unit
tests.

Test capability contracts answer whether a port has a safety net for a specific
optimization or experiment. They do not use maturity levels or naked case-count
claims:

```bash
python3 Project/scripts/report.py \
  --db Project/project.db \
  --section test-capabilities

python3 Project/scripts/report.py \
  --db Project/project.db \
  --section test-capability-gaps

python3 Project/scripts/report.py \
  --db Project/project.db \
  --section experiment-readiness

python3 Project/scripts/report.py \
  --db Project/project.db \
  --section full-node-capabilities

python3 Project/scripts/report.py \
  --db Project/project.db \
  --section full-node-gaps

python3 Project/scripts/report.py \
  --db Project/project.db \
  --section full-node-readiness
```

See `Nodes/Shared/testing/TEST_CAPABILITY_CONTRACT.md` for the artifact schema,
allowed provenance classes, and the rule that denominators require a named suite
with a version and hash.

Full-node capability reports sit beside benchmark gates. They separate validated
replay competence from network-peer behavior: public peer sync, inbound serving,
mempool relay, reorgs, crash recovery, restart soak, and adversarial/resource
safety. Canonical clean `tip_once` and `tip_maintenance` evidence can derive the
matching full-node rows; other full-node rows remain missing until explicit
port-owned capability artifacts prove them.

Crypto experiment readiness uses dedicated command keys:

```bash
python3 Project/scripts/report.py --db Project/project.db --section test-commands
cd Nodes/<Port> && make test-crypto-vectors
cd Nodes/<Port> && make test-block-connect-backend
```

These commands emit capability artifacts under `Nodes/Shared/testing/results/`.
Missing rows are valid evidence of absence; do not promote old native-sync
artifacts into BIP340 or libsecp256k1-equivalence passes.

Test coverage reports are for standalone product-node quality: consensus,
storage, P2P, runtime smoke, and status/reporting behavior. Benchmark gates,
telemetry schemas, timing buckets, and proof artifact comparability are validated
by the benchmark and baseline preflights instead:

```bash
python3 Project/scripts/preflight_benchmark_gate.py \
  --db Project/project.db \
  --gate baseline_5k \
  --all

python3 Project/scripts/preflight_port_baseline.py \
  --db Project/project.db \
  --all
```

Warm the port image before a benchmark campaign, then run fresh proof volumes
without rebuilding unless a clean rebuild is intentional:

```bash
sqlite-utils query Project/project.db \
  "select port, command from port_command_surface where command_key='docker_warm' order by port"

cd Nodes/<Port> && make docker-warm
sqlite-utils query Project/project.db \
  "select port, command from port_command_surface where command_key='docker_proof_local' order by port"
# Run docker_proof_local only for the official local Reference P2P lane.
# Add DOCKER_REBUILD=1 only for an intentional rebuild.

sqlite-utils query Project/project.db \
  "select port, command from port_command_surface where command_key='docker_proof_rpc_replay' order by port"
# RPC replay proof is evidence-only and is not ranked against P2P sync runs.
```

Project exposes stable projection views for direct queries:

```bash
sqlite-utils query Project/project.db \
  "select * from latest_port_status order by port"

sqlite-utils query Project/project.db \
  "select * from docker_coverage order by port"

sqlite-utils query Project/project.db \
  "select port, command_key, supported, command from port_command_surface order by port, command_key"

sqlite-utils query Project/project.db \
  "select port, baseline_par_status, coverage_control_status from test_coverage_matrix order by port"

sqlite-utils query Project/project.db \
  "select port, domain, domain_status, evidence from critical_test_domain_coverage order by port, domain"

sqlite-utils query Project/project.db \
  "select * from follower_blocker_matrix order by height, port"

sqlite-utils query Project/project.db \
  "select * from current_benchmark_results order by gate_id, port"

sqlite-utils query Project/project.db \
  "select * from benchmark_leaderboard where gate_id='shakedown_50k' order by rank"

sqlite-utils query Project/project.db \
  "select port, gate_id, artifact_quality from current_benchmark_results order by gate_id, port"

sqlite-utils query Project/project.db \
  "select * from port_baseline_5k order by port"

sqlite-utils query Project/project.db \
  "select * from consensus_runway order by port, target_height"
```

Generated reports are stdout-only. Do not add or commit a generated
`Project/reports/` tree.

## Conformance Import

Import a Shared result JSON after a port has completed its local proof:

```bash
python3 Project/scripts/import_conformance_results.py \
  --db Project/project.db \
  Nodes/Shared/conformance/results/java_rocksdb_codec_v2_storage_shared_2026-06-01.json
```

Aggregate storage-gate files are expanded so each entry in `results[]` becomes
one row in `conformance_results`. Script-corpus files are expanded from
`fixtures[]`. The original exported JSON remains indexed in `artifacts.raw_json`.

Canonical proof files should live under:

```text
Nodes/Shared/conformance/results/<port>_<gate>_<surface>_<YYYY-MM-DD>.json
```

Do not import directly from port-local scratch datadirs when a canonical result
file exists. Port-local logs, DBs, RocksDB/LevelDB directories, and Docker
volumes are runtime artifacts, not Project evidence.

Import a status JSON emitted by a node:

```bash
python3 Project/scripts/import_status_snapshot.py \
  --db Project/project.db \
  --node-id csbitnode \
  /path/to/status.json
```

The importer is port-neutral. It reads `implementation`, `language`, and `role`
from the status JSON when present, and otherwise infers them from `--node-id`.
If `current_blocker` is present, it also records a blocker row keyed by
`node_id:height:txid:input_index`.

Node runtimes should emit JSON and let Project scripts perform Project DB
writes. Runtime code should not write `Project/project.db` directly.

## Import Boundary

Imports should accept exported JSON or text summaries produced by a node. They
should not open a node's chainstate backend directly unless the operation is
explicitly read-only and documented as an observer import.
