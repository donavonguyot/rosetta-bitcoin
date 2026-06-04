# Live Tip Maintenance

Live mode turns bounded sync into a durable node loop. It must reuse the same
validated header and block connection path as one-shot sync.

## Loop Contract

```text
acquire datadir lock
open active chainstate
verify startup invariants
connect outbound peer
refresh headers with a bounded budget
connect missing blocks with a bounded budget
if current, idle briefly
on transient peer failure, reconnect with backoff
on consensus blocker, stop with blocker details
on chainstate invariant failure, stop with error
```

## Required Events

```text
live_start
live_iteration
peer_reconnect
tip_current
tip_advanced
live_stop
```

Events may be exported to `Project/project.db`, but live mode must not depend on
the project DB.

## Java Extraction Notes

Use `Nodes/Java/src/main/java/com/jbitnode/cli/LiveNodeService.java` as the lead
experiment. Preserve the bounded iteration model, idle polling, reconnect
semantics, and health events. Replace any backend-specific assumptions with the
`ChainstateStore` startup invariant.

## Out Of Scope For First Shared Live Gate

- inbound serving
- mempool relay
- full peer scoring
- full reorg implementation beyond required undo persistence
