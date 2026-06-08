# ZigNode

ZigNode is the Zig follower port for the RosettaBitcoin workspace.

For code structure and implementation scope, read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
For imported Zig posture, use Project reports from the repository root:

```bash
python3 Project/scripts/report.py --db Project/project.db --section port-status
python3 Project/scripts/report.py --db Project/project.db --section consensus-runway
python3 Project/scripts/report.py --db Project/project.db --section baseline-5k
```

Query Project for current imported runway posture instead of treating README
implementation notes as live status.

Public names:

- Port key: `zig`
- Binary: `zigbitnode`
- Node name: `ZigNode`
- Default datadir: `./data-zig`
- Native marker: `.zigbitnode_native_storage`
- RocksDB path: `chainstate-rocksdb/`
- Lock file: `.zigbitnode.lock`

Local prerequisites assume Homebrew:

```bash
brew install zig rocksdb secp256k1
```

Implementation surfaces:

- RocksDB native storage smoke path is implemented.
- Chainstate Codec v2 golden vector checks are implemented.
- Native crypto backend availability is wired through `libsecp256k1`.
- Shared script corpus is implemented with a Zig-native verifier and reports
  `45/45` with `engine=zig_native`, `delegated=false`, and
  `crypto_backend=libsecp256k1`.
- Local Reference P2P proof commands emit product progress for Project-owned
  benchmark artifact assembly.

Useful commands:

```bash
zig build test
make zig-node-codec-vectors
make zig-node-native-crypto-vectors
make zig-node-storage-proof
make zig-node-script-corpus
make docker-config
make docker-build
```

ZigNode must not claim live external P2P discovery, tip maintenance, or binary
gate completion until the Shared contracts are independently proven.
