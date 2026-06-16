# mojobitnode

`mojobitnode` is a bounded Mojo contender for RosettaBitcoin. It is not a
tip-capable full node, and Project control artifacts remain the source of
accepted benchmark truth.

The spike asks one narrow question: can Mojo install reproducibly and prove the
native prerequisites a future port would need?

## Spike Surface

- Debian `bookworm-slim` Docker image.
- Host development surface with Homebrew native dependencies.
- Mojo installed with the official `uv pip install` route, pinned to
  `mojo==1.0.0b1`.
- `mojobitnode` is a compiled Mojo entrypoint.
- Native calls go through owned C shims, not Python delegation:
  `libsecp256k1` primitives, RocksDB primitives, and non-consensus POSIX
  runtime glue for sockets/time/file writes.
- Live proof script verification reuses a Mojo-owned native crypto handle across
  the block-level job batch; compatibility fixture helpers may still construct
  one-shot handles for small diagnostic runs.
- Native `libsecp256k1` vector checks.
- RocksDB runtime truth smoke against `chainstate-rocksdb`.
- Project-shaped status JSON.
- Docker Shared script corpus proof (`45/45`).
- Local Reference P2P proof surfaces for strict 5k baseline and 50k shakedown
  candidates.
- Fast-port-shaped block-level script-verification job/result layer with
  sequential proof execution plus one RocksDB batch commit per connected block.
  Parallel runner research stays diagnostic until runner truth is self-proving.
- Tuned RocksDB open options, ordered block-level prevout `multi_get`,
  Mojo-owned sorted outpoint indexes for block-local lookups, and typed
  BIP143/Taproot sighash precompute telemetry for debug 50k profiling.
- Generic packed RocksDB batch apply is available for diagnostic profiling via
  `MOJOBITNODE_PACKED_ROCKSDB_BATCH=1`; default proof commits keep the proven
  WriteBatch primitive path because packed encoding regressed 50k wall time.
- Debug-only hot-path allocation/copy telemetry is available with
  `MOJOBITNODE_PROFILE_HOTPATH=1`. It emits a `hotpath_profile` object for
  slice/clone/list-copy, script stack churn, sighash assembly, job/context copy,
  and native argument-prep counters. Leave it unset for comparable benchmark
  artifacts; use it to choose the next narrow optimization.
- Legacy sighash now has a Mojo-owned cached preimage builder using
  transaction-level serialized input/output components. The uncached builder is
  kept as the byte-for-byte reference, and focused smokes compare cached output
  across `SIGHASH_ALL`, `NONE`, `SINGLE`, and `ANYONECANPAY` variants.
- Zig-style shadow crypto is diagnostic-only. Native `libsecp256k1` remains the
  comparable proof backend; the pure Mojo backend now implements correctness-
  first BIP340 Schnorr verification and Taproot tweak checks with
  libsecp-guided fixed-limb field multiplication and Jacobian group operations,
  while leaving ECDSA unsupported. `--shadow-crypto` emits a separate
  `port.script_corpus_shadow_crypto.v1` artifact with explicit pure backend
  support/unsupported rows, per-attempt `shadow_duration_ms`, aggregate shadow
  timing, large-fixture size metrics, and no native fallback. The current corpus
  shadow slice supports all 17 Taproot fixtures, including the large
  `scripts.p2tr_tapscript_71267`, `scripts.p2tr_tapscript_121035`, and
  `scripts.p2tr_tapscript_126975` stress rows, while leaving ECDSA-bearing
  non-Taproot rows unsupported. Broader pure shadow coverage waits on
  zero-disagreement rows that stay under the 5000ms per-row guardrail. See
  `docs/LIBSECP_TRANSLATION_NOTES.md` before changing the pure secp internals.

The proof binary is intentionally bounded. It implements the offline corpus and
local Reference 5k/50k proof paths, but it does not implement external peers,
supervisor loops, 100k/tip benchmark lanes, or tip maintenance.

The supported `mojobitnode` command is Mojo-owned and reports
`entrypoint_language: "mojo"`.
Consensus logic, hashes, TapTweak construction, script execution,
fixture/result shaping, and storage-proof orchestration stay in Mojo. The C
boundary is limited to generic native primitives and non-consensus runtime glue.

The diagnostic `script-corpus-dev` surface remains available for fixture-level
debugging. The public `script-corpus` command is the evidence surface and emits
canonical `port.script_corpus_result.v1` JSON with Mojo-owned `45/45` coverage.
`script-corpus --shadow-crypto` is a separate diagnostic comparator surface and
must not be imported as canonical corpus evidence. Unsupported rows are expected
for ECDSA fixtures and for Taproot fixtures outside the current bounded pure
shadow slice.

## Commands

Host/local surface:

```bash
make host-deps-check
make host-deps-install
make host-setup
make host-mojo-version
make host-build
make host-status
make host-native-crypto-vectors
make host-native-boundary-audit
make host-storage-proof
make host-script-corpus-dev
make host-script-corpus
make host-script-corpus-shadow
make host-local-reference-proof
make host-shakedown-50k-proof
make host-smoke-once
make host-toolchain-smoke
make host-parallel-runner-smoke
make host-script-corpus-foundation-smoke
make host-block-core-smoke
```

Homebrew provides `uv`, `rocksdb`, `secp256k1`, `pkgconf`, and
`python@3.11`. Mojo itself is not installed by Homebrew; the host surface uses a
repo-local `.venv` and installs the pinned Mojo package with `uv`.

Docker surface:

```bash
make docker-config
make docker-build
make docker-mojo-version
make docker-warm
make docker-status
make docker-native-crypto-vectors
make docker-native-boundary-audit
make docker-storage-proof
make docker-script-corpus
make docker-script-corpus-shadow
make docker-proof-local
make docker-proof-50k
make docker-smoke-once
make docker-toolchain-smoke
make docker-parallel-runner-smoke
```

If Debian cannot install or run Mojo, stop the spike and record that as the
blocker. Do not switch this spike to Ubuntu silently.

## Agent Tooling

Read `docs/AGENT_BRIEF.md` before substantial Mojo edits. Mojo syntax and tools
move quickly, so agents should refresh the generated local docs cache instead of
guessing from stale model memory:

```bash
make mojo-docs-cache
make mojo-docs-status
```

The cache is generated under `.mojo-docs/` and is intentionally ignored. Optional
operator-local Mojo AI skills can be installed with:

```bash
npx skills add modular/skills --skill mojo-syntax
npx skills update
```

Those skills are not vendored and are not required by the spike.

For parallel script-runner work, also read
`docs/PARALLEL_RUNNER_RESEARCH.md`. Comparable proof paths collect a
deterministic block-level script-job batch; defaults execute it sequentially.
Setting `MOJOBITNODE_PAR_SCRIPT_VERIFY=1` enables the diagnostic Mojo
`parallelize` runner when a block has at least `MOJOBITNODE_SCRIPT_MIN_INPUTS`
script jobs and `MOJOBITNODE_SCRIPT_THREADS` is not `1`. UTXO deletes, unspent
creates, undo, block storage, and metadata are still staged by Mojo and
committed through one RocksDB batch only after script verification passes.
Before script verification, block connect gathers distinct external prevouts
for the block, loads them with one ordered RocksDB `multi_get`, and keeps
same-block created/spent lookup in Mojo-owned indexed helpers while preserving
ordered undo and commit lists. Sighash precompute is selected by script family:
BIP143 cache, Taproot cache, both, or neither. The packed RocksDB batch apply
primitive is tested but opt-in for profiling with
`MOJOBITNODE_PACKED_ROCKSDB_BATCH=1`; default proof output should normally show
`rocksdb_batch_pack: 0`.
Project evidence promotion remains a later explicit step after a fresh artifact
self-proves positive parallel batch metrics and passes the benchmark contract.
Native crypto call counters are always emitted, but per-call crypto timing is
profiling-only to keep benchmark hot paths lean. Set
`MOJOBITNODE_PROFILE_CRYPTO=1` when a run specifically needs `ecdsa_ms`,
`schnorr_ms`, `taproot_tweak_ms`, or `native_bridge_ms`; default benchmark
proofs should treat those timing fields as zero and use `script_verify` /
`script_wall_ms` for comparable script cost.
Set `MOJOBITNODE_PROFILE_HOTPATH=1` only for diagnostic runs that need
`hotpath_profile` counters. The profile is passive and should preserve target
hashes, UTXO counts, runner truth, and required telemetry fields, but its
overhead should not be used as leaderboard evidence.
The current hot-path target is legacy sighash assembly; stack churn and native
argument preparation remain secondary until fresh profile evidence says
otherwise.

Use the native-boundary audit targets before trusting new proof output. They
fail on direct SSL-family crypto linkage or unclassified exported
`mojobitnode_*` C symbols. The Docker audit may report TLS/SSL packages pulled
in by Debian package closure; those packages are not accepted as Mojo consensus
crypto unless the shim directly links or calls them.
