# ocbitnode

`ocbitnode` is the OCaml follower foundation for RB testnet4 node proof work.
This first phase intentionally stops before P2P sync and 5k readiness. It proves
the risky native foundations first:

For code structure and honest scope, read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
For imported OCaml posture, use Project reports from the repository root:

```bash
python3 Project/scripts/report.py --db Project/project.db --section port-status
python3 Project/scripts/report.py --db Project/project.db --section consensus-runway
python3 Project/scripts/report.py --db Project/project.db --section baseline-5k
```

Query Project for current imported runway posture instead of treating README
proof notes as live status.

- stock OCaml 5 on Debian/Bookworm-style Docker images
- an owned minimal RocksDB C binding for runtime truth
- native `libsecp256k1` through opam `secp256k1` `0.5.0`
- Chainstate Codec v2 storage proof
- native OCaml Shared script corpus proof `45/45`
- reusable transaction/block parsing and a non-baseline block-connect skeleton

The binary gate remains `not_attempted` until a later P2P/header/block-sync phase.

## Commands

```bash
make build
make test
make ocbitnode-status
make ocbitnode-native-crypto-vectors
make ocbitnode-storage-proof
make ocbitnode-script-corpus
```

Docker is the primary foundation proof surface on hosts without opam/OCaml:

```bash
make docker-config
make docker-build
make docker-smoke-once
make docker-native-crypto-vectors
make docker-storage-proof
make docker-script-corpus
```

## CLI

```bash
ocbitnode status --datadir ./data-ocaml
ocbitnode storage-proof --datadir ./data-ocaml --result-path ../Shared/conformance/results/ocaml_rocksdb_codec_v2_storage_<date>.json
ocbitnode native-crypto-vectors --result-path ../Shared/conformance/results/ocaml_native_crypto_vectors_<date>.json
ocbitnode script-corpus --manifest ../Shared/conformance/fixtures/scripts/manifest.json --result-path ../Shared/conformance/results/ocaml_script_corpus_<date>.json --runtime-surface host
ocbitnode script-corpus --manifest ../Shared/conformance/fixtures/scripts/manifest.json --result-path /tmp/ocaml_one.json --runtime-surface host --fixture-id scripts.p2tr_tapscript_71267
```

## Current Boundary

The script-corpus command parses the fixture transaction and prevouts, dispatches
the spend template, computes legacy/BIP143/Taproot sighashes, and verifies the
spend with OCaml consensus/script code backed by native `libsecp256k1`. It emits
an importable `port.script_corpus_result.v1` artifact with verifier metadata
`engine=ocbitnode-native-script` and `delegated=false`.

The parser and block-connect prep modules are internal only. OCaml still makes
no Docker/local Reference P2P 5k claim; `docker_proof_local` and larger proof
commands remain `null` until sync exists.
