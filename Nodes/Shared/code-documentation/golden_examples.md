# Golden Code Documentation Examples

These examples show the target shape. They are not templates to paste into every
file. Copy the judgment: local invariant first, Shared pointer second, no status
claim.

## P2P Deferred Negotiation

Good inline shape:

```ts
/**
 * Deferred advanced negotiation: during initial sync this peer sends only the
 * simple version/verack/sendheaders path. Relay-oriented messages wait until
 * headers are current so we do not advertise behavior beyond our validated
 * chainstate. See Nodes/Shared/CODE_DOCUMENTATION.md and STATUS_CONTRACT.md.
 */
async completeDeferredHandshake(): Promise<void> {
  ...
}
```

Why this works:

- Names the cross-port concept.
- Explains the Bitcoin/P2P risk.
- Points to Shared docs instead of copying the full runbook.
- Does not claim any port is presently at tip.

## Honest Start Height

Good inline shape:

```java
// Honest start_height: advertise the validated tip used by block sync, not the
// header tip. Peers can disconnect if a node claims more chain than it can
// serve or validate.
int startHeight = tracker.bootstrapStartHeight(chain.name());
```

Why this works:

- It is near the call site where a future edit could inflate the value.
- It explains the failure mode without retelling the full handshake history.

## Block Connection And UTXO

Good inline shape:

```cpp
// The block-local UTXO view handles same-block spends before the atomic
// chainstate commit. Store the block bytes only after validation succeeds, so
// block index, undo, UTXO, and validated tip remain one runtime truth.
auto result = connectAndStoreBlock(...);
```

Why this works:

- It connects performance shape to consensus safety.
- It uses shared vocabulary that appears across ports.
- It keeps broader validation order in `VALIDATION_PIPELINE.md`.

## Script And Sighash Trap

Good inline shape:

```rust
/// Builds the BIP143 witness sighash preimage. This is consensus code: byte
/// order and scriptCode selection must match the Shared script fixtures, not
/// wallet-friendly transaction serialization.
fn witness_sighash(...) -> [u8; 32] {
    ...
}
```

Why this works:

- It teaches the Bitcoin-specific surprise to language experts.
- It warns against a plausible but wrong abstraction.

## Chainstate Runtime Truth

Good inline shape:

```go
// Runtime truth comes from the active RocksDB chainstate. Project reports may
// index this status later, but sync and validation must not read Project state.
func Status(datadir string) (...)
```

Why this works:

- It marks the boundary between node operation and mission control.
- It prevents a tempting dependency inversion.

## Single-Writer Datadir Lock

Good inline shape:

```csharp
/// Acquires the single-writer datadir lock for sync/connect/rebuild. This is a
/// chainstate integrity guard, not an advisory operator hint: overlapping
/// writers can lose UTXOs and create false validation blockers.
public sealed class DatadirLock : IDisposable
```

Why this works:

- It explains why the lock exists.
- It ties an operational mechanism to consensus diagnostics.
