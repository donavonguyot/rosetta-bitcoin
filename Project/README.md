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

Project SQLite is allowed and preferred for mission-control observations:

- node registry
- run history
- exported status snapshots
- blocker ledger entries
- conformance results
- benchmark results
- Docker contract state
- architecture decisions

Project SQLite must not store operational truth used by node runtimes:

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
  "select port, status from docker_contracts order by port"
```

Rebuild mission control from canonical evidence:

```bash
python3 Project/scripts/import_all.py --db Project/project.db --rebuild
```
