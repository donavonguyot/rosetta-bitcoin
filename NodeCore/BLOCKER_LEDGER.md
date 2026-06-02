# Blocker Ledger Contract

The blocker ledger is the shared work queue for consensus progress across
ports. A blocker is recorded when a node stops because it encountered a
consensus rule it cannot yet validate.

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
source_commit:
fixture:
test_name:
first_seen_at:
status:
follower_notes:
```

`status` should be one of:

```text
open
implemented_unverified
cleared
superseded
not_consensus
```

## Recording Rule

Do not record vague blockers. A useful consensus blocker identifies the exact
height, transaction, input, previous scriptPubKey, failure, and missing rule.

If a node stops on a missing UTXO, first investigate chainstate integrity,
single-writer locks, rebuild state, and atomic commit behavior. Missing UTXO is
often an operational chainstate failure, not a new consensus rule.

## Follower Rule

Follower ports may use Java and Python blocker facts as a work queue, but must
clear the blocker with their own code and tests. A port does not inherit another
port's validity.

## Operational Triage

Before recording a consensus blocker, rule out operational blockers documented
in `NodeCore/sync/OPERATIONAL_BLOCKERS.md`:

```text
inflated start_height
deferred-handshake mistakes
dual writers on one datadir
split operational truth
stale or missing block index metadata
```

If the root cause is operational, record it in the sync/P2P operational blocker
ledger shape instead of adding a consensus blocker row.

## Project DB Mirror

The canonical per-port ledger can live in docs next to the implementation, but
entries should also be exported into `Project/project.db` so reports can compare
port progress.
