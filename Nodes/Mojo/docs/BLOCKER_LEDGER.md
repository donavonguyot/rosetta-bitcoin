# Mojo Blocker Ledger

This ledger tracks Mojo consensus and sync blockers. Passing benchmark gates is
evidence, not a substitute for the binary end gate: independently validate and
maintain testnet4 tip.

## Historical Evidence Notes

Query Project for current imported Mojo evidence, benchmark gates, and consensus
runway posture. Bounded proof summaries are historical handoff context and must
not be treated as live gate status.

## Cleared: height 56447 - Legacy bare multisig malformed pubkey

```text
height: 56447
block_hash: 000000000ae11eebf9807d5ac0f9966282c59a1e613e229aa2bf7aea266d4535
txid: cb5fe6b28e78371a6fd7f9439542ff6bf0082f070097c9a096220f2a786d521f
input_index: 0
prevout: 2085d9aa766e5fa91e91e65a2ee9fdbdb7733687ce2a93615a515e8eb904a8b0:0
spent_script_pubkey: 5121024db836286794689a8c19071bd34e14dba07f8cc9f2e5e6a04295744bec831ac4210297e673f0bc7bcc5caf227323704c50635c32f24d529d4ba95a40e3dfbeaf0db72102d3cf631e5256795e184d8e99147f0d3ecdf1731aeefaded215df811cbc55160053ae
failure: a legacy bare-multisig input presented a malformed public key; Bitcoin Core treats a malformed pubkey in non-witness legacy script as a failed signature match (key does not match), not as a fatal malformed-input error
missing_rule: legacy_bare_multisig_malformed_pubkey_softfail
mojo_fix: cleared
test_fixture: shared script corpus (bare_multisig) plus Mojo reject-case validators
follower_notes:
- Surfaced by the Mojo port en route to tip, after the 2026-06-15 evidence epoch (river past the photograph).
- Core semantics: in a non-witness legacy CHECKMULTISIG, a malformed pubkey is a failed key match, not a fatal script error; treating it as fatal would wrongly reject valid blocks.
- The fix preserved strict-DER enforcement and witness-v0 fail-closed behavior; only the legacy non-witness path was loosened to Core-equivalent leniency.
- Exact provenance was recovered on 2026-08-26 from preserved Bitcoin Core testnet4 block data. It is post-snapshot supplemental evidence and does not change Project evidence.
```
