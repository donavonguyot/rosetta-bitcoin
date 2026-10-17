# Dependency and fixture provenance

Zig 0.16.0 is pinned by archive SHA-256 in `scripts/install_ci_zig.py` and
`docker/Dockerfile`. Update both together and run every hosted host/Docker lane.
Python 3.11 or newer runs RB consumer tooling; standalone node tools need 3.10
or newer. Native C-binding builds use the platform's RocksDB and libsecp256k1
packages; the Dockerfile records the Linux dependency installation. These
system packages are not byte-for-byte locked by the source inventory.

`libsecp256k1-zig/` is a materialized snapshot of RB's
`Libraries/Zig/libsecp256k1-zig`. It includes its own license. The `own_curve`
backend is experimental public-input verification. Node code owns Bitcoin
sighashes, signature suffixes, and Taproot tagged hashing; this package does not
provide node consensus or P2P logic.

`fixtures/` contains RB Shared's declared `conformance/fixtures`,
`testing/fixtures`, and `fixtures` roots, preserving their original layout.
For example the script corpus is at
`fixtures/conformance/fixtures/scripts/manifest.json`. Expected bytes are frozen;
updates must explain their provenance and rule coverage.

Before extraction, make dependency updates in their canonical RB locations,
commit them, and export again. The export manifest records the RB commit,
original paths, and every file's SHA-256. Preserve licenses and verify that
unrelated fixture bytes are unchanged. After extraction, import deliberate
snapshots from a recorded upstream commit and commit an updated provenance
record alongside the changed inputs; never fetch mutable fixture contents at
runtime or rewrite the original export manifest to disguise local edits.

For subsequent standalone Git revisions, `scripts/snapshot_ci_source.py` creates
a new clean-checkout inventory under `.zig-cache/`. Pass that inventory to CI
and RB's consumer adapter. The initial export manifest remains the transfer
receipt; the new inventory identifies the current revision.

Historical ledger paths beginning `Nodes/`, `Libraries/`, or `Project/` refer to
RB, not files required at runtime. Resolve them in the original RB revision
recorded by the entry or export manifest. Completed split/documentation plans
and crypto campaigns are retained in RB's `Docs/history/zigibit/`.
