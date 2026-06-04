# Project Scripts

Scripts in this directory import observations into `Project/project.db` or
generate reports from it. `Project/project.db` is the tracked mission-control
database; port-local operational SQLite remains forbidden for native/Core node
truth.

They must not mutate node operational datadirs.

Use SQLite Utils as the operator interface:

```bash
sqlite-utils tables Project/project.db --counts
sqlite-utils query Project/project.db \
  "select node_id, max(validated_height) as validated_height from status_snapshots group by node_id order by node_id"
```

## Import Everything

Rebuild Project from canonical Shared results, Docker manifests, selected status
exports, blocker ledgers, and seeded decisions:

```bash
python3 Project/scripts/import_all.py --db Project/project.db --rebuild
```

The importer is deterministic and idempotent. Running it again without
`--rebuild` should leave row counts stable.

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
python3 Project/scripts/report.py --db Project/project.db --section command-surface
python3 Project/scripts/report.py --db Project/project.db --section blocker-matrix
python3 Project/scripts/report.py --db Project/project.db --section docker-coverage
python3 Project/scripts/report.py --db Project/project.db --section benchmark-gates
python3 Project/scripts/report.py --db Project/project.db --section benchmark-comparability
```

Preflight a benchmark gate before starting a port run:

```bash
python3 Project/scripts/preflight_benchmark_gate.py \
  --db Project/project.db \
  --gate supporting_5k \
  --port go

python3 Project/scripts/preflight_benchmark_gate.py \
  --db Project/project.db \
  --gate supporting_5k \
  --all
```

The preflight is read-only. It checks Project mission-control rows for the
preferred command surface, Docker contract posture, local-reference P2P mode,
durable proof volume, and required metadata stance such as
`rocksdb_wal_disabled=false`, `header_target_height=5000`, `prefetch_depth=4`,
`script_runner_mode=parallel`, and `fresh_state=true`. It does not fail merely
because a port has no gate result yet; missing evidence means the run still
needs to happen.

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
  "select * from follower_blocker_matrix order by height, port"

sqlite-utils query Project/project.db \
  "select * from benchmark_gate_matrix order by target_height, port"

sqlite-utils query Project/project.db \
  "select * from benchmark_comparability order by target_height, port"
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

Node runtimes should emit JSON and let Project scripts perform Project SQLite
writes. Runtime code should not write `Project/project.db` directly.

## Import Boundary

Imports should accept exported JSON or text summaries produced by a node. They
should not open a node's chainstate backend directly unless the operation is
explicitly read-only and documented as an observer import.
