# Documentation Index

This directory holds shared workspace documentation. Prefer updating one of the
canonical docs below instead of adding a one-off plan file.

## Canonical Status And Policy

- `port-status.md` - current all-port baseline; status claims must stay
  conservative and proof-backed.
- `git-topology.md` - root repository, port directory, and artifact ownership.
- `artifact-retention.md` - proof/log/datadir retention policy.
- `storage-contract.md` - project-level storage compliance rules.
- `supervisor-contract.md` - durable supervisor behavior and tick expectations.
- `follower-port-matrix.md` - conservative blocker-clearance matrix.

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
