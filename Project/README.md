# Project

`Project/` is the RosettaBitcoin mission-control layer. It compares language
ports, stores exported run metadata, indexes compact proof artifacts, and
produces reports. It is not part of any node's consensus or sync machinery.

## Files

```text
Project/
  schema.sql
  project.db       # tracked mission-control SQLite DB
  scripts/
```

## Boundary

Project mission-control DB is allowed and preferred for observations:

- node registry
- run history
- exported status snapshots
- blocker ledger entries
- conformance results
- benchmark results
- Docker contract state
- standardized port command surfaces
- architecture decisions

Project mission-control DB must not store operational truth used by node runtimes:

- active UTXO set
- authoritative validated tip
- headers required for sync
- block index required for block retrieval
- undo data
- peer state required for node operation

Ports export observations into `Project/project.db`. They do not read from it to
validate blocks, select tips, fetch UTXOs, enforce blockers, or report live
runtime truth.

## Operator Interface

Use SQLite Utils for Project inspection:

```bash
sqlite-utils tables Project/project.db --counts
sqlite-utils query Project/project.db \
  "select * from latest_port_status order by port"
```

Mission-control projections are also available through the report script:

```bash
python3 Project/scripts/report.py --db Project/project.db --section port-status
python3 Project/scripts/report.py --db Project/project.db --section blocker-matrix
python3 Project/scripts/report.py --db Project/project.db --section docker-coverage
python3 Project/scripts/report.py --db Project/project.db --section command-surface
python3 Project/scripts/report.py --db Project/project.db --section benchmark-suite
python3 Project/scripts/report.py --db Project/project.db --section leaderboard --gate shakedown_50k
sqlite-utils query Project/project.db \
  "select * from benchmark_leaderboard where gate_id='shakedown_50k' order by rank"
```

Current benchmark leaderboards rank only canonical artifacts: passed,
comparable, self-validated proof JSON imported with `artifact_quality=canonical`.
Older proof files may still import for audit without supporting current ranks.

Rebuild mission control from canonical evidence:

```bash
python3 Project/scripts/import_all.py --db Project/project.db --rebuild
```
