# Shared Blocker Ledger Contract

Every consensus unblock must leave a handoff row that another port can reproduce
without reading chat transcripts or another implementation's chainstate.

## Required Fields

```text
height:
block_hash:
txid:
input_index:
spent_script_pubkey:
failure:
missing_rule:
source_port:
source_fixture:
port_fix:
test_fixture:
follower_notes:
```

## Rules

- A blocker is a consensus or validation gap. Peer disconnects, stale locks,
  timeout stalls, and fork repair are operational errors and belong in status or
  run history.
- Once a port validates beyond the blocker height, mark the blocker cleared or
  superseded in that port's ledger.
- Followers may reuse fixture bytes and exact facts, but must run their own
  verifier and write their own fixture/test evidence.
- Recurring blocker inspection belongs in a port CLI or NodeCore diagnostic,
  not a one-off Python script.

Shared rows are cataloged in
[`docs/consensus-blockers-testnet4.md`](consensus-blockers-testnet4.md).
