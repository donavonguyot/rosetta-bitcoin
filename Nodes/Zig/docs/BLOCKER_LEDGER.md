# ZigNode Blocker Ledger

ZigNode starts from the Shared consensus runway and should not rediscover known
script blockers by syncing until failure.

## Current Blockers

### Shared Script Corpus Verifier

```text
height: shared 45-fixture corpus
block_hash:
txid:
input_index:
spent_script_pubkey:
failure: cleared by Zig-native script verifier
missing_rule:
python_fix: see Nodes/Shared/consensus runway and port references
test_fixture: Nodes/Shared/conformance/fixtures/scripts/manifest.json
follower_notes: Current proof reports 45/45 with engine=zig_native, delegated=false, and crypto_backend=libsecp256k1. Keep this entry as the regression anchor before 5k baseline work.
```

### Local Reference P2P 5k Gate

```text
height: 0
block_hash:
txid:
input_index:
spent_script_pubkey:
failure: Local Reference P2P byte-source and ordered connect path are not implemented.
missing_rule: honest P2P handshake, getdata/block fetch, parsing, PoW, merkle, UTXO connect, and per-block RocksDB batch commit
python_fix:
test_fixture: supporting_5k_p2p benchmark gate
follower_notes: Must emit zig_docker_supporting_5k_benchmark_<date>.json with validated_height >= 5000 and chainstate_utxo_count=4574.
```
