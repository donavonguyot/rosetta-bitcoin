# Chainstate Rebuild And Promotion

Rebuilds must never mutate the active chainstate in place unless the node is
explicitly in destructive recovery mode. The normal production flow rebuilds a
new generation and promotes it only after verification.

## Normal Flow

```text
active generation remains readonly
create next generation
replay headers and stored blocks
verify tip height/hash
verify UTXO stats
verify block index coverage
mark next generation usable
atomically promote active pointer
archive or delete old generation later
```

## Required Metadata

```text
generation_id
parent_generation_id
backend_name
backend_path
chain
target_height
target_hash
status
started_at
finished_at
promoted_at
```

## Status Values

```text
planned
rebuilding
verifying
usable
promoted
failed
abandoned
```

## Java Extraction Notes

Java already has two useful rebuild experiments:

- `ChainstateRebuildService` for opt-in destructive rebuild from network block
  bytes.
- `ChainstateRebuild` for offline replay into a scratch RocksDB store.

Shared should keep the replay and verification ideas, but replace ad hoc
destructive promotion with explicit generations and an active pointer.

## Hard Failure Rule

If the active backend is missing, mid-rebuild, or misaligned with its declared
tip, sync and live mode must refuse to run. Repair is a rebuild/promote action,
not a best-effort sync.
