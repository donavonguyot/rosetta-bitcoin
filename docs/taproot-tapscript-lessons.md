# Taproot And Tapscript Lessons

Taproot key-path and script-path are separate consensus surfaces.

## Key-Path

- First shared testnet4 milestone: height `6975`.
- Requires BIP340 Schnorr verification and BIP341 key-path sighash.
- Clearing key-path does not imply script-path support.

## Script-Path

- First shared C# blocker: height `22830`.
- Required pieces include control block parsing, leaf hash calculation, taproot
  output key commitment check, tapscript evaluation, and BIP342 sighash.
- Witness shape classifies key-path vs script-path:
  - key-path spends have a single Schnorr signature witness item.
  - script-path spends end with tapscript and control block items.

## Shared Rule Trail

Java has cleared a long tapscript trail through `136369`, including stack ops,
hash ops, CLTV/CSV edge cases, terminal stack truthiness, mega-witness scripts,
and script-number behavior. These facts are follower fixtures, not validity
oracles.

## C# Next Diagnostic

Before implementing C# tapscript, add a first-class C# or NodeCore diagnostic
that reports:

```text
height
block_hash
txid
input_index
spent_script_pubkey
witness_item_count
template
taproot_spend_type
tapscript_length
control_block_length
leaf_version
missing_rule
```
