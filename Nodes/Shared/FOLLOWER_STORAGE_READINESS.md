# Follower Storage Readiness Projection

Current follower storage readiness is Project mission-control knowledge, not a
hand-maintained Markdown matrix. Query Project for current imported port status,
storage/conformance results, Docker coverage, and command surfaces:

```bash
python3 Project/scripts/import_all.py --db Project/project.db --rebuild
python3 Project/scripts/report.py --db Project/project.db --section port-status
python3 Project/scripts/report.py --db Project/project.db --section conformance
python3 Project/scripts/report.py --db Project/project.db --section docker-coverage

python3 Project/scripts/query_db.py \
  --sql "select port, validated_height, chainstate_backend, chainstate_status from latest_port_status order by port"

python3 Project/scripts/query_db.py \
  --sql "select port, category, result, result_count, max_validated_height from conformance_summary order by port, category, result"
```

## Readiness Definition

A follower is storage-ready for serious Core/native work only when imported
evidence shows:

- an explicit native chainstate backend;
- RocksDB runtime truth in native/Core paths;
- restart/rebuild behavior covered by the storage gate;
- status truth reported from the active backend;
- Docker proof or supervisor coverage when claiming Docker readiness;
- compact proof JSON preserved under `Nodes/Shared/conformance/results/`.

Storage readiness does not imply consensus clearance, Docker contract
completion, benchmark parity, or binary-gate passage. Keep those gates separate
in Project reports.

## Durable Guidance

- Java remains the lead extraction source for shared storage lessons.
- Python's historical blocker trail is handoff evidence only.
- Ports may keep legacy/reference storage tools only when they are explicitly
  named as non-Core evidence surfaces.
- Serious-port optimization should target the active native backend and shared
  timing buckets, not observer stores.

See `storage/STORAGE_GATE.md`, `chainstate/CHAINSTATE_STORE.md`, and
`storage/ENGINE_DECISION.md` for the durable contracts and storage decision.
