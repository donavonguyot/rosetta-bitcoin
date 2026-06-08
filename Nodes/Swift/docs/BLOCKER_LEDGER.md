# Swift Blocker Ledger

This ledger tracks Swift consensus and sync blockers. Passing benchmark gates is
evidence, not a substitute for the binary end gate: independently validate and
maintain testnet4 tip.

## Historical Evidence Notes

Query Project for current imported Swift evidence, benchmark gates, and
consensus runway posture. Older bounded proof summaries are historical handoff
context and must not be treated as live gate status.

## Known Unproven Surfaces Before Tip Claim

```text
height: multiple
block_hash:
txid:
input_index:
spent_script_pubkey:
failure: audit finding, not a live Swift blocker
missing_rule: consensus_parity_before_tip
swift_fix: pending
test_fixture: pending focused Swift regressions plus shared corpus
follower_notes:
- Swift must not claim tip readiness from corpus/5k/10k alone.
- Audit and prove nested P2SH->P2WPKH, CLTV/CSV, Taproot script-path binding,
  annex/code-separator handling, tapscript-only rules, duplicate inputs, and
  value conservation before long tip sync.
```

## Cleared: height 6975 - Taproot key-path region

```text
height: 6975
block_hash:
txid: 12376f5a136a337ce4ea4025dbef2c18158945ef6aac58f2fc4d7c5fe81dff62
input_index: 0
spent_script_pubkey: P2TR
failure: historical Swift 10k stop on taproot_witness_shape
missing_rule: taproot_key_path_verification
swift_fix: P2TR key-path Schnorr verification with BIP341 key-path sighash
test_fixture: Docker local-reference proof through 10000
follower_notes:
- Keep this as a regression gate. A witness with one stack item is key-path,
  not malformed script-path.
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
swift_fix:
test_fixture:
follower_notes:
```
