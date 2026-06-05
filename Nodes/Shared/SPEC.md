# RosettaBitcoin Shared Specification

## Purpose

Shared defines the common full-node contract that every RosettaBitcoin port
must implement independently. It standardizes durable state, validation progress,
status reporting, blocker records, rebuild semantics, and conformance fixtures.

The contract is extracted from the JavaNode experiment. Java proved that a port
can validate far beyond early testnet4 blockers, but it also exposed the risk of
mixing a SQLite metadata truth with a separate hot UTXO backend. Shared exists
to prevent that class of split-brain state from being copied into other ports.

## Binary Gate

The binary gate is unchanged:

```text
From empty local state on Bitcoin testnet4, the node reaches and maintains tip
while independently validating every stored connected block.
```

Headers-only sync, trusted block import, matching another port without local
validation, or skipping unknown consensus rules does not pass.

## Required Layers

Every serious port implements these layers, even if the type names differ by
language:

```text
wire/
sync/
consensus/
storage/
chainstate/
status/
cli/
```

## Authoritative State

The active chainstate backend owns:

- validated tip height and hash
- active UTXO set
- undo records or disconnect metadata
- chainstate backend identity
- chainstate generation ID
- chainstate status

Metadata and reporting stores may mirror this data, but they are never
authoritative for consensus.

## Java Lessons To Preserve

Preserve these Java-derived patterns:

- block-local UTXO view with `created`, `spent`, and `loaded` maps
- batched UTXO spends and creates
- one logical block commit after all validation succeeds
- deterministic validation blocker ordering
- bounded chunk sync and live-loop iterations
- single-writer datadir lock
- fine-grained timing fields with stable names
- rebuild into a new generation before promotion
- pure per-port consensus crypto authority with optional accelerator backends
  gated by differential tests

Do not preserve these Java mistakes:

- status reading SQLite UTXO counts while sync writes another backend
- backend defaults that differ silently by entry point
- using SQLite `validated_tip` as truth when the active UTXO backend disagrees
- cross-store mutation without an invariant check
- treating one shared native crypto library as the only consensus authority for
  every port

## Port Roles

```text
JavaNode:
  lead implementation and proving ground for Shared

CSharpNode:
  first clean follower against Shared

PythonNode:
  historical provenance, fixture generator, readable reference

TypeScriptNode:
  minimal-runtime portability check

CppNode:
  systems/performance follower

ElixirNode:
  supervision and peer-lifecycle experiment
```

Follower ports use Java/Python blocker facts as a work queue, not as a validity
oracle.

## Required Startup Invariants

Before sync, live mode, rebuild continuation, or status claims, a node must
verify:

- exactly one writer owns the datadir lock
- active chainstate backend is declared
- backend path exists unless creating an empty state
- backend generation is usable, not mid-rebuild
- chainstate tip height/hash match backend metadata
- block index covers all connected heights through the validated tip
- no stored block gap exists below the validated tip
- status reads from the active chainstate backend

Failure to satisfy these invariants is a startup error, not a warning.
