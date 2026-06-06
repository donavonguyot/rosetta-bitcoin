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
python3 Project/scripts/report.py --db Project/project.db --section benchmark-gates
python3 Project/scripts/report.py --db Project/project.db --section benchmark-comparability
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
`performance_100k`, `tip_once`, and `tip_maintenance`. Historical 10k and
50k-to-100k artifacts may still import, but they are not official gates.
Project lifecycle rows decide whether missing future gates are active work,
active-development runway, or deliberate baseline retirement.

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
tails are operational state, not committed evidence. The runner updates
`Nodes/Shared/conformance/current_evidence.json` only after the fresh artifact
passes shape, stance, timing, telemetry, and anomaly checks. A failed command,
missing artifact, ambiguous artifact selection, rejected artifact, or suspicious
regression pauses the campaign instead of moving to the next port.

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
metrics remain report-only until the first inventory shows comparable data worth
ratcheting.

Some ports expose optional lane commands. C++ currently reports
`test_core_regression`, `test_wire_codec`, `test_runtime_smoke`, and
`test_coverage_core` so its historically broad suite is visible by domain.
Those lanes are informational unless a port explicitly claims them; they are not
cross-port baseline requirements.

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
  "select * from benchmark_gate_matrix order by target_height, port"

sqlite-utils query Project/project.db \
  "select * from benchmark_comparability order by target_height, port"

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
