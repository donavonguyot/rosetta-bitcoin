# RustNode Blocker Ledger

## Last recorded evidence

```text
implementation: RustNode
node_id: rsbitnode-native-storage
validated_height: 2 in bounded storage proof only
local_reference_validated_height: 10000 in host and Docker Core RPC replay
baseline_5k_p2p: passed in Docker local Reference P2P proof
baseline_5k_p2p_artifact: Nodes/Shared/conformance/results/rust_docker_baseline_5k_benchmark_2026-06-04.json
baseline_5k_p2p_validated_height: 5000
baseline_5k_p2p_validated_hash: 000000000e3cb5b92e9765ed9c80c6b06f3d0a186478b330dd5e6b274acf03e2
binary_gate_status: not_attempted
current_blocker: none for bounded local-reference target 10000
```

## Notes

The Rust scaffold now fetches raw blocks from local Reference Core, validates
header hash, proof-of-work, previous links, merkle roots, parses transactions,
and connects UTXOs through the optimized RocksDB batch commit path. It now
passes the bounded local-reference target through height 10000 without using
another port or Core as a validation oracle. The 5k P2P comparator uses local
Reference Core only as a byte source over Bitcoin P2P; it remains a bounded
proof harness, not live tip maintenance.

The previous first Taproot blocker is cleared:

```text
height: 6975
block_hash: 000000000170ab1f84b7e3c702778a9eb9e71fdf5065037bce65e90d553f8f91
txid: 12376f5a136a337ce4ea4025dbef2c18158945ef6aac58f2fc4d7c5fe81dff62
input_index: 0
spent_script_pubkey: 512096519126915cde17e68250819b504b3fda380b8d98e3540a3f2baa3b011eb29c
failure: unsupported Rust scriptPubKey template: 512096519126915cde17e68250819b504b3fda380b8d98e3540a3f2baa3b011eb29c
missing_rule: P2TR key-path/script verification
status: cleared by Rust-native P2TR key-path/script verification
```

The shared 45-fixture Shared script corpus now passes `45/45` through a
Rust-native verifier. Covered shared blocker semantics include P2SH/nested
witness, P2WSH, bare multisig, CLTV/CSV, legacy/BIP143/Taproot sighash, P2TR
key-path, tapscript control-block validation, and blocker opcodes through the
Java-cleared fixture trail up to height 136369.
