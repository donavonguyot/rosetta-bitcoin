# Fixture packages, build provenance, and state migration — 2026-10-03

This implementation keeps the existing benchmark contract versions and evidence
selection rules. It was developed in an isolated checkout of committed source;
the primary checkout's uncommitted Zig result edits were preserved. No live-Core
workload, Core stop, or Core datadir relocation was performed.

The machine-readable completion record is
[`provenance_rollout_2026-10-03.json`](../Nodes/Shared/conformance/provenance_rollout_2026-10-03.json).
It is an implementation receipt, not a benchmark result or a current-evidence
selection. Historical result files and retired-port source were not rewritten.

## B: canonical fixtures and Java resources

`Project/scripts/build_fixture_package.py` packages only
`Nodes/Shared/conformance/fixtures/` and `Nodes/Shared/testing/fixtures/`, preserving
names relative to Shared. The uncompressed tar uses sorted paths, mode 0644,
zero timestamps and uid/gid, empty owner names, and no host metadata. Symlinks and
special entries are rejected. Extraction rejects unsafe paths, symlinks, and
stale or conflicting contents.

The committed inventory is
[`fixture_package.json`](../Nodes/Shared/conformance/fixture_package.json).
Each retained tar has a matching immutable JSON receipt under
`state:packages/rosetta-fixtures-<sha256>.json`. Publication is atomic and checks
existing package bytes before reuse. Packages are append-only and have no GC.

From the repository root, reproduce or verify the package with:

```sh
python3 Project/scripts/build_fixture_package.py
python3 Project/scripts/build_fixture_package.py --verify 14f375ab39c9c4971336b723712321b2340c1e96400a4a3796dacf0cff52f70b
python3 -m unittest discover -s Project/scripts -p test_fixture_package.py
```

The build prints the digest. Use `--receipt <output.json>` to write a fresh
inventory for review. Generated results and package files are outside the
approved roots. The six Mojo rejection cases' source-fixture IDs and transitive
Shared input paths are enumerated in `fixture_package.json`;
[`fixture_package_scope.json`](../Nodes/Shared/conformance/fixture_package_scope.json)
records the port-owned mutation inputs and implementation excluded from the tar.
Mutations are covered by `source_commit`, not invented standalone fixture files.

All nine active ports consume extracted fixtures through the shared Make include:
C++, C#, Go, Java, Mojo, Rust, Swift, Zig, and OCaml. For example:

```sh
make -C Nodes/Java fixture-package
make -C Nodes/OCaml fixture-package
```

The Project launchers retain lifecycle selection; port runtimes do not query the
Project database. Build/test/corpus paths and Compose fixture mounts use the
extracted package.

Java's [`fixture_resources.json`](../Nodes/Java/fixture_resources.json) records
each of the 1,762 verified Shared duplicates by original resource name, package
member, and content hash. It also records an individual keep disposition for all
79 unmatched files. Maven assembles `target/generated-test-resources/fixtures`
before test-resource processing, preserving `/fixtures/...` names. Direct
filesystem consumers use that assembled directory. Missing mappings or changed
bytes fail assembly.

Two existing Java issues prevented a clean baseline: malformed DER input could
overrun its scalar bounds, and the invalid Taproot expected-output test assumed
the calculation must throw instead of checking the mismatch. Those issues were
corrected before the parity baseline. Then clean `mvn verify` runs before and
after duplicate removal had the same 438 test identities and passing outcomes,
with zero skips, errors, or failures. The case-level receipt is
[`fixture_parity.json`](../Nodes/Java/fixture_parity.json). Recheck with:

```sh
mvn -B -f Nodes/Java/pom.xml clean verify
python3 Project/scripts/record_java_parity.py --compare Nodes/Java/fixture_parity.json
```

## A: build-bound provenance and imports

The shared Project helper binds `fixture_hash`, full `source_commit`, and
`binary_sha256` to committed build inputs. Build receipts live under the state
root's `build-receipts/` directory and record whether the subject is a Docker
image or a native file. Docker execution is pinned to the recorded immutable
image ID; a native receipt hashes the measured executable file. An unreceipted
prebuilt image cannot acquire pins from the launcher's current HEAD.

`run_benchmark_campaign.py`, `run_parallel_benchmark_campaign.py`,
`run_crypto_lane.py`, and `run_zig_50k.py` accept optional `--run-ref`. The supplied
string is copied verbatim, including surrounding whitespace and punctuation,
and is omitted when absent. Internal `run_id` remains independent. Canonical
assembly goes through `control_benchmark_harness.build_artifact`; experimental
formats keep their classifications. Parallel summaries carry pins per port;
crypto component and node measurements identify their respective measured
artifacts, separately from probe/reference identities.

Both import entrypoints validate retained tar bytes before schema dispatch and
unchanged-artifact shortcuts. Missing, misnamed, or corrupt packages fail before
artifact writes; an import never reconstructs a missing historical package from
current fixtures. An older retained package remains valid after fixtures change.
Absent provenance receives separate `provenance_status: absent` metadata;
malformed provenance fails. Verified pins and status are retained in the existing
JSON storage and refreshed idempotently on unchanged imports. Parallel metadata
is verified per port, including mixed historical absent/verified summaries.

The `artifact_provenance` SQL view and `report.py --section provenance` expose the
pins and status without changing ranking rules or adding query CLI flags.

## C: local state and deferred Core cutover

`Project/scripts/state_root.py` resolves `RB_STATE_ROOT` once, defaults to
`~/.rblab`, and exposes a Python API and JSON CLI. Resolution creates nothing:

```sh
python3 Project/scripts/state_root.py
python3 Project/scripts/state_root.py --effective
python3 Project/scripts/migrate_state.py
```

The last command is dry-run by default. Non-Core application uses `--apply`, with
optional `--class campaigns` or `--class substrate`. The command takes an
exclusive migration lock, checks writable open handles, checks available space,
journals recovery actions before effects, verifies file bytes/modes/timestamps,
and retains originals outside the repository. Producers using the new helper
take shared writer leases. Read-only file handles do not count as writers.

The completed local migrations are:

| Original logical location | New location | Retained original | Bytes copied |
| --- | --- | --- | ---: |
| `Project/.campaigns` | `state:campaigns/` | state-root `retained-originals/campaigns` | 4,398,652,094 |
| `Nodes/RosettaNode/substrate/.local` | `state:substrate/` | state-root `retained-originals/substrate` | 11,234,199,742 |

The whole mixed evidence/cache campaign tree was preserved. Socket endpoints
are not portable file data: 276 substrate socket paths remain in the retained
original and are enumerated in the local migration receipt. All portable file
contents and required metadata were compared before switching. Local absolute
paths and detailed inventories remain in state-root `migrations/`; the committed
receipt uses logical references and inventory hashes.

Execution-order deviation: substrate was copied first while the initial
campaign check was blocked by read-only virtualization handles. After confirming
their access mode, the campaigns tree was copied and verified. Neither cutover
proceeded with a detected writer. Compatibility symlinks at the old locations
support existing checkouts; no bulk remains there. Until the updated ignore
rules are present in an older checkout, those symlinks can appear as untracked.

The actual `campaign-v2` was idle, received a dated `FROZEN.txt`, and became
read-only before migration. Its destination is `state:substrate/campaign-v2`;
its existing evidence bytes were preserved. A retained original also remains
under state-root `retained-originals/substrate/campaign-v2`.

Completed migrations are idempotent. After interruption, `--recover <class>`
finishes a verified cutover when the original has already been retained;
`--rollback <class>` restores or keeps the original. A rolled-back or partial
copy is retained for inspection, not deleted or silently reused. Resolve that
retained migration record and its occupied paths before attempting a new copy.

Retention policy permits port-local build directories and retired-port state.
Path hygiene enforces the migrated classes, accepts receipt-backed compatibility
links, reports incomplete migration journals, and keeps a dated Core exception.

**Core remains deferred.** Its effective location is still
`Nodes/Reference/bitcoin-core-testnet4` in the primary checkout. Its pre/post seed
hashes are pending. The separate `migrate_core.py --execute-scheduled` path is for
an explicitly scheduled cutover: stop and verify stopped, stream canonical-tar
hash, copy preserving permissions, hash again, require equality, switch Compose,
then start. A mismatch preserves the original and prevents destination startup.
The helper writes a machine-readable seed receipt and a dated Reference addendum.
This operational Core sequence has not been run or live-tested here.

## Validation record and remaining limits

- Packaging: four tests cover two-tree reproducibility with metadata changes,
  changed bytes, unrelated results, retained corruption, symlinks, and unsafe
  extraction paths.
- Java: 438 matching passing cases before/after deletion and on the final clean
  build, no skipped cases. Every removed resource has a byte-checked mapping.
- Consumers: C++, C#, Go, Java, Mojo, Rust, Swift, and Zig each passed the 45-case
  package-backed corpus. Mojo passed all six must-reject cases on both backends.
  All nine ports passed package preparation and Compose rendering.
- OCaml host corpus remains environmentally blocked: Opam is not initialized.
  Its package extraction and Compose rendering passed; its runtime corpus is
  not claimed as verified.
- Provenance: six tests cover the three existing gate artifacts, opaque reference
  round-trip, absent/malformed objects, old/missing/corrupt retained packages,
  unchanged-artifact revalidation, experimental dispatch, and per-port SQL
  projection. Both import entrypoints were exercised with isolated databases.
- Importer, control harness, serial campaign, and parallel campaign self-tests
  passed. Six crypto-lane tests passed. The tracked current evidence selection
  imported into an isolated database: 153 artifacts, all historically absent
  provenance. The tracked Project database and evidence selection were untouched.
- Six migration tests passed, covering interrupted copy, corruption, occupied
  destination, active writer refusal, completed rerun, rollback/recovery, and
  canonical seed hash behavior. Nested state-path tooling tests also passed.
- Docker contract validation reported zero errors across 13 manifests. Fresh
  end-to-end Docker benchmark execution was not performed; image execution
  binding was checked through code paths, tests, and Compose rendering.
- Documentation drift still reports the missing
  `Docs/paper/figures/substrate_pipeline.pdf` linked by the unchanged publication
  document. Path hygiene still reports 717 existing absolute-path findings in
  tracked sources/evidence/database payloads; historical evidence was preserved.
  No new runtime-state-root finding remains after migration.
- Each implementation diff was checked for external project references,
  accidental machine paths, retired-port changes, and historical evidence edits.

Tests used offline fixtures and isolated databases. The remaining validation
limits do not constitute benchmark evidence or permission to run a live-Core
campaign.
