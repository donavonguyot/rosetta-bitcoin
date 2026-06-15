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
- Native calls go through a tiny owned C shim, not Python delegation.
- Native `libsecp256k1` vector checks.
- RocksDB runtime truth smoke against `chainstate-rocksdb`.
- Project-shaped status JSON.
- Docker Shared script corpus proof (`45/45`).
- Local Reference P2P proof surface for the strict 5k baseline candidate.

The proof binary is intentionally bounded. It implements the offline corpus and
local Reference 5k proof paths, but it does not implement external peers,
supervisor loops, long-run benchmark lanes, or tip maintenance.

The supported `mojobitnode` command is Mojo-owned and reports
`entrypoint_language: "mojo"`.

The diagnostic `script-corpus-dev` surface remains available for fixture-level
debugging. The public `script-corpus` command is the evidence surface and emits
canonical `port.script_corpus_result.v1` JSON with Mojo-owned `45/45` coverage.

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
make host-storage-proof
make host-script-corpus-dev
make host-script-corpus
make host-local-reference-proof
make host-smoke-once
make host-toolchain-smoke
make host-script-corpus-foundation-smoke
make host-block-core-smoke
```

Homebrew provides `uv`, `rocksdb`, `secp256k1`, `pkgconf`, `openssl@3`, and
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
make docker-storage-proof
make docker-script-corpus
make docker-proof-local
make docker-smoke-once
make docker-toolchain-smoke
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
