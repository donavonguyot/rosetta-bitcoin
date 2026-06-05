# Artifact Inventory Projection

Current artifact inventory is selected by `current_evidence.json` and imported
into `Project/project.db`. This Markdown file defines retention rules only; it
is not a live port-by-port cleanup list.

Use Project for current evidence rows:

```bash
python3 Project/scripts/import_all.py --db Project/project.db --rebuild

sqlite-utils query Project/project.db \
  "select port, claim, gate_id, imported, path from current_evidence_status order by port, claim"

sqlite-utils query Project/project.db \
  "select port, category, result, result_count, max_validated_height from conformance_summary order by port, category, result"

python3 Project/scripts/report.py --db Project/project.db --section conformance
python3 Project/scripts/report.py --db Project/project.db --section benchmark-summary
python3 Project/scripts/report.py --db Project/project.db --section current-evidence
python3 Project/scripts/report.py --db Project/project.db --section historical-evidence-candidates
```

## Canonical Project Evidence

Keep compact, committed proof JSON here:

```text
Nodes/Shared/conformance/results/
```

Cross-port benchmark JSON belongs in the same directory when it follows
`Nodes/Shared/conformance/BENCHMARK_CONTRACT.md`. Keep compact summaries, not
live datadirs, RocksDB directories, Docker volumes, or long logs.

`Nodes/Shared/conformance/current_evidence.json` is the curated working set for
current Project truth. Files under `results/` that are not referenced there are
historical evidence candidates, not current status inputs.

## Cross-Port Rules

| Pattern | Classification | Action |
|---------|----------------|--------|
| `Nodes/*/docs/BLOCKER_LEDGER.md` | port durable evidence | Keep; Project imports known ledgers. |
| `Nodes/*/tests/fixtures/**` | port durable evidence | Keep. |
| `Nodes/*/snapshots/*.json` | checkpoint evidence | Keep only when intentionally tracked by the port. |
| `Nodes/*/data*`, `blocks/`, `chainstate-rocksdb/`, `operational-*`, `utxo-*` | runtime state | Ignore; delete only if classified as scratch or explicitly approved. |
| Local DB files | runtime state | Ignore; delete scratch copies, not active primary datadirs. |
| `*.log`, `sync_*.log`, `sync_chunk_*.log`, `sync_catchup_*.log` | generated logs | Delete stale logs after preserving compact evidence. |
| `build*/`, `target/`, `dist/`, `_build/`, `deps/`, `node_modules/`, `.venv/` | generated build output | Ignore/delete when not needed for immediate validation. |
| `*.pid`, `.batch-sync-running`, `*.lock` | runtime markers | Delete only when the corresponding process is not running. |
| nested `.git/` directories | legacy cruft | Delete; the workspace has one root Git repository. |

## Preservation Rule

Before deleting bulky local evidence, preserve a compact JSON result under
`Nodes/Shared/conformance/results/` when it supports a current project claim,
add it to `current_evidence.json`, then rebuild Project so the artifact hash and
summary are indexed.

## Cleanup Guardrails

- Do not delete primary datadirs during active sync.
- Do not delete blocker ledgers, fixtures, or cited proof JSON.
- Do not commit live DBs or logs to root.
- Prefer regenerating proof JSON over preserving bulky local scratch trees.
