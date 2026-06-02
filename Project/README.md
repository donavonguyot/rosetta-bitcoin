# Project

`Project/` is the RosettaBitcoin management layer. It compares language ports,
stores exported run metadata, and produces reports. It is not part of any node's
consensus or sync machinery.

## Files

```text
Project/
  schema.sql
  project.db       # generated locally; ignored by root *.db rule
  reports/
  scripts/
```

## Boundary

Project SQLite may store:

- node registry
- run history
- exported status snapshots
- blocker ledger entries
- conformance results
- benchmark results
- architecture decisions

Project SQLite must not store operational truth used by nodes:

- active UTXO set
- authoritative validated tip
- headers required for sync
- block index required for block retrieval
- undo data
- peer state required for node operation

Ports export observations into `Project/project.db`. They do not read from it to
validate blocks.
