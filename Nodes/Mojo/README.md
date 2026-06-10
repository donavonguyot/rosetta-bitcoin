# mojobitnode

`mojobitnode` is a bounded Mojo feasibility spike for RosettaBitcoin. It is not
a full port and does not claim 5k baseline readiness.

The spike asks one narrow question: can Mojo install reproducibly and prove the
native prerequisites a future port would need?

## Spike Surface

- Debian `bookworm-slim` Docker image.
- Host development surface with Homebrew native dependencies.
- Mojo installed with the official `uv pip install mojo` route.
- `mojobitnode` is a compiled Mojo entrypoint.
- Native calls go through a tiny owned C shim, not Python delegation.
- Native `libsecp256k1` vector checks.
- RocksDB runtime truth smoke against `chainstate-rocksdb`.
- Project-shaped status JSON.

The proof binary is intentionally small. It does not implement P2P, script
corpus, block connect, benchmark artifacts, supervisor loops, or Project evidence
updates.

The supported `mojobitnode` command is Mojo-owned and reports
`entrypoint_language: "mojo"`.

## Commands

Host/local surface:

```bash
make host-deps-check
make host-deps-install
make host-setup
make host-build
make host-status
make host-native-crypto-vectors
make host-storage-proof
make host-smoke-once
```

Homebrew provides `uv`, `rocksdb`, `secp256k1`, `pkgconf`, `openssl@3`, and
`python@3.11`. Mojo itself is not installed by Homebrew; the host surface uses a
repo-local `.venv` and installs the Mojo package with `uv`.

Docker surface:

```bash
make docker-config
make docker-build
make docker-warm
make docker-status
make docker-native-crypto-vectors
make docker-storage-proof
make docker-smoke-once
```

If Debian cannot install or run Mojo, stop the spike and record that as the
blocker. Do not switch this spike to Ubuntu silently.
