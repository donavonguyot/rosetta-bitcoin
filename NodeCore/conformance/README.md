# Conformance Suite

The conformance suite is the portability proof for NodeCore. Every language port
must consume the same fixtures and produce the same status/failure results.

## Fixture Areas

```text
fixtures/
  README.md
  chainstate_codec_v2_vectors.json
  native_crypto_v1_vectors.json
  scripts/
    manifest.json
    MATRIX.md
    README.md
```

**Script corpus:** [`fixtures/scripts/`](fixtures/scripts/) is the offline
45-fixture spend-verification gate. When debugging failures, start with
[`docs/script-semantics-gotchas.md`](../../docs/script-semantics-gotchas.md)
(§ NodeCore script corpus and MATRIX triage), not the fixture `missing_rule` field alone.

The fixture manifest is broader than the current shared byte tree. During
bootstrap, fixture bytes may live in port-local test trees while the shared
fixture ID and expected outcome remain documented in `MANIFEST.md`.

## Shared Tooling

Fixture harvesters and proof-capture helpers live under `tools/`. They are
shared project tooling, not port runtime code. Some bootstrap harvesters still
write bytes into port-local test resource trees until those fixtures are fully
promoted into this conformance area.

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

## Result Retention

Canonical project evidence is compact JSON under:

```text
NodeCore/conformance/results/
```

Use the naming convention from `docs/artifact-retention.md`:

```text
<port>_<gate>_<surface>_<YYYY-MM-DD>.json
```

Do not store live datadirs, DBs, block files, full logs, or proof scratch
directories in `NodeCore/conformance/`. Preserve only compact proof summaries
that support a project claim.

## Java Extraction Notes

Initial fixtures should be harvested from Java's current tests and blocker
history, especially block 1/2 connect tests, script blocker regressions, live
loop mock-peer tests, and rebuild tests.
