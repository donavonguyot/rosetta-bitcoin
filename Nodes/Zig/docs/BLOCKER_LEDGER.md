# ZigNode Blocker Ledger

ZigNode starts from the Shared consensus runway and should not rediscover known
script blockers by syncing until failure.

## Historical Regression Anchors

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
follower_notes: Project owns current imported script-corpus posture. Keep this entry as a regression anchor for Zig-native script verification.
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
follower_notes: Project owns current imported benchmark posture. Live external P2P discovery, tip maintenance, and binary gate remain separate gates.
```
