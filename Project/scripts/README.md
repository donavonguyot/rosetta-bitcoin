# Project Scripts

Scripts in this directory should import observations into `Project/project.db`
or generate reports from it.

They must not mutate node operational datadirs.

## Expected Script Types

```text
init_project_db
import_status_snapshot
import_blocker_ledger
import_conformance_results
import_benchmark_results
generate_reports
```

## Conformance Import

Import a NodeCore result JSON after a port has completed its local proof:

```bash
python3 Project/scripts/import_conformance_results.py \
  --db Project/project.db \
  NodeCore/conformance/results/java_rocksdb_codec_v2_storage_shared_2026-06-01.json
```

Aggregate storage-gate files are expanded so each entry in `results[]` becomes
one row in `conformance_results`. The original exported JSON remains preserved
in `raw_json`.

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

Node runtimes should emit JSON and let Project scripts perform SQLite writes.

## Import Boundary

Imports should accept exported JSON or text summaries produced by a node. They
should not open a node's chainstate backend directly unless the operation is
explicitly read-only and documented as an observer import.
