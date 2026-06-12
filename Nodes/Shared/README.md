# Shared

Shared is the shared full-node contract for RosettaBitcoin. It is not a
shared runtime library. Each language implementation owns its code, but every
serious node must implement the same storage, chainstate, sync, status, rebuild,
and conformance rules.

JavaNode has served as the lead implementation for this contract, having exposed the
production concerns that matter most: high-volume block connection, hot UTXO
backend alignment, live tip maintenance, rebuild safety, status truth, and
performance attribution.

PythonNode remains useful as readable historical provenance and a fixture source,
but Shared is extracted from Java's working and broken operational lessons,
Python history, and cross-port proof artifacts rather than from any single
port's assumptions.

## Directory Map

```text
Nodes/Shared/
  SPEC.md
  STATUS_CONTRACT.md
  BLOCKER_LEDGER.md
  storage/
  chainstate/
  sync/
  consensus/
  conformance/
  diagnostics/
  docker/
  replay/
  code-documentation/
  templates/
```

For consensus readiness, start with
`Nodes/Shared/consensus/CONSENSUS_RUNWAY.md`. It defines the staged
`script-corpus -> 5k -> 50k -> 100k -> tip_once -> tip_maintenance` path and points Project at
the Shared rule ledger instead of scattered historical status notes.

## Contract Map

Use these docs as the durable Shared contract surface:

| Area | Start here | Also useful |
|------|------------|-------------|
| Status and blocker records | `STATUS_CONTRACT.md`, `BLOCKER_LEDGER.md` | `diagnostics/BLOCKER_DIAGNOSTICS.md` |
| Storage and chainstate | `storage/STORAGE_GATE.md`, `chainstate/CHAINSTATE_STORE.md` | `storage/CHAINSTATE_CODEC_V2.md`, `storage/ROCKSDB_REPLAY_PROOF.md`, `chainstate/REBUILD_PROMOTE.md`, `FOLLOWER_STORAGE_READINESS.md` |
| Consensus runway | `consensus/CONSENSUS_RUNWAY.md` | `consensus/CONSENSUS_KNOWLEDGE_LEDGER.md`, `consensus/VALIDATION_PIPELINE.md`, `consensus/generated/rule_matrix.md` |
| Crypto backends | `consensus/NATIVE_CRYPTO.md` | `consensus/CRYPTO_BACKEND.md` |
| Docker runtime | `docker/DOCKER_RUNTIME_CONTRACT.md` | `docker/PORT_DOCKER_INVENTORY.md` |
| Benchmarks and replay | `conformance/BENCHMARK_CONTRACT.md` | `replay/REPLAY_TELEMETRY.md` |
| Live operation | `sync/LIVE_TIP_MAINTENANCE.md` | `sync/OPERATIONAL_BLOCKERS.md` |
| Code documentation | `CODE_DOCUMENTATION.md` | `code-documentation/golden_examples.md`, `code-documentation/language_idioms.md`, `code-documentation/agent_brief_template.md`, `code-documentation/review_questions.md`, `code-documentation/port_architecture_outline.md` |
| New port baseline | `templates/port-baseline-5k/README.md` | `SPEC.md` |

## Non-Negotiable Rule

Each node has exactly one authoritative operational chainstate in its own
datadir. `Project/project.db` is mission-control state and must never be used
by consensus code to validate blocks, read UTXOs, enforce blockers, or decide
the validated tip.

```text
Operational chainstate:
  active UTXO set
  undo data
  validated tip
  backend metadata
  generation identity

Project mission-control DB:
  run history
  reports
  blocker ledger
  conformance results
  benchmark comparisons
  Docker contract state
  decisions
```

If status and sync disagree about the active backend, the node must refuse to
run.
