# CSharpNode Follower Plan

CSharpNode should be the first clean follower implementation of NodeCore. It
should copy Java's current RocksDB-exclusive node-local KV posture, not older
temporary storage splits.

The first concrete slice is the storage gate plan in
[`CSharpNode_STORAGE_GATE_PLAN.md`](CSharpNode_STORAGE_GATE_PLAN.md). Complete
that slice before broad P2P or consensus expansion.

## Scope

CSharpNode should implement the NodeCore contract in this order:

1. `IChainstateStore` interface and SQLite reference implementation only if
   needed for tests.
2. Active chainstate metadata and startup invariants.
3. Atomic block connect using a block-local UTXO view.
4. Status export matching `NodeCore/STATUS_CONTRACT.md`.
5. Conformance runner consuming `NodeCore/conformance` fixtures.
6. Script blocker work queue from the shared blocker ledger.
7. RocksDB backend using NodeCore Chainstate Codec v2.

## Do Not Copy

Do not copy these Java transitional mechanics:

- SQLite as project tracker and hot UTXO store at the same time.
- Makefile-only backend truth.
- status based on SQLite UTXO counts while another backend is active.
- destructive backend switching without generation promotion.
- treating the native file backend as production chainstate.

## Acceptance Criteria

- CSharpNode can run conformance fixtures without `Project/project.db`.
- CSharpNode exports status snapshots importable into `Project/project.db`.
- The active chainstate backend owns validated height/hash.
- The serious backend is RocksDB, not file or SQLite.
- Missing UTXO failures first trigger chainstate-integrity investigation, not a
  new consensus-rule assumption.
