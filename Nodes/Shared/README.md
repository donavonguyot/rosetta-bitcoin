# Shared

Shared is the shared full-node contract for RosettaBitcoin. It is not a
shared runtime library. Each language implementation owns its code, but every
serious node must implement the same storage, chainstate, sync, status, rebuild,
and conformance rules.

JavaNode is the lead implementation for this contract because it has exposed the
production concerns that matter most: high-volume block connection, hot UTXO
backend alignment, live tip maintenance, rebuild safety, status truth, and
performance attribution.

PythonNode remains useful as a readable historical scout and fixture source, but
Shared is extracted from Java's working and broken operational lessons rather
than from any single port's assumptions.

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
```

## Non-Negotiable Rule

Each node has exactly one authoritative operational chainstate in its own
datadir. Project-level SQLite is mission-control state and must never be used by
consensus code to validate blocks, read UTXOs, enforce blockers, or decide the
validated tip.

```text
Operational chainstate:
  active UTXO set
  undo data
  validated tip
  backend metadata
  generation identity

Project SQLite:
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
