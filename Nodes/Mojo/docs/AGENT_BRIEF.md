# Mojo Agent Brief

This directory is a bounded Mojo feasibility spike, not a full RosettaBitcoin
port. Current work should preserve the spike boundary unless a later plan
explicitly adds consensus, P2P, or baseline gates.

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

The supported executable is `mojobitnode` with exactly these spike commands:

```text
status --datadir <path> --json
native-crypto-vectors --vectors <path> --result-path <path>
storage-proof --datadir <path> --result-path <path>
```

The CLI is Mojo-owned and must continue to report
`entrypoint_language: "mojo"`, `native_shim: "owned_c"`, and
`delegated: false` where applicable. Do not reintroduce Python delegation or a
separate C proof executable.

`script-corpus-dev --manifest <path> --fixture-id <id> --result-path <path>` is
a host diagnostic foundation for the future corpus runner. It currently supports
only `scripts.bare_multisig_27840`, which now passes through Mojo-owned legacy
sighash/script handling plus the owned C shim's generic `libsecp256k1` DER
verifier. Keep it out of `current_evidence.json` and Docker manifest coverage
until it is a real 45/45 corpus command.

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
```

## Future 5k Order

Do not jump from this spike directly to a live 5k claim. The future port order is:

1. Shared script corpus command and proof shape.
2. Strict corpus preflight clean in Project.
3. Local Reference P2P/block-connect implementation.
4. Strict 5k baseline proof with RocksDB runtime truth, native crypto, WAL,
   fixed benchmark knobs, `core_spendable_v1` UTXO accounting, and canonical
   importable proof JSON.

Until those gates exist, keep Project status language at feasibility-spike level.
