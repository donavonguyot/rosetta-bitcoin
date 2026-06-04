# Documentation Index

This directory holds shared workspace documentation. Prefer updating one of the
canonical docs below instead of adding a one-off plan file.

## Project Projections

- `port-status.md` - how to query Project for the current all-port projection.
- `follower-port-matrix.md` - how to query Project for the blocker matrix.

These pages do not own repeated status rows. Rebuild/import Project and query
`Project/project.db` for mission-control status:

```bash
python3 Project/scripts/import_all.py --db Project/project.db --rebuild
python3 Project/scripts/report.py --db Project/project.db --section port-status
python3 Project/scripts/report.py --db Project/project.db --section blocker-matrix
```

## Canonical Policy

- `git-topology.md` - root repository, port directory, and artifact ownership.
- `artifact-retention.md` - proof/log/datadir retention policy.
- `storage-contract.md` - project-level storage compliance rules.
- `supervisor-contract.md` - durable supervisor behavior and tick expectations.

## Durable Lessons

- `consensus-blockers-testnet4.md` - shared blocker facts and fixture anchors.
- `script-semantics-gotchas.md` - consensus/script traps learned from blockers.
- `blocker-ledger.md` - blocker record shape and classification rules.
- `port-performance-lessons.md` - reusable performance lessons.
- `../Nodes/Shared/conformance/BENCHMARK_CONTRACT.md` - the primary cross-port
  `100k` durable benchmark, timing buckets, and artifact naming.
- `checkpoint-strategy.md` - checkpoint and snapshot guidance.
- `native-crypto-contract.md` - native crypto expectations.
- `agent-prompts.md` - reusable prompts for agents.

## Cleanup Rule

Completed implementation plans should not remain as living Markdown. Extract
still-current rules into canonical docs, then delete the plan file or move the
facts into `Nodes/Shared/` contracts.
