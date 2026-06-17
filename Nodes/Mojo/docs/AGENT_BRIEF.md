# Mojo Agent Brief

This directory is a bounded Mojo contender, not a tip-capable RosettaBitcoin
port. Current work should preserve the active gate boundary unless a later plan
explicitly adds external peers, supervisor loops, tip-once, or tip-maintenance
work.

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
script-corpus-reject --manifest <path> --result-path <path> --crypto-backend native|pure
local-reference-proof --datadir <path> --target 5000 --peer <host:port> --result-path <path>
local-reference-proof --datadir <path> --target 50000 --peer <host:port> --result-path <path>
local-reference-proof --crypto-backend pure --datadir <path> --target 5000 --peer <host:port> --result-path <path>
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
comparison. Use `pure-crypto-microbench` for tuning decisions: it loops fixed
pure ECDSA/Schnorr/Taproot vectors without native calls or shadow-agreement
accounting by default, then reports per-stage totals and per-iteration timing.
It also supports `field` and `point` cases that compare the current exact 4x64
field/point operations with the new 5x52 lazy-field and Jacobian group core.
ECDSA microbench output also reports diagnostic Fe52 WNAF/GLV product and
result timings. Pure diagnostic ECDSA and Schnorr now route through Fe52 plain
WNAF, and pure Taproot tweak checks route through the Fe52 scalar path. Fe52
GLV stays microbench-only because it is parity-clean but not faster than plain
Fe52 WNAF. The `ecdsa-batch` microbench is also diagnostic-only: it sweeps
homogeneous Fe52 SIMD WNAF lanes at K=2/4/8/16 with scalar Fe52 as oracle. The
latest host K sweep stayed parity-clean and measured scalar Fe52 at `83us` per
signature, K=2 at `50us`, K=4 at `40us`, K=8 at `32us`, and K=16 at `43us`.
It is not a live verifier route and does not support divergent mixed-lane WNAF
digits. Raw Mojo SIMD comparisons still produce scalar aggregate `Bool`, but
the current probe synthesizes per-lane masks arithmetically from raw `uint64`
SIMD ops and proves mask-driven zero/select works. A K=4 fixed-window
mixed-lane prototype now runs as a diagnostic, but remains disabled because it
reports two lane-result mismatches against scalar Fe52.
The measured shadow set enables all 17 Taproot corpus rows,
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
With `MOJOBITNODE_PAR_SCRIPT_VERIFY=1`, enough script jobs, and a thread count
other than `1`, shadow replay fills per-job result slots through Mojo
`parallelize` and then reduces the rows sequentially. The `shadow_crypto` object
must report `runner_mode`, `runner_actual_mode`, `script_jobs`,
`parallel_batches`, and `thread_count`; a parallel claim needs positive batch
evidence.
The current Docker 5k and 50k diagnostic replays are clean: zero unsupported
pure-shadow script inputs, zero disagreements, no native fallback, and positive
shadow parallel batch evidence at heights 5000 and 50000. The latest Docker 50k
shadow replay reached the expected hash with `1385632` supported script inputs
and `28012` shadow parallel batches. Its family timing buckets are
`p2pkh_ecdsa=52738ms`, `segwit_v0=115019ms`, `p2sh=2852ms`,
`taproot_schnorr=13294ms`, and `taproot_tweak=9012ms`, so ECDSA-family work is
now the next measured pure-crypto bottleneck.

`script-corpus-reject` is a Mojo-local must-reject diagnostic surface. It uses
repo-owned mutation metadata in `fixtures/script_corpus_reject_cases.json` and
derives reject rows from existing positive Shared fixtures rather than changing
the Shared corpus. Current rows cover P2PKH, bare multisig, P2SH, SegWit
v0/P2WSH, Taproot tweak, and Taproot Schnorr paths. Native and pure backends
must reject every row. The red targets deliberately enable pure-only fault
modes with `MOJOBITNODE_ENABLE_REJECT_FAULTS=1` and
`MOJOBITNODE_PURE_CRYPTO_FAULT=accept_ecdsa|accept_schnorr|accept_taptweak`;
those modes must stay confined to reject-corpus red checks.

`local-reference-proof --crypto-backend pure` is diagnostic 5k-only in this
slice. Pure Mojo crypto determines block acceptance, the artifact reports
`native_crypto_backend: "none"` and `crypto_backend:
"mojo-pure-secp256k1"`, and the run remains
`diagnostic_non_comparable`. The current Docker diagnostic reaches height 5000
with the expected hash and UTXO count, no native fallback, clean telemetry, and
positive parallel batch evidence. Do not treat it as Project evidence or a
replacement for the native comparable 5k/50k lane.

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
make host-script-corpus-reject
make host-script-corpus-reject-red
make host-pure-crypto-profile
make host-pure-crypto-microbench
make host-native-boundary-audit
make host-local-reference-proof
make host-shakedown-50k-proof
make host-shadow-5k-proof
make host-shadow-50k-proof
make host-pure-5k-proof
make docker-script-corpus
make docker-script-corpus-shadow
make docker-script-corpus-reject
make docker-script-corpus-reject-red
make docker-pure-crypto-profile
make docker-pure-crypto-microbench
make docker-native-boundary-audit
make docker-proof-local
make docker-proof-50k
make docker-proof-100k
make docker-status-100k
make docker-proof-post-100k-to-tip
make docker-shadow-5k-proof
make docker-shadow-50k-proof
make docker-pure-5k-proof
```

## Current Gate Order

The current port order is:

1. Keep Shared script corpus proof clean in Docker.
2. Keep Project-accepted baseline 5k evidence clean.
3. Keep Project-accepted 50k shakedown evidence quarantined to the prior
   accepted artifact while the diagnostic parallel runner is validated.
4. Treat `performance_100k` as the next missing canonical evidence gate; run it
   only through Project's campaign runner and native comparable proof lane.
5. Treat `post_100k_to_tip` as blocked until the durable 100k proof volume is
   ready and `docker-status-100k` reports source-state truth.

Strict 5k/50k proof requires RocksDB runtime truth, native crypto, WAL, fixed
benchmark knobs, `core_spendable_v1` UTXO accounting, and canonical importable
proof JSON.

Until Project accepts a control artifact for a gate, keep status language at
candidate/debug level even when local or Docker debug proof passes. A proof may
only report `script_runner_mode: "parallel"` when at least one script batch
actually ran through the parallel verifier and the artifact validates.
