# Conformance Suite

The conformance suite is the portability proof for NodeCore. Every language port
must consume the same fixtures and produce the same status/failure results.

## Fixture Areas

```text
fixtures/
  genesis/
  headers/
  blocks/
  chainstate/
  scripts/
  rebuild/
  live-loop/
  status/
```

## Required Test Categories

- genesis initialization
- header proof-of-work and chain linkage
- block 1 and block 2 connection
- UTXO spend/add invariants
- same-block spend behavior
- undo write/read contract
- atomic commit failure simulation
- known script blocker fixtures
- rebuild and promote verification
- status JSON expected output
- live loop transitions: current tip, new headers, catch-up, disconnect, blocker

## Runner Contract

Each port should expose a local conformance runner that accepts a fixture path
and emits JSON:

```text
implementation
commit
fixture_id
result
validated_height
validated_hash
chainstate_backend
timings
failure
```

The runner may export results to `Project/project.db`, but conformance execution
must not depend on the project DB.

## Java Extraction Notes

Initial fixtures should be harvested from Java's current tests and blocker
history, especially block 1/2 connect tests, script blocker regressions, live
loop mock-peer tests, and rebuild tests.
