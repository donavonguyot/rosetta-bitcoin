# gobitnode blocker ledger

This ledger preserves durable Go blocker facts. Query Project for current
imported Go evidence, benchmark gates, and consensus runway posture; bounded
proof summaries in this ledger are historical handoff context, not live status.

## Cleared: height 739 — first spend-path script verification

```text
height: 739
block_hash: 000000004cfba4fe6174c546086df7fb52b3d65d44788c0ee8acf436dd28de32
txid: 475ff67b2f2631c6b443635951d81127dcf21898f697d5f7c31e88df836ee756
input_index: 0
prev_txid: f87060189216e5c7cc7bd94fff99a976104c4591ccf38619549ffdc2869f7a6b
prev_vout: 0
spent_script_pubkey: 0014a54e2a1ec06389203887661535ed118b7d053889
spent_value: 5000000000
spent_height: 610
spent_coinbase: true
failure: Go connect replay reached a spend path before native script verification was implemented
missing_rule: script_verify_not_implemented
source_port: Go
source_fixture: local Core RPC raw blocks through 10000
port_fix: native Go spend-path script verification and atomic spend/output staging
test_fixture: Shared script corpus plus local-reference replay through 10000
follower_notes: Cleared by Docker local-reference proof through height 10000; do not treat as live P2P tip proof.
```

## Cleared: height 6975 — Taproot key-path region

```text
height: 6975
failure: historical follower checkpoint for early Taproot spend handling
missing_rule: taproot_key_path_verification
source_port: Go
source_fixture: local Core RPC raw blocks through 10000
port_fix: native Go Taproot/Tapscript verifier backed by libsecp256k1 Schnorr and x-only tweak support
test_fixture: Shared script corpus plus Docker local-reference replay through height 10000
follower_notes: Docker replay crossed height 7000 and completed height 10000 with current_blocker=null. The 5k P2P comparator is a separate Project benchmark lane.
```

## Template

```text
height:
block_hash:
txid:
input_index:
spent_script_pubkey:
failure:
missing_rule:
source_port:
source_fixture:
port_fix:
test_fixture:
follower_notes:
```
