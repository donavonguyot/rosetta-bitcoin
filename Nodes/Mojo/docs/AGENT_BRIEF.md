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
  RocksDB, `secp256k1`, `pkgconf`, and OpenSSL.

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
storage-proof --datadir <path> --result-path <path>
script-corpus --manifest <path> --result-path <path>
local-reference-proof --datadir <path> --target 5000 --peer <host:port> --result-path <path>
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

`local-reference-proof` is the bounded 5k candidate path. It must use local
Reference P2P bytes, RocksDB operational truth, native `libsecp256k1`, and
`core_spendable_v1` UTXO accounting. Do not hand-edit a baseline claim; Project's
campaign harness owns accepted control artifacts and current benchmark evidence.

## Native Boundary

`src/mojo_native_shim.c` is the owned native boundary for RocksDB and
`libsecp256k1`. Keep command dispatch, JSON shaping, and user-visible CLI
behavior in Mojo. The shim should expose primitives only when Mojo interop is
not sufficient for the spike.

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

Do not use `mojo test`; current Mojo testing uses `TestSuite` and runs with
`mojo run`:

```bash
make host-toolchain-smoke
make docker-toolchain-smoke
make host-script-corpus-foundation-smoke
make host-block-core-smoke
make host-script-corpus
make host-local-reference-proof
make docker-script-corpus
make docker-proof-local
```

## Current Gate Order

The current port order is:

1. Keep Shared script corpus proof clean in Docker.
2. Keep local Reference P2P/block-connect proof clean to height 5000.
3. Let Project run the strict baseline campaign and own accepted evidence.
4. Only after baseline acceptance, plan the next gate separately.

Strict 5k requires RocksDB runtime truth, native crypto, WAL,
   fixed benchmark knobs, `core_spendable_v1` UTXO accounting, and canonical
   importable proof JSON.

Until Project accepts the control artifact, keep status language at candidate
level even when local debug proof passes.
