# Testnet4 consensus blockers

This file mirrors the live blocker ledger in a compact, follower-friendly format.
Use `docs/BLOCKER_LEDGER.md` for the full run history and operational notes.

## Current blocker cleared: 136369

```text
height: 136369
block_hash: 00000000000000013bac826dbc0a7fcfd3e60bf4bc2ab34abb53a219c9762df3
txid: 34bbb5793c54f9e2530c88e8b0f7c2517b875bd29ffcd505bdb8abd7f8adf1dc
input_index: 0
spent_script_pubkey: 002015d8d785605bb57624a0fb5ce61211f3279edb9b6a9a5750f602bcbe5451537d
template: P2WSH
missing_rule: OP_BOOLAND (0x9a) in witness script
java_fix: ScriptInterpreter.evaluate OP_BOOLAND via castToBool conjunction
regression_test: P2wshBooland136369RegressionTest
fixtures: src/test/resources/fixtures/tx_p2wsh_booland_136369*
harvest: scripts/harvest_block136369_fixtures.py
```

## Recently cleared blockers

```text
133634: P2TR tapscript CSV stack disable-flag no-op
132361: legacy P2SH OP_ABS (0x90)
126975: P2TR tapscript OP_2OVER (0x70) + OP_OVER (0x78)
121035: P2TR tapscript OP_BOOLOR (0x9b)
118555: bare legacy mega-script (OP_DEPTH/OP_ROLL/OP_MIN + bare-puzzle CMS)
116040: legacy P2SH OP_RIPEMD160 (0xa6)
108972: legacy P2SH OP_2SWAP/OP_PICK/OP_2OVER/OP_DEPTH
108508: P2TR tapscript OP_1SUB (0x8c)
107951: legacy P2PKH terminal stack (extra scriptSig item)
100372: P2TR tapscript OP_0NOTEQUAL (0x92)
98631: legacy P2WSH OP_NIP (0x77)
98025: legacy P2WSH OP_WITHIN (0xa5)
89632: P2TR tapscript CLTV/CSV BIP65/BIP112 no-op when tx nVersion < 2
87214: P2TR tapscript OP_IFDUP (0x73)
82921: legacy P2SH OP_NOT (0x91) + OP_SHA1 (0xa7)
82856: P2TR tapscript OP_SHA1 (0xa7)
82112: legacy P2SH OP_NOP (0x61)
78841: P2TR tapscript OP_MAX (0xa4)
71267: P2TR tapscript stack ops and OP_NUMNOTEQUAL opcode mapping
70924: P2TR tapscript OP_TUCK and related opcode surface
67562: P2TR tapscript OP_HASH256 (0xaa)
```
# Consensus blockers — testnet4 (JavaNode)

Live stall history for testnet4 block connect. See `BLOCKER_LEDGER.md` for full template and follower notes.

| Height | Missing rule | Template | Status |
|--------|--------------|----------|--------|
| 136369 | OP_BOOLAND (0x9a) P2WSH witness | P2WSH | **fixed** — `P2wshBooland136369RegressionTest` |
| 133634 | CHECKSEQUENCEVERIFY 5-byte operand + stack disable-flag no-op | P2TR script-path | **fixed** — `P2trTapscript133634RegressionTest` |
| 132361 | OP_ABS (0x90) legacy P2SH redeem | P2SH | **fixed** — `P2shAbs132361RegressionTest` |
| 126975 | OP_2OVER (0x70) + OP_OVER (0x78) tapscript | P2TR script-path | **fixed** — `P2trTapscript126975RegressionTest` |
| 121035 | OP_BOOLOR (0x9b) tapscript | P2TR script-path | **fixed** — `P2trTapscript121035RegressionTest` |
| 107951 | legacy P2PKH terminal stack (extra scriptSig item) | P2PKH | **fixed** — `P2pkh107951RegressionTest` |
| 100372 | OP_0NOTEQUAL (0x92) tapscript | P2TR script-path | **fixed** — `P2trTapscript100372RegressionTest` |
| 98631 | OP_NIP (0x77) legacy P2WSH witness | P2WSH | **fixed** — `P2wshNip98631RegressionTest` |
| 98025 | OP_WITHIN (0xa5) legacy P2WSH witness | P2WSH | **fixed** — `P2wshWithin98025RegressionTest` |
| 89632 | CLTV/CSV (0xb1/0xb2) no-op on nVersion&lt;2 tapscript | P2TR script-path | **fixed** — `P2trTapscript89632RegressionTest` |
| 87214 | OP_IFDUP (0x73) tapscript | P2TR script-path | **fixed** — `P2trTapscript87214RegressionTest` |
| 82921 | OP_NOT (0x91) + OP_SHA1 (0xa7) legacy P2SH | P2SH | **fixed** — `P2shSha182921RegressionTest` |
| 82856 | OP_SHA1 (0xa7) tapscript | P2TR script-path | **fixed** — `P2trTapscript82856RegressionTest` |
| 82112 | OP_NOP (0x61) legacy P2SH redeem | P2SH | **fixed** — `P2sh82112RegressionTest` |
| 78841 | OP_MAX (0xa4) tapscript | P2TR script-path | **fixed** — `P2trTapscript78841RegressionTest` |
| 71267 | OP_ROLL/DEPTH/ROT/2SWAP/3DUP/BOOLAND/NOT; OP_NUMNOTEQUAL | P2TR script-path | **fixed** — `P2trTapscript71267RegressionTest` |
| 70924 | OP_TUCK + stack/altstack/min/max surface | P2TR script-path | **fixed** — `P2trTapscript70924RegressionTest` |
| 67562 | OP_HASH256 (0xaa) tapscript | P2TR script-path | **fixed** |

## Current head

- **validated_height:** 136562 (136369 OP_BOOLAND fix landed; first resume subchunk +194 blocks)
- **next blocker height:** (unknown — resume supervisor active; peer timeout retry at 136562)
- **target chunk:** `CHUNK_TOTAL=55000 SUBCHUNK_SIZE=1000 DATA_DIR=./data-java PEERS=127.0.0.1:48333 ./scripts/sync_supervisor.sh`
