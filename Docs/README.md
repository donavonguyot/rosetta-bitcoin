# Documentation Index

This directory holds shared workspace documentation. Prefer updating one of the
canonical docs below instead of adding a one-off plan file.

## Project Projections

- `port-status.md` - how to query Project for the current all-port projection.
- `follower-port-matrix.md` - how to query Project for the blocker matrix.
- `../Nodes/Shared/consensus/CONSENSUS_RUNWAY.md` - how to query Project for
  corpus-to-tip consensus readiness.
- `../Nodes/Shared/conformance/BENCHMARK_CONTRACT.md` - official benchmark
  suite, telemetry requirements, and port lifecycle classifications.

These pages do not own repeated status rows. Rebuild/import Project and query
`Project/project.db` for mission-control status:

```bash
python3 Project/scripts/import_all.py --db Project/project.db --rebuild
python3 Project/scripts/report.py --db Project/project.db --section port-status
python3 Project/scripts/report.py --db Project/project.db --section port-lifecycle
python3 Project/scripts/report.py --db Project/project.db --section current-evidence
python3 Project/scripts/report.py --db Project/project.db --section blocker-matrix
python3 Project/scripts/report.py --db Project/project.db --section consensus-runway
```

## Canonical Policy

- `port-baseline-5k.md` - strict first readiness baseline for comparable ports.
- `git-topology.md` - root repository, port directory, and artifact ownership.
- `artifact-retention.md` - proof/log/datadir retention policy.
- `storage-contract.md` - project-level storage compliance rules.
- `supervisor-contract.md` - durable supervisor behavior and tick expectations.
- `../Nodes/Shared/README.md` - map of Shared contracts and runbooks.
- `../Nodes/Shared/storage/STORAGE_GATE.md` - storage gate expectations.
- `../Nodes/Shared/chainstate/CHAINSTATE_STORE.md` - native chainstate contract.
- `../Nodes/Shared/docker/DOCKER_RUNTIME_CONTRACT.md` - Docker runtime contract.

## Durable Lessons

- `consensus-blockers-testnet4.md` - shared blocker provenance and fixture anchors.
- `script-semantics-gotchas.md` - consensus/script traps learned from blockers.
- `blocker-ledger.md` - blocker record shape and classification rules.
- `port-performance-lessons.md` - reusable performance lessons.
- `../Nodes/Shared/conformance/BENCHMARK_CONTRACT.md` - official benchmark
  suite, lifecycle classifications, telemetry requirements, timing buckets, and
  artifact naming.
- `checkpoint-strategy.md` - checkpoint and snapshot guidance.
- `native-crypto-contract.md` - native crypto expectations.
- `../Nodes/Shared/consensus/NATIVE_CRYPTO.md` - shared native crypto API and vectors.
- `../Nodes/Shared/consensus/CRYPTO_BACKEND.md` - backend posture and per-port crypto reporting.
- `../Nodes/Shared/consensus/VALIDATION_PIPELINE.md` - consensus validation pipeline.
- `../Nodes/Shared/consensus/CONSENSUS_KNOWLEDGE_LEDGER.md` - rule ledger shape.
- `../Nodes/Shared/consensus/generated/rule_matrix.md` - generated rule coverage matrix.
- `../Nodes/Shared/sync/LIVE_TIP_MAINTENANCE.md` - live tip maintenance contract.
- `../Nodes/Shared/sync/OPERATIONAL_BLOCKERS.md` - operational blocker taxonomy.
- `../Nodes/Shared/replay/REPLAY_TELEMETRY.md` - replay telemetry contract.
- `agent-prompts.md` - reusable prompts for agents.

For baseline readiness, prefer Project over hand-maintained summaries:

```bash
python3 Project/scripts/report.py --db Project/project.db --section benchmark-suite
python3 Project/scripts/report.py --db Project/project.db --section port-lifecycle
python3 Project/scripts/report.py --db Project/project.db --section baseline-5k
python3 Project/scripts/preflight_port_baseline.py --db Project/project.db --all
```

## Cleanup Rule

Completed implementation plans should not remain as living Markdown. Extract
still-current rules into canonical docs, then delete the plan file or move the
facts into `Nodes/Shared/` contracts.
