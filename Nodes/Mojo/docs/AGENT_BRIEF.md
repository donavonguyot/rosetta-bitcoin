# Mojo Agent Brief

This directory is a bounded Mojo contender, not a tip-capable RosettaBitcoin
port. Current work should preserve the active gate boundary unless a later plan
explicitly adds external peers, supervisor loops, long-run lanes, or tip work.

## Current Toolchain

- Target Mojo package: `mojo==1.0.0b1`.
- Host install surface: repo-local `.venv` via `uv pip install "mojo==1.0.0b1"`.
- Docker install surface: Debian `bookworm-slim` with the same pinned Mojo
  package.
- Mojo is not provided by Homebrew. Homebrew only provides `uv`, `python@3.11`,
  RocksDB, `secp256k1`, and `pkgconf`.

Use the version checks before trusting local output:

```bash
make host-mojo-version
make docker-mojo-version
```

## Public CLI Surface

The supported executable is `mojobitnode` with these public commands:

```text
status --datadir <path> --json
native-crypto-vectors --vectors <path> --result-path <path>
pure-crypto-profile --result-path <path>
storage-proof --datadir <path> --result-path <path>
script-corpus --manifest <path> --result-path <path>
script-corpus --manifest <path> --shadow-crypto --result-path <path>
local-reference-proof --datadir <path> --target 5000 --peer <host:port> --result-path <path>
local-reference-proof --datadir <path> --target 50000 --peer <host:port> --result-path <path>
```

The CLI is Mojo-owned and must continue to report
`entrypoint_language: "mojo"`, `native_shim: "owned_c"`, and
`delegated: false` where applicable. Do not reintroduce Python delegation or a
separate C proof executable.

`script-corpus-dev --manifest <path> --fixture-id <id> --result-path <path>` is
still available for fixture-level diagnosis. It also accepts
`--fixture-set legacy|segwit-v0|non-taproot|taproot|all`. The public
`script-corpus` command is the canonical evidence path and must stay Mojo-owned,
with no Python or other-port delegation.

`script-corpus --shadow-crypto` is diagnostic. It keeps native `libsecp256k1`
as the default/comparable lane, then records whether the pure Mojo backend
supports each fixture without using native fallback. Its
`port.script_corpus_shadow_crypto.v1` output belongs in Mojo-local debug paths,
not Project current evidence. The pure backend currently supports BIP340
Schnorr and Taproot tweak primitives through libsecp-guided fixed-limb field
multiplication and Jacobian group operations. Pure ECDSA/DER now matches native
vector result classes, including high-S normalization, malformed DER/pubkey
handling, and consensus-invalid signatures. The diagnostic
`pure-crypto-profile` command records ECDSA stage timings for DER parse, pubkey
parse/lift, high-S normalization, scalar inverse, scalar multiplication,
reference double-base, wNAF double-base, affine conversion, and native-result
comparison. The measured shadow set enables all 17 Taproot corpus rows,
including the large
`scripts.p2tr_tapscript_71267`, `scripts.p2tr_tapscript_121035`, and
`scripts.p2tr_tapscript_126975` stress rows, plus all three timing-gated
P2PKH/ECDSA rows: `scripts.p2pkh_sighash_single_38010`,
`scripts.p2pkh_61174`, and `scripts.p2pkh_107951`, the first bare legacy and
bare multisig rows: `scripts.bare_legacy_118555` and
`scripts.bare_multisig_27840`, the 10 simple P2SH legacy rows, and all SegWit
v0/P2WSH rows. P2PKH shadow rows report ECDSA sighash, verify, total, and
signature-count timings. Shadow artifacts
include per-attempt `shadow_duration_ms`, aggregate timing fields, and
large-fixture size metrics; do not broaden support unless new rows have zero
disagreement and stay under the 5000ms per-row guardrail. Read
`docs/LIBSECP_TRANSLATION_NOTES.md` before changing pure secp internals.

`local-reference-proof` is the bounded local Reference proof path for 5k and
50k. It must use local Reference P2P bytes, RocksDB operational truth, native
`libsecp256k1`, and `core_spendable_v1` UTXO accounting. Do not hand-edit a
benchmark claim; Project's campaign harness owns accepted control artifacts and
current benchmark evidence.

`local-reference-proof --shadow-crypto` is diagnostic-only. Native validation
still accepts or rejects blocks; pure Mojo crypto replays supported corpus
families beside the native path and reports any future unsupported rows or
disagreements explicitly. These artifacts must report
an explicit diagnostic non-comparable marker and pass
`validate_shadow_crypto_proof.py`; they are not Project-imported benchmark truth.

## Native Boundary

`src/mojo_native_shim.c` is the owned native boundary for `libsecp256k1`
primitives, RocksDB primitives, and non-consensus POSIX runtime glue for
sockets/time/file writes. Keep consensus logic, hashes, TapTweak construction,
fixture/result shaping, storage-proof operation sequencing, command dispatch,
JSON shaping, and user-visible CLI behavior in Mojo. The shim should expose
primitives only when Mojo interop is not sufficient for the spike.
Generic RocksDB packed batch application is allowed as a storage primitive, but
Mojo must own operation ordering, keys, values, undo encoding, metadata, and all
consensus decisions. Default proof runs use the proven WriteBatch primitive
path; `MOJOBITNODE_PACKED_ROCKSDB_BATCH=1` is diagnostic-only unless a later
profile proves it faster.

The live proof path routes signature and Taproot tweak checks through a
Mojo-owned crypto backend wrapper so a block-level script job batch does not
construct a dynamic-library handle for every signature. Native `libsecp256k1`
is the only comparable backend. The pure Mojo backend is explicit diagnostic
scaffolding and must report unsupported rather than falling back to native.

Native crypto call counts are part of proof telemetry. Per-call crypto timing is
profiling-only: set `MOJOBITNODE_PROFILE_CRYPTO=1` when investigating
`ecdsa_ms`, `schnorr_ms`, `taproot_tweak_ms`, or `native_bridge_ms`. Comparable
benchmark runs should leave it unset and use `script_verify` / `script_wall_ms`
for hot-path cost.
Hot-path allocation/copy profiling is also diagnostic-only. Set
`MOJOBITNODE_PROFILE_HOTPATH=1` when a run needs the `hotpath_profile` object
for slice/clone/list-copy, script stack churn, sighash assembly, job/context
copy, and native argument-prep counters. Do not promote or compare a run because
of these counters; use them to pick the next narrow Mojo optimization.
The current measured target is legacy sighash assembly. Mojo keeps the uncached
legacy sighash path as the reference oracle and routes live verification through
a cached preimage builder only after focused equivalence smokes pass.

Before trusting a new native proof, run:

```bash
make host-native-boundary-audit
make docker-native-boundary-audit
```

The audit distinguishes direct shim linkage from Debian package closure. TLS/SSL
packages may exist in the image because other packages pull them in, but they
are not allowed to become linked or called Mojo consensus crypto dependencies.

## Docs And Testing

Mojo syntax changes quickly, and older model knowledge can be stale. Refresh the
local generated docs cache before substantial Mojo edits:

```bash
make mojo-docs-cache
make mojo-docs-status
```

Generated docs live in `.mojo-docs/` and are intentionally ignored. The optional
AI skill install is operator-local and not required for CI:

```bash
npx skills add modular/skills --skill mojo-syntax
npx skills update
```

For parallel script-runner work, read `docs/PARALLEL_RUNNER_RESEARCH.md` after
refreshing the cache. The local cache includes current Mojo 1.0.0b1 pages for
CPU `parallelize`, `sync_parallelize`, async `TaskGroup`, atomics, locks, and
logical core discovery. `sync_parallelize` currently warns that callback
exceptions trap instead of propagating, so consensus failures must be captured in
owned result records and reduced deterministically after the parallel section.
The proof path uses a fast-port-shaped block-level script job/result layer.
Defaults execute that batch sequentially. Setting
`MOJOBITNODE_PAR_SCRIPT_VERIFY=1` enables the diagnostic Mojo `parallelize`
runner only when the block has at least `MOJOBITNODE_SCRIPT_MIN_INPUTS` script
jobs and `MOJOBITNODE_SCRIPT_THREADS` is not `1`; `0` means the Mojo runtime
default worker count. After verification passes, Mojo stages UTXO deletes,
unspent creates, undo, block storage, and metadata, then commits them through
one RocksDB batch. The proof path opens RocksDB with the durable fast-port
tuning profile, gathers distinct external prevouts for each block, loads them
through ordered `multi_get`, and uses Mojo-owned sorted outpoint indexes for
created/spent block-local state while preserving ordered lists for undo and
commit determinism. Sighash precompute is selected by script family: BIP143,
Taproot, both, or neither, and proof telemetry reports the split counters. Do
not treat any env flag as a comparable proof claim by itself. A proof may report
`script_runner_mode: "parallel"` only when at least one parallel batch actually
executed and the artifact includes runner batch metrics accepted by the
benchmark validator.

Do not use `mojo test`; current Mojo testing uses `TestSuite` and runs with
`mojo run`:

```bash
make host-toolchain-smoke
make host-parallel-runner-smoke
make docker-toolchain-smoke
make docker-parallel-runner-smoke
make host-script-corpus-foundation-smoke
make host-block-core-smoke
make host-script-corpus
make host-script-corpus-shadow
make host-pure-crypto-profile
make host-native-boundary-audit
make host-local-reference-proof
make host-shakedown-50k-proof
make host-shadow-5k-proof
make host-shadow-50k-proof
make docker-script-corpus
make docker-script-corpus-shadow
make docker-pure-crypto-profile
make docker-native-boundary-audit
make docker-proof-local
make docker-proof-50k
make docker-shadow-5k-proof
make docker-shadow-50k-proof
```

## Current Gate Order

The current port order is:

1. Keep Shared script corpus proof clean in Docker.
2. Keep Project-accepted baseline 5k evidence clean.
3. Keep Project-accepted 50k shakedown evidence quarantined to the prior
   accepted artifact while the diagnostic parallel runner is validated.
4. Treat 100k as the next missing gate; do not start it without a separate plan.

Strict 5k/50k proof requires RocksDB runtime truth, native crypto, WAL, fixed
benchmark knobs, `core_spendable_v1` UTXO accounting, and canonical importable
proof JSON.

Until Project accepts a control artifact for a gate, keep status language at
candidate/debug level even when local or Docker debug proof passes. A proof may
only report `script_runner_mode: "parallel"` when at least one script batch
actually ran through the parallel verifier and the artifact validates.
