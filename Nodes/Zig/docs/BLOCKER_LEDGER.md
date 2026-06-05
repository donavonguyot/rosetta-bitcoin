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
height: 5000
block_hash: 000000000e3cb5b92e9765ed9c80c6b06f3d0a186478b330dd5e6b274acf03e2
txid:
input_index:
spent_script_pubkey:
failure: cleared by Zig local Reference P2P proof
missing_rule:
python_fix:
test_fixture: baseline_5k_p2p benchmark gate
follower_notes: Current Docker proof emits zig_docker_baseline_5k_benchmark_2026-06-05-zig-5k.json with validated_height=5000, chainstate_utxo_count=4574, fresh_state=true, WAL enabled, current_blocker=null, and binary_gate_status=not_attempted. Live external P2P discovery, tip maintenance, and binary gate remain out of scope.
```
