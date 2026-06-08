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

Recommended fields for future hardening are `header_hash`, `stored_block_hash`,
active block shape, reconnect counters, disconnect reason, and natural timing
buckets. They are not hard gates until Project evidence shows they are broadly
useful and low tax.

Progress must come from the sync writer or a writer-owned channel. Proof wrappers
must not depend on opening live chainstate from a second sidecar while the writer
is active.

## Progress Posture

Project reports active ports with these posture labels:

| Posture | Meaning |
|---------|---------|
| `writer_owned` | The sync/proof writer emits `rb.port_progress` directly. This is the preferred steady-state model. |
| `wrapper_translated` | A wrapper builds product progress from another status surface. This is acceptable only as a temporary compatibility bridge. |
| `mixed` | The writer emits progress, but a wrapper also owns some pass-through or final-status glue. |
| `missing` | Project cannot find a current product-progress source. |

Go, Rust, Zig, Swift, OCaml, and C++ should stay writer-owned unless a concrete
defect proves otherwise. C# and Java may keep wrapper glue around their Docker
proof surfaces, but writer-emitted `rb.port_progress` is the primary product
truth and wrappers should pass it through rather than re-author it.

## Boundary

Ports must not own benchmark gates, lifecycle heartbeat policy, stall
classification, canonical benchmark artifact assembly, current-evidence updates,
or leaderboard rules. Those are Project control-plane responsibilities.

Port-local tests should validate node behavior: consensus, storage, P2P,
status, blockers, and restart/reconnect behavior. They should not lock in
benchmark artifact schemas or telemetry pass/fail rules.

Project may keep importing old port-authored benchmark JSON as historical
archaeology. Active-port current benchmark evidence is built by the control
harness from product progress and final status. New active benchmark runs must
not commit port-authored benchmark JSON under
`Nodes/Shared/conformance/results/`; any local port JSON is ignored debug output.
