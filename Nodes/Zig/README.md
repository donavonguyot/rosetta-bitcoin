# Zigibit / zigbitnode

Zigibit is the Zig testnet4 node developed in RosettaBitcoin. Its executable
remains `zigbitnode`; evidence uses port key `zig` and implementation `ZigNode`.
See [architecture](docs/ARCHITECTURE.md), [contributing](CONTRIBUTING.md),
[security](SECURITY.md), [dependency provenance](docs/DEPENDENCIES.md), and the
[blocker ledger](docs/blocker_ledger.jsonl).

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

RB can also test a pinned external checkout without its sibling-directory layout:

```sh
export RB_ZIG_SOURCE=/path/to/zigibit
python3 Project/scripts/run_zig_external_lab.py
```

Run that command from RB with Python 3.11 or newer. The same `RB_ZIG_SOURCE`
selection applies to RB Docker lab targets and Project campaign provenance.
See the [RB consumer guide](https://github.com/donavonguyot/rosetta-bitcoin/blob/main/Docs/zigibit-consumers.md)
for supported commands and legacy exceptions. Supply a clean standalone export, or use `--manifest`
with a clean inventory produced by `snapshot_ci_source.py` after a future move.
The adapter verifies all inventoried inputs, uses only the external tree as its
Docker build context, checks the built revision and binary hash, and runs offline
tests, corpus, codec, storage smoke, fresh local Reference P2P through height
5,000, and separate-process reopen/resume checks. No Project DB or RB source is
mounted into the node. RB still owns topology, orchestration, and evidence import.

Each invocation creates unique proof volumes and a new results directory under
`RB_STATE_ROOT/project-campaigns/`. It refuses existing campaign state, never
resets operational volumes, and retains failed runs for diagnosis. Review the
compact `bounded.json`, `storage.json`, and `corpus.json` before promoting evidence;
raw outputs and logs remain in the campaign directory. This is a bounded
extraction check; it does not replace ranked benchmark campaign evidence.

Portability does not establish independent empty-state sync to tip, tip
maintenance, serving, or relay readiness. Those require their own runtime proof.

## Standalone CI and dependency updates

The exported `.github/workflows/zig-standalone.yml` runs macOS and Linux builds,
unit tests, documentation, replay diagnostics, and offline vectors with Zig
0.16.0. It checks the default C-binding/both-store lane and the experimental
own-curve/native lane. Linux also builds the offline Docker test stage for both
lanes. In RosettaBitcoin, CI first exports outside the checkout and uses only
that export as the source and Docker context. Run its host checks locally with:

```sh
python3 scripts/ci_standalone.py --zig /path/to/zig-0.16.0/zig
python3 scripts/ci_standalone.py --zig /path/to/zig-0.16.0/zig \
  --store native --crypto-backend own_curve
```

After an eventual repository move, CI inventories each clean Git revision in
`.zig-cache/ci-source-manifest.json` and verifies it after testing. The original
export manifest stays unchanged as provenance. Compiler downloads are pinned
by version and SHA-256 in `scripts/install_ci_zig.py` and the Dockerfile.

Until that move, RosettaBitcoin remains the canonical node source. After the
move, node changes should originate in Zigibit's repository; Rosetta lab
integration should consume a pinned revision instead of maintaining a second
editable copy. Capture, activity sampling, stimulus funding, Project imports,
and benchmark orchestration remain Rosetta tools. They are not node runtime
or standalone test dependencies.

The crypto package and Shared fixtures are vendored snapshots with source paths
and hashes in the export manifest. Update them deliberately from their canonical
Rosetta sources, record the upstream revision, preserve licenses, and rerun the
standalone acceptance checks. Do not regenerate frozen expected bytes merely to
make a failing test pass. Shared contracts and Project readiness claims remain
owned by RosettaBitcoin.
