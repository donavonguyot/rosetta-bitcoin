# RustNode Blocker Ledger

## Historical evidence notes

This ledger preserves durable Rust blocker facts. Query Project for current
imported Rust evidence, benchmark gates, and consensus runway posture; bounded
proof summaries in this ledger are historical handoff context, not live status.

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
