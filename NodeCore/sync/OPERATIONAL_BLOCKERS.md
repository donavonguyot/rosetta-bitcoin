# Sync And P2P Operational Blockers

Operational blockers are failures in sync mechanics, peer behavior, storage, or
process coordination. They are not consensus blockers unless the node has a
complete, connected chainstate and stops on an unsupported consensus rule.

## Required Fields

```text
area:
port:
datadir:
peer:
command:
advertised_start_height:
header_height:
validated_height:
stored_block_height:
sync_status:
failure:
root_cause:
recovery:
prevention:
evidence:
status:
```

## Known Classes

### Inflated start_height

Peers may disconnect when a node advertises header height as `start_height`
while validated height is lower. During initial sync, advertise the validated
height or another conservative value.

### Deferred handshake messages

Initial sync should complete only the simple handshake:

```text
version -> verack -> sendheaders
```

Defer `feefilter`, `mempool`, and `sendcmpct` until headers are current and the
node is in the appropriate live mode.

### Dual writer corruption

One datadir must have one writer. If two sync/rebuild processes write the same
chainstate, missing UTXO failures are operational until proven otherwise.

### Split operational truth

A port is not storage-complete while validated tip, undo, block index, or sync
state are split across multiple operational stores. Followers should implement
one active operational truth and treat project reporting as observational.

## Clearance Rule

An operational blocker is cleared only when the port proves:

```text
fresh startup succeeds
restart succeeds
single-writer guard holds
status reports the active store
the same failure mode has a regression test or documented recovery command
```

Consensus blocker ledgers should link to operational blockers only after this
triage is complete.
