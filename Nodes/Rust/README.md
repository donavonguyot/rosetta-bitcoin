# rsbitnode

`rsbitnode` is the Rust follower port for the RosettaBitcoin workspace. The
first milestone is a Core-native scaffold: RocksDB-owned storage metadata,
status JSON, storage proof output, Chainstate Codec v2 vector checks, native
crypto vector plumbing, Docker smoke/proof surfaces, and a Rust script-corpus
harness for the shared 45-fixture NodeCore corpus.

This milestone does not claim live sync, block connection, script verification
clearance, or binary-gate progress.

## Commands

```bash
make build
make test
make rust-node-status
make rust-node-storage-proof
make rust-node-codec-vectors
make rust-node-native-crypto-vectors
make rust-node-script-corpus
```

## Native/Core State

Native state lives under the selected datadir:

```text
<datadir>/
  .rsbitnode_native_storage
  chainstate-rocksdb/
```

No SQLite artifact is allowed in the Rust native datadir. Status and storage
proof read Rust-owned RocksDB metadata directly.

## Script Corpus

`rsbitnode script-corpus` loads all 45 entries from
`NodeCore/conformance/fixtures/scripts/manifest.json` and verifies that the
referenced fixture files are present and readable. Until Rust has an independent
script verifier, each fixture row is recorded as `not_implemented`; this is a
harness proof, not script conformance clearance.

## Docker

```bash
make docker-config
make docker-build
make docker-status
make docker-proof-local
make docker-smoke-once
```
