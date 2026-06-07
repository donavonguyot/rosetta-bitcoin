# Port Progress Contract

Ports are product nodes. They expose truthful runtime progress; Project turns
that progress into benchmark telemetry, artifacts, evidence, and rankings.

## Product Progress

During sync/proof runs, a port may emit writer-owned progress lines:

```text
rb.port_progress {"chain":"testnet4", ...}
```

Required fields:

```text
chain
sync_status
header_height
validated_height
validated_hash
stored_block_height
chainstate_utxo_count
current_blocker
```

Useful optional fields include `peer`, `downloaded_blocks`, `connected_blocks`,
active block height/hash/shape, reconnect/disconnect counters, and timing
counters that naturally belong to the node implementation.

Progress must come from the sync writer or a writer-owned channel. Proof wrappers
must not depend on opening live chainstate from a second sidecar while the writer
is active.

## Boundary

Ports must not own benchmark gates, lifecycle heartbeat policy, stall
classification, canonical benchmark artifact assembly, current-evidence updates,
or leaderboard rules. Those are Project control-plane responsibilities.

Port-local tests should validate node behavior: consensus, storage, P2P,
status, blockers, and restart/reconnect behavior. They should not lock in
benchmark artifact schemas or telemetry pass/fail rules.

Project may keep importing historical port-authored benchmark JSON, but current
benchmark evidence should be built by the control harness from product progress
and final status.
