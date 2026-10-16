# Zigibit / zigbitnode

Zigibit is the Zig testnet4 node developed in RosettaBitcoin. Its executable
remains `zigbitnode`; evidence uses port key `zig` and implementation `ZigNode`.
See [architecture](docs/ARCHITECTURE.md) and the [blocker ledger](docs/blocker_ledger.jsonl).

## Build and test

Use **Zig 0.16.0**, Python 3.10 or newer, and a C toolchain. Default builds link
RocksDB and libsecp256k1. On macOS: `brew install rocksdb secp256k1`. On Debian:
`apt-get install build-essential librocksdb-dev libsecp256k1-dev python3`.
Install Zig 0.16.0 separately if your package manager supplies another release.
Homebrew on Apple Silicon is searched automatically; other library prefixes
can use Zig's `--search-prefix` option.

From the node directory:

```sh
make build ZIG=/path/to/zig-0.16.0/zig
make test ZIG=/path/to/zig-0.16.0/zig ZIG_ARGS='-Doptimize=ReleaseSafe'
make docs ZIG=/path/to/zig-0.16.0/zig
```

Direct equivalents are `zig build`, `zig build test`, and `zig build docs`.
Binaries, autodoc, and documentation coverage stay under `zig-out/`.
`make clean` removes build outputs only. Tests fail if required frozen fixtures
are missing; they never regenerate expected fixture bytes.

- `-Dstore=both|rocksdb|native` selects storage; default `both`.
- `-Dcrypto-backend=c_binding|own_curve` selects crypto; default `c_binding`.
- `-Dfixtures-root=PATH` selects fixture inputs with the Shared directory layout.
- `-Dshared-root=PATH` selects the root for default proof-result paths.
- `-Dsource-commit=SHA` records the source revision in `--build-info`.

The `own_curve` plus `native` build does not link RocksDB or libsecp256k1.
Own-curve is experimental public-input verification; node code owns Bitcoin
sighashes, signature suffixes, and Taproot tagged hashing.

## Standalone export

From the RosettaBitcoin workspace root:

```sh
python3 Project/scripts/export_zig_standalone.py /tmp/zigibit-source
```

The destination must be new and outside the workspace. The exporter copies node
source, materializes the canonical crypto library as `libsecp256k1-zig/`, and
bundles declared Shared fixture roots under `fixtures/`. It includes licenses
and a `standalone-manifest.json` with source revision, dirty-source flag,
original paths, and every exported file's SHA-256. Git metadata, datadirs,
Project database, build caches, and benchmark results are excluded. It does not
create a repository.

The exported tree needs no RosettaBitcoin checkout or Project scripts:

```sh
cd /tmp/zigibit-source
python3 scripts/verify_standalone.py
zig build -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseSafe -Dstore=both
zig build test -Doptimize=ReleaseSafe -Dstore=rocksdb
zig build test -Doptimize=ReleaseSafe -Dstore=native -Dcrypto-backend=own_curve
zig build docs
zig build run -- script-corpus
zig build run -- consensus-context
zig build run -- codec-vectors
zig build run -- test-capability --kind crypto-vectors --outcome-path zig-out/crypto-vectors.json
```

With bundled fixtures present, direct builds read `fixtures/` and write default
proof results below `zig-out/conformance/results/`. Rerun the checksum verifier
after testing to confirm source and fixture inputs were unchanged. Intentional
source edits require a new export for a matching manifest.

## Standalone Docker

From an exported tree, use only that tree as the build context. The test stage
runs offline after dependencies are installed:

```sh
docker build -f docker/Dockerfile --target test \
  --build-arg NODE_SOURCE=. --build-arg CRYPTO_SOURCE=libsecp256k1-zig \
  --build-arg FIXTURE_SOURCE=fixtures -t zigibit:test .
docker build -f docker/Dockerfile --target runtime \
  --build-arg NODE_SOURCE=. --build-arg CRYPTO_SOURCE=libsecp256k1-zig \
  -t zigibit:local .
docker run --rm --network none zigibit:local zigbitnode --build-info
```

Add `--build-arg STORE=native --build-arg CRYPTO_BACKEND=own_curve` for the
self-hosted build. The runtime image contains the binary and runtime libraries;
mount fixtures explicitly for corpus commands in that image.

## RosettaBitcoin integration

Inside RosettaBitcoin, `rosetta.mk` adds lab proof, fixture-package, and Reference
Docker topology targets. `ROSETTA=0` disables that layer. Normal build/test/docs
commands do not invoke Project. The crypto source remains canonical in Libraries
and is linked locally until export; other symlink inputs are refused.

Commands such as `make zig-node-storage-proof`, `make native-shadow-5k`, and
`make docker-proof-local` remain lab integration commands. Use isolated datadirs
under `RB_STATE_ROOT` (default `~/.rblab`), one writer per datadir, and fresh proof
state separate from operational state. Proof promotion and Project imports are
explicit, separate operations. Current imported status is queried from the
RosettaBitcoin root:

```sh
python3 Project/scripts/report.py --db Project/project.db --section port-status
python3 Project/scripts/report.py --db Project/project.db --section consensus-runway
```

Portability does not establish independent empty-state sync to tip, tip
maintenance, serving, or relay readiness. Those require their own runtime proof.
