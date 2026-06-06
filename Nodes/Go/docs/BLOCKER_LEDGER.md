# gobitnode blocker ledger

Go has no current blocker inside the bounded local-reference proof through
height 10000. The current milestone remains offline/Core-native proof plus
bounded local-reference replay and a 5k local Reference P2P comparator; this is
not live P2P tip maintenance or binary-gate completion.

## Last recorded evidence

```text
runtime_surface: docker
peer_mode: local_reference
peer: see proof artifact; current reruns use bitcoin-core-testnet4:48333
evidence_lane: baseline_5k_p2p
header_height: 5000
stored_block_height: 5000
validated_height: 5000
validated_hash: 000000000e3cb5b92e9765ed9c80c6b06f3d0a186478b330dd5e6b274acf03e2
sync_status: blocks_current
current_blocker: null
chainstate_backend: rocksdb
native_crypto_backend: libsecp256k1
proof_result: Nodes/Shared/conformance/results/go_docker_baseline_5k_benchmark_2026-06-04.json
```

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
