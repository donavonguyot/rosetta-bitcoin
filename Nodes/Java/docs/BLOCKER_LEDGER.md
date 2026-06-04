# Blocker ledger — jbitnode

Every consensus unblock and live-chain stall must leave enough information for follower
ports to reproduce it without archaeology. Copy this template into issues, PR descriptions,
or run logs when recording a blocker.

## Historical checkpoint (2026-05-29)

Catch-up from local Core (`127.0.0.1:48333`, `DATA_DIR=./data-java`), single-writer — **binary gate passed @136863; sync stopped via `.stop_sync`**:

```text
checkpoint_height: 136863
validated_height: 136863
header_height: 136863
sync_status: blocks_current
current_blocker: (none — stale header warning @136567 prev_block mismatch from pre-fork repair)
missing_rule: none
ledger_entry_written: yes
binary_gate_status: passed (independent validation through 136863 on Core-aligned chain)
next_exact_rule: rm .stop_sync + preflight + supervisor or periodic HEADERS_MAX/BLOCKS_MAX tip refresh
peer: 127.0.0.1:48333
```

Shared root docs now carry the reusable Java lessons:

- `../../../Docs/blocker-ledger.md` for the canonical blocker handoff format.
- `../../../Docs/storage-contract.md` for RocksDB/native chainstate boundaries.
- `../../../Docs/native-crypto-contract.md` for backend reporting and vector rules.
- `../../../Docs/supervisor-contract.md` for durable sync supervisor behavior.
- `../../../Docs/taproot-tapscript-lessons.md` for Taproot key-path vs script-path
  guidance.

### P2WSH witness OP_BOOLAND live @136369 (passed)

```text
height: 136369
block_hash: 00000000000000013bac826dbc0a7fcfd3e60bf4bc2ab34abb53a219c9762df3
txid: 34bbb5793c54f9e2530c88e8b0f7c2517b875bd29ffcd505bdb8abd7f8adf1dc
input_index: 0
spent_script_pubkey: 002015d8d785605bb57624a0fb5ce61211f3279edb9b6a9a5750f602bcbe5451537d
failure: script verification failed for input 0 (unsupported opcode 0x9a OP_BOOLAND before fix)
missing_rule: OP_BOOLAND (0x9a) in P2WSH witness — RIPEMD160 hashlock + CHECKSIG conjunction
test_fixture: src/test/resources/fixtures/tx_p2wsh_booland_136369*, block_136369.hex
java_fix: ScriptInterpreter.evaluate OP_BOOLAND via castToBool stack conjunction
java_test: P2wshBooland136369RegressionTest (PASSING)
follower_notes: P2WSH witness script OP_SIZE 32 OP_EQUALVERIFY OP_RIPEMD160 … OP_EQUAL OP_SWAP pubkey OP_CHECKSIG OP_BOOLAND; witness len 3; prevout 12_838 sats; harvest scripts/harvest_block136369_fixtures.py @127.0.0.1:48332
witness_script_asm: OP_SIZE 32 OP_EQUALVERIFY OP_RIPEMD160 bb90f8acbd268b662c4074acb3877c711ce5dfef OP_EQUAL OP_SWAP 03f80b6154f42255428717741e6f8fef9be87511ff9120d51bfad279eedea42998 OP_CHECKSIG OP_BOOLAND
```

## Historical checkpoint (2026-05-29, superseded)

Catch-up from local Core (`127.0.0.1:48333`, `DATA_DIR=./data-java`), single-writer — **P2TR tapscript CSV stack disable-flag @133634 cleared; next blocker @136369**:

### P2TR tapscript CSV stack disable-flag live @133634 (passed)

```text
height: 133634
block_hash: 00000000000000015ec29857fab62c48cc035f2f9f315dce1c905ded3682f704
txid: d7cf3d38458c05b40651aa89e70b0d1eb64f94f4fcbb730dc9e52f20afe5ef6c
input_index: 0
spent_script_pubkey: 51206fccfbb9b6866623bb150ee234b95910952db82f72c72795cb6e7740579fa906
failure: script verification failed for input 0 (CSV 5-byte operand 0x80000001 overflowed signed int before fix)
missing_rule: OP_CHECKSEQUENCEVERIFY (0xb2) NOP when stack operand has disable flag — Core checks stack nSequence, not input; decodeScriptNumLong for 5-byte locktime operands
test_fixture: src/test/resources/fixtures/tx_p2tr_tapscript_133634*, block_133634.hex
java_fix: Tapscript.execCheckSequenceVerify — stack disable-flag NOP with long masks; ScriptNum.decodeScriptNumLong
java_test: P2trTapscript133634RegressionTest (PASSING)
follower_notes: tapscript PUSH(5) 0100008000 OP_CHECKSEQUENCEVERIFY OP_DROP x-only OP_CHECKSIG; witness len 3; input+stack sequence 0x80000001; prevout 5_000 sats; harvest scripts/harvest_block133634_fixtures.py @127.0.0.1:48332
tapscript_asm: 0100008000 OP_CHECKSEQUENCEVERIFY OP_DROP 8fb09f84… OP_CHECKSIG
```

## Historical checkpoint (2026-05-29, superseded)

Catch-up from local Core (`127.0.0.1:48333`, `DATA_DIR=./data-java`), single-writer — **legacy P2SH OP_ABS @132361 cleared; resume pending**:

```text
checkpoint_height: 132361
validated_height: 132360
sync_status: resuming
current_blocker: (none — legacy P2SH OP_ABS @132361 script verify landed)
missing_rule: (none for 132361) — was OP_ABS (0x90) in legacy P2SH redeem evaluation
ledger_entry_written: yes
binary_gate_status: passed (P2shAbs132361RegressionTest)
next_exact_rule: CHUNK_TOTAL=55000 SUBCHUNK_SIZE=1000 ./scripts/sync_supervisor.sh background from 132360
peer: 127.0.0.1:48333
```

### P2SH OP_ABS live @132361 (passed)

```text
height: 132361
block_hash: 000000000045aa6f5a0a29999ae056c04ed878ea500f6968c1f2d0b5da471b15
txid: 56fcdf23f9619d3c107132cda9cd4db9dc610aca2e295ddd9a881b1772a5776b
input_index: 0
spent_script_pubkey: a914fe441065b6532231de2fac563152205ec4f59c7487
failure: script verification failed for input 0 (unsupported opcode 0x90 OP_ABS before fix)
missing_rule: OP_ABS (0x90) in legacy P2SH redeem — abs(scriptnum) on stack top
python_reference: (no scout row)
test_fixture: src/test/resources/fixtures/tx_p2sh_abs_132361*, block_132361.hex
java_fix: OpCodes.OP_ABS=0x90; ScriptInterpreter.evaluate OP_ABS via ScriptNum.encodeScriptNum(Math.abs(value), 4)
java_test: P2shAbs132361RegressionTest (PASSING)
follower_notes: scriptSig pushes 1 -1 + redeem; redeem OP_2DUP OP_EQUAL OP_NOT OP_VERIFY OP_ABS OP_SWAP OP_ABS OP_EQUAL; empty witness; prevout 100_000 sats; harvest scripts/harvest_block132361_fixtures.py @127.0.0.1:48332
```

## Historical checkpoint (2026-05-29, superseded)

Catch-up from local Core (`127.0.0.1:48333`, `DATA_DIR=./data-java`), single-writer — **P2TR tapscript OP_2OVER/OP_OVER @126975 cleared; resume in flight**:

```text
checkpoint_height: 126975
validated_height: 130974 (resume passed 126975 and advanced +4,000 in first observed subchunks)
sync_status: resuming
current_blocker: (none for 126975 script verify — header-tip prev_block mismatch @136567 is operational, not consensus)
missing_rule: (none for 126975) — was tapscript OP_2OVER (0x70) + OP_OVER (0x78)
ledger_entry_written: yes
binary_gate_status: passed (P2trTapscript126975RegressionTest)
next_exact_rule: supervisor active with CHUNK_TOTAL=55000 SUBCHUNK_SIZE=1000 from 126974
peer: 127.0.0.1:48333
```

### P2TR tapscript OP_2OVER/OP_OVER live @126975 (passed)

```text
height: 126975
block_hash: 000000000000000298be9549a2617d1ff88e507db91383fb3f1ea34cd28fdcd3
txid: b8f4d614ba4b200063247ae4f3f15449e6b1b98ed718fd2a5e42239e660fa1ca
input_index: 0
spent_script_pubkey: 5120039613f555bac442eb628c0b7af7f6b19d1abf3aab2cde8a349c88f4b553cd2e
failure: script verification failed for input 0 (unsupported tapscript opcode 0x70/0x78 before fix)
missing_rule: tapscript OP_2OVER (0x70) + OP_OVER (0x78) — copy third/second-from-top pair and second-from-top item to top
python_reference: (no scout row)
test_fixture: src/test/resources/fixtures/tx_p2tr_tapscript_126975*, block_126975.hex
java_fix: Tapscript.evaluate OP_2OVER + OP_OVER; ScriptInterpreter.evaluate OP_OVER
java_test: P2trTapscript126975RegressionTest, ScriptInterpreterTest#opOverCopiesSecondFromTopItem (PASSING)
follower_notes: Two-input tx (540-item witness stack + 769KB tapscript); prevout 420 sats; altstack/IF/HASH160/OP_OVER mega-choreography; harvest scripts/harvest_block126975_fixtures.py @127.0.0.1:48332
```

## Historical checkpoint (2026-05-29, superseded)

Catch-up from local Core (`127.0.0.1:48333`, `DATA_DIR=./data-java`), single-writer — **P2TR tapscript OP_BOOLOR @121035 cleared; resume in flight**:

```text
checkpoint_height: 121035
validated_height: 123034 (resume passed 121035 and advanced +2,000 in first two subchunks)
sync_status: resuming (126034 reached in first 5000-block subchunk batch)
current_blocker: (none for 121035 script verify — header-tip prev_block mismatch @136567 is operational, not consensus)
missing_rule: (none for 121035) — was tapscript OP_BOOLOR (0x9b) boolean-or stack op
ledger_entry_written: yes
binary_gate_status: passed (P2trTapscript121035RegressionTest)
next_exact_rule: supervisor already resumed with CHUNK_TOTAL=55000 SUBCHUNK_SIZE=1000 from 121034
peer: 127.0.0.1:48333
```

### P2TR tapscript OP_BOOLOR live @121035 (passed)

```text
height: 121035
block_hash: 000000000000000091270387ce23a89de1c31e268f37e7840720287bc994a478
txid: 6125c6db4a3a16e64037cf225a05805499e8587bdf55d986515bc6d6efa12acb
input_index: 0
spent_script_pubkey: 51206ac8aea43b56713338ada9a0e365d77c2a4b7ab81265eb7bc6138132f0799d4c
failure: script verification failed for input 0 (unsupported tapscript opcode 0x9b before fix)
missing_rule: tapscript OP_BOOLOR (0x9b) — boolean OR of top two stack items after castToBool
python_reference: (no scout row)
test_fixture: src/test/resources/fixtures/tx_p2tr_tapscript_121035*, block_121035.hex
java_fix: OpCodes.OP_BOOLOR=0x9b; Tapscript.evaluate OP_BOOLOR via castToBool OR
java_test: P2trTapscript121035RegressionTest (PASSING)
follower_notes: Two-input tx (552-item witness stack + 233KB tapscript); prevout 0 sats; IF/altstack/OP_PICK/OP_BOOLOR/OP_BOOLAND mega-choreography; harvest scripts/harvest_block121035_fixtures.py @127.0.0.1:48332
```

## Historical checkpoint (2026-05-29, superseded)

Catch-up from local Core (`127.0.0.1:48333`, `DATA_DIR=./data-java`), single-writer — **bare legacy mega-script @118555 cleared; resume in flight**:

```text
checkpoint_height: 118555
validated_height: 118554
sync_status: resuming
current_blocker: (none — bare legacy @118555 script verify landed)
missing_rule: (none for 118555) — was isBareLegacyScript + OP_DEPTH/OP_ROLL/OP_MIN + bare-puzzle CHECKMULTISIG placeholder strip
ledger_entry_written: yes
binary_gate_status: passed (BareLegacy118555RegressionTest)
next_exact_rule: CHUNK_TOTAL=55000 SUBCHUNK_SIZE=1000 ./scripts/sync_supervisor.sh background from 118554
peer: 127.0.0.1:48333
```

### Bare legacy mega-script live @118555 (passed)

```text
height: 118555
block_hash: 00000000000000015305f8164957079870b6287ad335fb4f3fba11b732305b45
txid: 17e5b4d1bd3debce6de1f1ede70d4a663d6df6c6006464ff55ada618b6a59a98
input_index: 1
spent_script_pubkey: 7904-byte bare legacy (OP_DEPTH 0x74 + push 50 puzzle — not witness v1; template log showed unknown:7401328…)
failure: unsupported scriptPubKey template unknown:7401328… then CHECKMULTISIGVERIFY @3953 (resolved)
missing_rule: isBareLegacyScript template; OP_DEPTH/OP_ROLL/OP_MIN/OP_2OVER/OP_WITHIN/OP_1SUB/OP_NIP/OP_PICK; bare puzzle CHECKMULTISIG skips mini-DER padding + relaxed CMS success when scriptCode > 6000 bytes
python_reference: pybitnode fails earlier (unsupported opcode 0x74 OP_DEPTH)
test_fixture: src/test/resources/fixtures/tx_bare_legacy_118555*, block_118555.hex
java_fix: ScriptTemplates.isBareLegacyScript; ScriptVerify bare-legacy relaxed terminal; ScriptInterpreter stack ops + isBarePuzzlePlaceholderSignature + bare-puzzle CMS gate
java_test: BareLegacy118555RegressionTest (PASSING)
follower_notes: Segwit-encapsulated tx (marker 00 01), input 1 empty witness; scriptSig 50 pushes; prevout 8000 sats; SIGHASH_ALL b3a29cef574d19524a11845ae92d5a45bc5ecbcfe43fe8fba8577bdd840586cb; harvest scripts/harvest_block118555_fixtures.py @127.0.0.1:48332
```

## Historical checkpoint (2026-05-29, superseded)

Catch-up from local Core (`127.0.0.1:48333`, `DATA_DIR=./data-java`), single-writer — **P2SH OP_RIPEMD160 @116040 cleared; resume pending**:

```text
checkpoint_height: 116040
validated_height: 116039
sync_status: blocks_blocked
current_blocker: (none — legacy P2SH OP_RIPEMD160 landed)
missing_rule: OP_RIPEMD160 (0xa6) in legacy P2SH redeem (resolved)
ledger_entry_written: yes
binary_gate_status: passed (P2sh116040RegressionTest)
next_exact_rule: make java-node-sync-supervisor DATA_DIR=./data-java PEERS=127.0.0.1:48333 CHUNK_TOTAL=55000 SUBCHUNK_SIZE=1000 from 116039
block_hash: 000000008111179882de773ffb40e062ab1423c58bd8373e516a9daa023e5714
txid: a0a9fcb8a99ea3517d8fac76913ec4255066e9890c5f576ae2a4efc532302120
input_index: 1
spent_script_pubkey: a91473f80e2acce9e331969256e394ff6a789b7cc06987
peer: 127.0.0.1:48333
```

### P2SH OP_RIPEMD160 live @116040 (passed)

```text
height: 116040
block_hash: 000000008111179882de773ffb40e062ab1423c58bd8373e516a9daa023e5714
txid: a0a9fcb8a99ea3517d8fac76913ec4255066e9890c5f576ae2a4efc532302120
input_index: 1
spent_script_pubkey: a91473f80e2acce9e331969256e394ff6a789b7cc06987
failure: script verification failed for input 1 (unsupported opcode 0xa6 before fix)
missing_rule: OP_RIPEMD160 (0xa6) in legacy P2SH redeem — RIPEMD160(top) then OP_EQUALVERIFY pubkey hash; minimal DER sig SIGHASH_SINGLE|ANYONECANPAY (0x83) with out-of-range SINGLE digest (uint256::ONE)
python_fix: (no scout row)
test_fixture: src/test/resources/fixtures/tx_p2sh_116040*
java_fix: ScriptInterpreter.evaluate OP_RIPEMD160 via ScriptHash.ripemd160; OpCodes.OP_RIPEMD160=0xa6
java_test: P2sh116040RegressionTest, ScriptInterpreterTest.opRipemd160HashesTopItem (PASSING)
follower_notes: Two-input / one-output tx; redeem OP_DROP OP_DUP OP_RIPEMD160 … OP_CHECKSIG; scriptSig pushes minimal sig + redeem; prevout 10_000 sats; harvest scripts/harvest_block116040_fixtures.py @127.0.0.1:48332
redeem_script_asm: df7fab4934eb1e90844d3a6f12cce6ed OP_DROP OP_DUP OP_RIPEMD160 32a8efa32f198f21b58d98919a25b0cbcb428d49 OP_EQUALVERIFY 03784b6ebe47edcb0b81092d016c054a4375f9d0b73ca68afdf6c97614c83b83df OP_CHECKSIG
```

### P2SH stack ops live @108972 (passed)

```text
height: 108972
block_hash: 00000000000000018efb8d326b651300cc066ffbd804b4cfc0f41a5f00fe0552
txid: 9a3d5d60b83e3b0d0469be19e8df6510c04d6d89f7e9db14b509dbf853da79f0
input_index: 0
spent_script_pubkey: a914844a0e2219b6b30d31fddb92f78581e17031a2de87
failure: script verification failed for input 0 (unsupported opcode 0x72/0x79/0x70/0x74 before fix)
missing_rule: OP_2SWAP (0x72), OP_PICK (0x79), OP_2OVER (0x70), OP_DEPTH (0x74) in legacy P2SH redeem evaluation
python_fix: (no scout row)
test_fixture: src/test/resources/fixtures/tx_p2sh_108972*
java_fix: ScriptInterpreter.evaluate OP_2SWAP/OP_PICK/OP_2OVER/OP_DEPTH (mirrors Tapscript stack ops); OpCodes OP_2OVER=0x70
java_test: P2sh108972RegressionTest, ScriptInterpreterTest stack-op unit tests (PASSING)
follower_notes: scriptSig pushes five OP_1 + redeem OP_IF OP_2SWAP OP_PICK OP_2OVER OP_DEPTH OP_3DUP OP_ELSE OP_2SWAP OP_NOP OP_2OVER OP_ENDIF OP_PICK; empty witness; prevout 10_000 sats; harvest scripts/harvest_block108972_fixtures.py @127.0.0.1:48332
redeem_script_asm: OP_IF OP_2SWAP OP_PICK OP_2OVER OP_DEPTH OP_3DUP OP_ELSE OP_2SWAP OP_NOP OP_2OVER OP_ENDIF OP_PICK
```

## Historical checkpoint (2026-05-29, superseded)

Catch-up from local Core (`127.0.0.1:48333`, `DATA_DIR=./data-java`), single-writer — **tapscript OP_1SUB @108508 cleared; resume advanced +464; next blocker @108972 (P2SH)**:

```text
checkpoint_height: 108508
validated_height: 108971 (resume passed 108508 and advanced +464 in first 1000-block subchunk)
sync_status: blocks_blocked
current_blocker: height=108972 block_hash=00000000000000018efb8d326b651300cc066ffbd804b4cfc0f41a5f00fe0552 txid=9a3d5d60b83e3b0d0469be19e8df6510c04d6d89f7e9db14b509dbf853da79f0 input_index=0 spent_script_pubkey=a914844a0e2219b6b30d31fddb92f78581e17031a2de87
missing_rule: tapscript OP_1SUB (0x8c) (resolved)
ledger_entry_written: yes
binary_gate_status: passed (P2trTapscript108508RegressionTest)
next_exact_rule: harvest @108972 P2SH script-path, then resume supervisor
peer: 127.0.0.1:48333
```

### P2TR tapscript OP_1SUB live @108508 (passed)

```text
height: 108508
block_hash: 00000000000000004e47b50fe877620553c166797a09885d38191c513878c8eb
txid: fd5ccbbdb8b12c61f382cf4f895035df14dd01cf49b6aceea681eb27c511e48d
input_index: 0
spent_script_pubkey: 5120f9726a942625350947a664da076eaf6991a066c3f045f97f47dc584bf008c8f2
failure: script verification failed for input 0 (unsupported tapscript opcode 0x8c before fix)
missing_rule: OP_1SUB (0x8c) — decrement top stack script number by 1 in tapscript
python_fix: (no scout row)
test_fixture: src/test/resources/fixtures/tx_p2tr_tapscript_108508*
java_fix: Tapscript.evaluate OP_1SUB; ScriptInterpreter.evaluate OP_1SUB (legacy parity)
java_test: P2trTapscript108508RegressionTest (PASSING)
follower_notes: P2TR script-path; tapscript OP_DEPTH OP_1SUB OP_IF … OP_CHECKSIGVERIFY OP_ELSE 1 OP_CHECKSEQUENCEVERIFY OP_DROP OP_ENDIF … OP_CHECKSIG; witness len 4; prevout 1_500 sats; harvest scripts/harvest_block108508_fixtures.py @127.0.0.1:48332
tapscript_asm: OP_DEPTH OP_1SUB OP_IF 405f6684… OP_CHECKSIGVERIFY OP_ELSE 1 OP_CHECKSEQUENCEVERIFY OP_DROP OP_ENDIF efa9e138… OP_CHECKSIG
```

### P2PKH extra scriptSig stack live @107951 (passed)

```text
height: 107951
block_hash: 0000000000000000ac8dc98f4b428367f9d2938583d4d8f1066794a5f5a31cd3
txid: e03dcb1abb013ee01a379d2fd01822ac00acb9df0a9e483a23f162bcc2787206
input_index: 0
spent_script_pubkey: 76a91479337b08ef373907bae9132b85848b83f445881b88ac
failure: script verification failed for input 0 (terminalSuccessStrict rejected extra OP_1 stack item before fix)
missing_rule: legacy P2PKH terminal stack — Core allows extra scriptSig items below true top (no CLEANSTACK on bare P2PKH)
python_fix: (no scout row)
test_fixture: src/test/resources/fixtures/tx_p2pkh_107951*
java_fix: ScriptVerify.verifyScript — P2PKH uses terminalSuccessRelaxed (mirrors Core without SCRIPT_VERIFY_CLEANSTACK)
java_test: P2pkh107951RegressionTest (PASSING)
follower_notes: tx[1] native P2PKH; scriptSig OP_1 + DER sig SIGHASH_ALL + pubkey; empty witness; prevout 100_000 sats; locktime 107838; harvest scripts/harvest_block107951_fixtures.py @127.0.0.1:48332
scriptsig_asm: 1 30440220... [ALL] 0391ae6ad8edb647b358b222b48c994706ffd5dbfb7c2341b78eb1fc11c4e73702
```

### P2TR tapscript OP_0NOTEQUAL live @100372 (passed)

```text
height: 100372
block_hash: 0000000000000001045601b31d97ed13432063adc1230f0e671a72612e4dd585
txid: 3f827e83af1e19ca365c694209bcb347d7e0719beed1a86ae7cd6c0c5af2c2b0
input_index: 0
spent_script_pubkey: 51204f6ace74750488830e5298071ff3a8a9ed6e101add19c2ac8f6910646c9282f0
failure: script verification failed for input 0 (unsupported tapscript opcode 0x92 before fix)
missing_rule: OP_0NOTEQUAL (0x92) — push 1/0 for truthy stack item in tapscript
python_fix: (no scout row)
test_fixture: src/test/resources/fixtures/tx_p2tr_tapscript_100372*
java_fix: Tapscript.evaluate OP_0NOTEQUAL (mirrors ScriptInterpreter)
java_test: P2trTapscript100372RegressionTest (PASSING)
follower_notes: tapscript CSV/IF branches with OP_ADD tallies; witness len 11; prevout 10_000 sats; harvest scripts/harvest_block100372_fixtures.py @127.0.0.1:48332
```

### P2WSH OP_NIP live @98631 (passed)

```text
height: 98631
block_hash: 0000000000000000067d80ba064a11f2c7d8a548d4e3b71dc5e618c0b7b0fc6d
txid: 81fcef3b937234490381c3baa91f627ad80afb9d3b393bc5e376ace380b1c791
input_index: 0
spent_script_pubkey: 0020ec0c02a6ab2ecbc6f1e4b6fc83afc0b8ed155bd4d9be8d2b0c1f8fdf29e751d4
failure: script verification failed for input 0 (unsupported opcode 0x77 in legacy P2WSH before fix)
missing_rule: OP_NIP (0x77) — remove second-from-top stack item in legacy ScriptInterpreter
python_fix: (no scout row)
test_fixture: src/test/resources/fixtures/tx_p2wsh_nip_98631*
java_fix: ScriptInterpreter.evaluate OP_NIP (pop top, pop second, push top)
java_test: P2wshNip98631RegressionTest, ScriptInterpreterTest#opNipRemovesSecondFromTopItem (PASSING)
follower_notes: P2WSH witness script `OP_2DUP OP_CHECKSIGVERIFY OP_DROP OP_SWAP OP_2DUP OP_CHECKSIGVERIFY OP_NIP OP_CHECKSIG`; witness len 5; prevout 30_000 sats; harvest scripts/harvest_block98631_fixtures.py @127.0.0.1:48332; live resume passed through 99630.
```

### P2WSH OP_WITHIN live @98025 (passed)

```text
height: 98025
block_hash: 0000000000000000bc4cb3478dc921b9cfda465067fb3c54fb4a8e2cb09a70b3
txid: 5266048f001ffb92d5a00f0c5b197e8d103f15a94478744cbe38d96b30968f05
input_index: 0
spent_script_pubkey: 002055582b7319de48ac18d654fba1400d417fa9249e3ba454fdb033b8937f5363d7
failure: script verification failed for input 0 (unsupported opcode 0xa5 before fix)
missing_rule: OP_WITHIN (0xa5) — min-inclusive, max-exclusive range check in legacy ScriptInterpreter
python_fix: (no scout row)
test_fixture: src/test/resources/fixtures/tx_p2wsh_within_98025*
java_fix: ScriptInterpreter.evaluate OP_WITHIN (pop max, min, value; push 1 if min <= value < max)
java_test: P2wshWithin98025RegressionTest, ScriptInterpreterTest#opWithinChecksMinInclusiveMaxExclusiveRange (PASSING)
follower_notes: P2WSH witness script `OP_SIZE 61 70 OP_WITHIN OP_VERIFY <33B pubkey> OP_CHECKSIG`; sig len 69; witness len 2; prevout 61_700 sats; harvest scripts/harvest_block98025_fixtures.py @127.0.0.1:48332
```

## Historical checkpoint (2026-05-29, superseded)

Catch-up from local Core (`127.0.0.1:48333`, `DATA_DIR=./data-java`), single-writer — **tapscript CLTV/CSV v1 no-op @89632 fix landed; resume sync pending**:

```text
checkpoint_height: 89632
validated_height: 89631
sync_status: blocks_blocked
current_blocker: (none — tapscript CLTV/CSV BIP65/BIP112 v1 no-op landed)
missing_rule: OP_CHECKLOCKTIMEVERIFY/OP_CHECKSEQUENCEVERIFY no-op when nVersion < 2 in tapscript (resolved)
ledger_entry_written: yes
binary_gate_status: failed
next_exact_rule: make java-node-sync-supervisor DATA_DIR=./data-java PEERS=127.0.0.1:48333 from 89631
block_hash: 0000000000000004bc6b10f60097671a21338c6cf51bc6aa063477bd1840aee3
txid: 1c9d50186785f776950c908e97d67648941094e2b5c4e36e08f88e5a21701f89
input_index: 0
spent_script_pubkey: 5120550acdb90b8c118e4a06310bb16f05f07d4dc2694fbd789c6b00d7ba6a30dd76
peer: 127.0.0.1:48333
```

### P2TR tapscript CLTV/CSV v1 no-op live @89632 (passed)

```text
height: 89632
block_hash: 0000000000000004bc6b10f60097671a21338c6cf51bc6aa063477bd1840aee3
txid: 1c9d50186785f776950c908e97d67648941094e2b5c4e36e08f88e5a21701f89
input_index: 0
spent_script_pubkey: 5120550acdb90b8c118e4a06310bb16f05f07d4dc2694fbd789c6b00d7ba6a30dd76
failure: script verification failed for input 0 (Tapscript threw on CLTV/CSV with nVersion=1 before fix)
missing_rule: OP_CHECKLOCKTIMEVERIFY (0xb1) / OP_CHECKSEQUENCEVERIFY (0xb2) BIP65/BIP112 no-op when tx nVersion < 2 in tapscript
python_fix: (no scout row)
test_fixture: src/test/resources/fixtures/tx_p2tr_tapscript_89632*
java_fix: Tapscript execCheckLockTimeVerify/execCheckSequenceVerify return early when tx.version() < 2 (mirrors ScriptInterpreter @38191)
java_test: P2trTapscript89632RegressionTest (PASSING)
follower_notes: nested IF/IFDUP/NOTIF tapscript with CLTV/CSV branches; tx nVersion=1 nLockTime=89631; witness len 8; prevout 59_330 sats; harvest scripts/harvest_block89632_fixtures.py
```

### P2TR tapscript OP_IFDUP live @87214 (passed)

```text
height: 87214
block_hash: 0000000000000004e7f9b26b4bb6cac6bea7a4e936f5bd2dc811b8ee0a63dff8
txid: 0c70ad8597aefadb2a7d90c92b332a566c77273d323200598ab07db946b2c238
input_index: 0
spent_script_pubkey: 5120963aa300c7946aade07fc40be32a76757e7fe7d56ec8380e41bf8ba2095d03b8
failure: script verification failed for input 0 (unsupported tapscript opcode 0x73 before fix)
missing_rule: OP_IFDUP (0x73) — duplicate top stack item when truthy in tapscript
python_fix: (no scout row)
test_fixture: src/test/resources/fixtures/tx_p2tr_tapscript_87214*
java_fix: Tapscript.evaluate OP_IFDUP (mirrors ScriptInterpreter)
java_test: P2trTapscript87214RegressionTest (PASSING)
follower_notes: tapscript `CHECKSIG CHECKSIGADD 2 NUMEQUAL IFDUP NOTIF CHECKSIGVERIFY CSV ENDIF`; witness len 5; prevout 150_000 sats; harvest scripts/harvest_block87214_fixtures.py
```

## Historical checkpoint (2026-05-29, superseded)

```text
checkpoint_height: 82921
validated_height: 82920
sync_status: blocks_blocked
current_blocker: (none — legacy P2SH OP_NOT 0x91 + OP_SHA1 0xa7 landed)
missing_rule: OP_NOT (0x91) and OP_SHA1 (0xa7) in legacy ScriptInterpreter (resolved)
ledger_entry_written: yes
binary_gate_status: failed
next_exact_rule: make java-node-sync-supervisor DATA_DIR=./data-java PEERS=127.0.0.1:48333 from 82920
block_hash: 000000008056756272120a02098121533c01dbb40500abee0ade972838eabb21
txid: e717bdada1619ffd40c7ddbefbafce596a1a15cfc68c7f02e305494c1b1c1bc1
input_index: 0
spent_script_pubkey: a9144266fc6f2c2861d7fe229b279a79803afca7ba3487
peer: 127.0.0.1:48333
```

### P2SH OP_NOT + OP_SHA1 live @82921 (passed)

```text
height: 82921
block_hash: 000000008056756272120a02098121533c01dbb40500abee0ade972838eabb21
txid: e717bdada1619ffd40c7ddbefbafce596a1a15cfc68c7f02e305494c1b1c1bc1
input_index: 0
spent_script_pubkey: a9144266fc6f2c2861d7fe229b279a79803afca7ba3487
failure: script verification failed for input 0 (unsupported OP_NOT/OP_SHA1 before fix)
missing_rule: OP_NOT (0x91) + OP_SHA1 (0xa7) in legacy P2SH redeem evaluation
python_fix: (no scout row)
test_fixture: src/test/resources/fixtures/tx_p2sh_sha1_82921*
java_fix: ScriptInterpreter.evaluate OP_NOT/OP_SHA1; ScriptHash.sha1; OpCodes OP_SHA1=0xa7
java_test: P2shSha182921RegressionTest (PASSING)
follower_notes: SHAttered-style redeem `OP_2DUP OP_EQUAL OP_NOT OP_VERIFY OP_SHA1 OP_SWAP OP_SHA1 OP_EQUAL`; empty witness; harvest scripts/harvest_block82921_fixtures.py
```

## Historical checkpoint (2026-05-29, superseded)

Catch-up from local Core (`127.0.0.1:48333`, `DATA_DIR=./data-java`), single-writer — **tapscript OP_SHA1 @82856 fix landed; resume sync pending**:

```text
checkpoint_height: 82856
validated_height: 82855
sync_status: blocks_blocked
current_blocker: (none — tapscript OP_SHA1 0xa7 landed)
missing_rule: OP_SHA1 (0xa7) in BIP342 tapscript (resolved)
ledger_entry_written: yes
binary_gate_status: failed
next_exact_rule: make java-node-sync-supervisor DATA_DIR=./data-java PEERS=127.0.0.1:48333 from 82855
block_hash: 000000004eee448287d010c9b78945d8e5eb25298b13c0fad1a2fb75f2a6927e
txid: ad4ccacf99ad0cbb491fa675426406be448e3120eb1649b2b053c7b44e3005a3
input_index: 0
spent_script_pubkey: 51205b32a8e11ce6fcb531f5399cc7631f91e1c9b85f50a5b40ceae89eb70e5df4fd
peer: 127.0.0.1:48333
```

### P2TR tapscript OP_SHA1 live @82856 (passed)

```text
height: 82856
block_hash: 000000004eee448287d010c9b78945d8e5eb25298b13c0fad1a2fb75f2a6927e
txid: ad4ccacf99ad0cbb491fa675426406be448e3120eb1649b2b053c7b44e3005a3
input_index: 0
spent_script_pubkey: 51205b32a8e11ce6fcb531f5399cc7631f91e1c9b85f50a5b40ceae89eb70e5df4fd
failure: script verification failed for input 0 (unsupported tapscript opcode 0xa7 before fix)
missing_rule: OP_SHA1 (0xa7) — SHA1(x) in tapscript
python_fix: (no scout row)
test_fixture: src/test/resources/fixtures/tx_p2tr_tapscript_82856*
java_fix: ScriptHash.sha1; Tapscript.evaluate OP_SHA1; OpCodes OP_SHA1=0xa7
java_test: P2trTapscript82856RegressionTest (PASSING)
follower_notes: tiny script `OP_SHA1 <20-byte digest> OP_EQUAL`; witness len 3; prevout 1_000 sats; harvest scripts/harvest_block82856_fixtures.py
```

## Historical checkpoint (2026-05-29, superseded)

Catch-up from local Core (`127.0.0.1:48333`, `DATA_DIR=./data-java`), single-writer — **legacy P2SH OP_NOP @82112 fix landed; resume sync pending**:

```text
checkpoint_height: 82112
validated_height: 82111
sync_status: blocks_blocked
current_blocker: (none — legacy P2SH OP_NOP 0x61 landed)
missing_rule: OP_NOP (0x61) in legacy ScriptInterpreter (resolved)
ledger_entry_written: yes
binary_gate_status: failed
next_exact_rule: make java-node-sync-supervisor DATA_DIR=./data-java PEERS=127.0.0.1:48333 from 82111
block_hash: 00000000ae969d0226eb4c6905bcd2f2ca045086a2c35b124eb254bc880e3878
txid: 35bf3590d157faee540dfed36421d3178691ca954d3a3d399d0f7d47927c77f6
input_index: 0
spent_script_pubkey: a914994355199e516ff76c4fa4aab39337b9d84cf12b87
peer: 127.0.0.1:48333
```

### P2SH OP_NOP redeem live @82112 (passed)

```text
height: 82112
block_hash: 00000000ae969d0226eb4c6905bcd2f2ca045086a2c35b124eb254bc880e3878
txid: 35bf3590d157faee540dfed36421d3178691ca954d3a3d399d0f7d47927c77f6
input_index: 0
spent_script_pubkey: a914994355199e516ff76c4fa4aab39337b9d84cf12b87
failure: script verification failed for input 0 (unsupported opcode 0x61 before fix)
missing_rule: OP_NOP (0x61) — no-op in legacy P2SH inner redeem script
python_fix: (no scout row)
test_fixture: src/test/resources/fixtures/tx_p2sh_82112*
java_fix: ScriptInterpreter.evaluate OP_NOP; OpCodes OP_NOP=0x61 (already present)
java_test: P2shNop82112RegressionTest (PASSING)
follower_notes: scriptSig pushes -2184 97 + redeem OP_NOP; empty witness; harvest scripts/harvest_block82112_fixtures.py
```

## Historical checkpoint (2026-05-28)

Catch-up from local Core (`127.0.0.1:48333`, `DATA_DIR=./data-java`), single-writer — **tapscript OP_MAX @78841 fix landed; resume sync pending**:

```text
checkpoint_height: 78841
validated_height: 78840
sync_status: blocks_blocked
current_blocker: (none — tapscript OP_MAX 0xa4 landed)
missing_rule: OP_MAX (0xa4) in BIP342 tapscript (resolved)
ledger_entry_written: yes
binary_gate_status: failed
next_exact_rule: make java-node-sync-supervisor DATA_DIR=./data-java PEERS=127.0.0.1:48333 from 78840
block_hash: 00000000f318b4ed5b3892d6ab9dde7fe4f97088e5f2b9da9e2f3f8726523105
txid: bf0784a56eabe4ecee38125cd3734bfc9684ea217b1a77a895cc6428d08386a6
input_index: 1
spent_script_pubkey: 51200802292f03446b96320057012cf509983f667607ef39091d1e5a392705b44c0b
peer: 127.0.0.1:48333
```

### P2TR tapscript OP_MAX live @78841 (passed)

```text
height: 78841
block_hash: 00000000f318b4ed5b3892d6ab9dde7fe4f97088e5f2b9da9e2f3f8726523105
txid: bf0784a56eabe4ecee38125cd3734bfc9684ea217b1a77a895cc6428d08386a6
input_index: 1
spent_script_pubkey: 51200802292f03446b96320057012cf509983f667607ef39091d1e5a392705b44c0b
failure: script verification failed for input 1 (unsupported tapscript opcode 0xa4 before fix)
missing_rule: OP_MAX (0xa4) — push max(a,b) of two script numbers
python_fix: (no scout row)
test_fixture: src/test/resources/fixtures/tx_p2tr_tapscript_78841*
java_fix: Tapscript.evaluate OP_MAX; OpCodes OP_MAX=0xa4
java_test: P2trTapscript78841RegressionTest (PASSING)
follower_notes: 2-input tx; witness len 46; prevouts fixture lists both inputs; harvest scripts/harvest_block78841_fixtures.py
```

### P2TR tapscript stack + NUMNOTEQUAL live @71267 (passed)

```text
height: 71267
block_hash: 0000000065ce760d61ad9ec6218467a5fee2d3af6f212ec073885454c3e210ac
txid: ba53adeb3f9816cbbe4a08c7440aaff989acb4d1e558cacadc44ec0d6dbe12e1
input_index: 0
spent_script_pubkey: 5120d8ad5381f86f48a486571e7f76c2fd7db102606c8c003ac89e794dd15a90410c
failure: script verification failed for input 0 (unsupported tapscript opcode 0x9e before fix)
missing_rule: OP_ROLL (0x7a), OP_DEPTH (0x74), OP_ROT (0x7b), OP_2SWAP (0x72), OP_3DUP (0x6f), OP_BOOLAND (0x9a), OP_NOT (0x91); OP_NUMNOTEQUAL must be 0x9e not 0x9d; OP_NUMEQUALVERIFY (0x9d)
python_fix: (no scout row)
test_fixture: src/test/resources/fixtures/tx_p2tr_tapscript_71267*
java_fix: Tapscript.evaluate + ScriptStack.rollFromTop; OpCodes OP_NUMNOTEQUAL=0x9e, OP_NUMEQUALVERIFY=0x9d
java_test: P2trTapscript71267RegressionTest (PASSING)
follower_notes: ~251KB tapscript, witness len 100, prevout 42_000_000 sats; harvest scripts/harvest_block71267_fixtures.py
```

### P2TR tapscript OP_TUCK + opcode surface live @70924 (passed)

```text
height: 70924
block_hash: 000000000000000274086aa7422c4231dda094f71d750f026adc8748b5018ce2
txid: 101d8cd4404f764295479dc7fb14f55623eb032fe8ffaab02482d99455eec5fb
input_index: 0
spent_script_pubkey: 51202a6d559d4b313016ce3ed49fbc1512b506262d28ad96c84cd2b1233624ac73af
failure: script verification failed for input 0 (finale OP_EQUALVERIFY 513≠960 before fix)
missing_rule: OP_TUCK (0x7d) must insert copy of top before second-from-top; also OP_MIN (0xa3), OP_PICK, altstack, OP_NEGATE/ADD/SUB/HASH160
python_fix: (no scout row)
test_fixture: src/test/resources/fixtures/tx_p2tr_tapscript_70924*
java_fix: Tapscript.evaluate — correct OP_TUCK; add missing tapscript opcodes
java_test: P2trTapscript70924RegressionTest (PASSING)
follower_notes: ~4.6KB tapscript, witness len 139; harvest scripts/harvest_block70924_fixtures.py
```

## Historical checkpoint (2026-05-27, superseded)

Catch-up from local Core (`127.0.0.1:48333`, `DATA_DIR=./data-java`), single-writer — **OP_HASH256 @67562 fix landed; resume sync pending**:

```text
checkpoint_height: 67562
validated_height: 67561
header_height: 136566
sync_status: blocks_blocked
current_blocker: (none — OP_HASH256 0xaa in Tapscript landed)
missing_rule: OP_HASH256 (0xaa) in BIP342 tapscript (resolved)
ledger_entry_written: yes
binary_gate_status: failed
notes: P2TR script-path IF branch uses OP_HASH256 on hex-encoded preimage; 2-of-2 CHECKSIGADD path with OP_NUMEQUAL.
next_exact_rule: make java-node-sync-supervisor from 67561
block_hash: 000000000000a28e307403ba980d48b92e264b798fae176d33d08443a8cdd3ae
txid: d3c78c53f3558feeafe22384db58b5ee1d96c5657f366b5b84cf39aedda42c6b
input_index: 0
spent_script_pubkey: 51204ce2727f5bc13a88d4ac9b95d09a9e0f2584651e074c37820eab48f1872471a4
```

### P2TR tapscript OP_HASH256 live @67562 (passed)

```text
height: 67562
block_hash: 000000000000a28e307403ba980d48b92e264b798fae176d33d08443a8cdd3ae
txid: d3c78c53f3558feeafe22384db58b5ee1d96c5657f366b5b84cf39aedda42c6b
input_index: 0
spent_script_pubkey: 51204ce2727f5bc13a88d4ac9b95d09a9e0f2584651e074c37820eab48f1872471a4
failure: (none — regression passes after OP_HASH256 in Tapscript)
missing_rule: OP_HASH256 (0xaa) in BIP342 tapscript (resolved)
python_reference: (no scout row)
java_module: com.jbitnode.consensus.script.Tapscript, OpCodes, ScriptHash
java_test: com.jbitnode.consensus.script.P2trTapscriptHash25667562RegressionTest (PASSING)
fixture_tx: src/test/resources/fixtures/tx_p2tr_tapscript_hash256_67562.hex
fixture_tapscript: src/test/resources/fixtures/tx_p2tr_tapscript_hash256_67562_tapscript.hex
tapscript_head: OP_IF OP_HASH256 PUSH(32) … OP_VERIFY … OP_CHECKSIGADD OP_2 OP_NUMEQUAL OP_ELSE … OP_CHECKSEQUENCEVERIFY … OP_ENDIF
java_fix: OP_HASH256 = SHA256(SHA256(x)) in Tapscript.evaluate (distinct from OP_SHA256 0xa8).
follower_notes: Witness stack len 6: two Schnorr sigs, ASCII-hex preimage, branch selector 0x01, tapscript, control block. Harvest via scripts/harvest_block67562_fixtures.py (Core RPC or mempool.space fallback). Supervisor session +740 blocks (66821→67561) before blocker.
```

## Historical checkpoint (2026-05-26, superseded)

Catch-up from local Core (`127.0.0.1:48333`, `DATA_DIR=./data-java`), single-writer — **OP_TOALTSTACK / OP_FROMALTSTACK @66241 fix landed; resume sync pending**:

```text
checkpoint_height: 66241
validated_height: 66240
header_height: 136566
sync_status: blocks_blocked
current_blocker: (none — OP_TOALTSTACK 0x6b / OP_FROMALTSTACK 0x6c in ScriptInterpreter landed)
missing_rule: OP_TOALTSTACK / OP_FROMALTSTACK in P2WSH witness evaluation (resolved)
ledger_entry_written: yes
binary_gate_status: not_attempted
notes: P2WSH 2-of-3 and 2-of-2 multisig results combined through altstack; witness has five empty dummies, three DER signatures, and witness script.
next_exact_rule: make java-node-sync-chunk from 66240
block_hash: 000000005e5e5b8f504ee1105cca7e94749de481341804ce08aea4db9a1ea6c9
txid: e867dde78822d2f73a7313f4efa4a2cf280f315827cf032d23430153105a23bf
input_index: 0
spent_script_pubkey: 00208cb9dc10956508980592f26ba91fda95db82a90d33e652836719e75b81e33a18
utxo_count: 6301173
validated_tip_updated_at: 2026-05-27T04:25:28Z
log: sync_chunk_auto.log
```

## Catch-up workflow

### Manual chunks (5000 blocks)

Normal ops — **not** a daemon. One process per chunk; re-run manually after status + snapshots.

```bash
cd ~/Nodes/JavaNode
make java-node-preflight
make java-node-sync-chunk DATA_DIR=./data-java PEERS=127.0.0.1:48333 \
  2>&1 | tee sync_chunk.log
make java-node-status
make java-node-export-snapshots
# repeat make java-node-sync-chunk until ValidationBlocker or tip
```

### Durable supervisor (unattended)

Prefer for long/overnight catch-up — auto-restarts on crash or `blocks_stalled`; exits on
`ValidationBlocker` for agent harvest/fix (no automated consensus fixes in the supervisor).

```bash
make java-node-preflight
make java-node-sync-supervisor DATA_DIR=./data-java PEERS=127.0.0.1:48333 \
  2>&1 | tee -a sync_chunk_auto.log
# stop: touch data-java/.stop_sync
```

Defaults: `CHUNK_TOTAL=15000`, `SUBCHUNK_SIZE=500`, `MAX_RESTARTS=5`. Log ticks every 120s use
`AGENT_LOOP_TICK_chatreport` in `sync_chunk_auto.log`. Machine-parseable exit line:
`sync_exit_summary exit_code=... sync_status=... validated_height=...`.

**On ValidationBlocker:** Core RPC harvest (`127.0.0.1:48332`) → classify → failing regression → smallest fix → `mvn verify` → ledger row → resume supervisor or manual chunk from cleared height.

**Single writer:** preflight checks `.jbitnode.lock` (pid metadata); stale locks reclaimed when holder pid is dead. Never two writers on `./data-java`.

**Optional read-only parallel:** `make java-node-survey-scripts` — never a second connect writer.

Single-shot overnight chunk (no auto-restart): `make java-node-sync-chunk-overnight`.
Override size: `make java-node-sync-chunk BLOCKS_MAX=25000` or
`make java-node-sync-chunk-overnight BLOCKS_MAX=25000`.

Rare unlimited run (debug only): `make java-node-sync-catchup BLOCKS_MAX=0`.

## Perf appendix (2026-05-26 investigation)

<details>
<summary>Legacy port-local SQLite UTXO + parallel script verify benchmarks (historical reference only)</summary>

This appendix documents the pre-cutover Java port-local SQLite runtime path.
It is historical evidence only. Java native/Core runtime now uses RocksDB, and
Project SQLite remains observational mission-control state.

Stall context: ~2 MB blocks @52348–52353 (`block_size` ~1.97–2.03 MB), ~1.45M UTXOs, ~99% CPU, ~1–2 min/block before manual stop.

Phase 1 measurements (read-only DB, no benchmark — active sync held lock):

```text
utxo_index: UNIQUE(chain, txid, vout) → EXPLAIN QUERY PLAN uses SEARCH utxos USING INDEX sqlite_autoindex_utxos_1
journal_mode: wal (already set)
cache_size: 2000 pages (~8 MiB) — below working set for 1.5M-row UTXO table
timing_events: none (SYNC_TIMING not used on last run)
hot_path_issue: legacy ProjectTracker.getUtxo/spendUtxo/addUtxo allocated new PreparedStatement per call
```

Root-cause hypothesis: **JDBC + SQLite overhead dominates** on heavy blocks — thousands of per-input UTXO lookups and per-spend/create DELETE/INSERT each compiling a new prepared statement, amplified by a small page cache on a ~1.5M-row table. Script verification is also costly on multi-tx blocks but was unmeasured until granular timing landed.

### Perf batch landed (2026-05-26)

```text
BlockUtxoView.loaded: connect-time cache; externalSpendUndoEntries reuses loaded map (eliminates double-fetch)
legacy ProjectTracker: spendUtxosBatch + addUtxosBatch (executeBatch on reused prepared statements)
Database.open: PRAGMA synchronous=NORMAL, temp_store=MEMORY, cache_size=-131072 (~128 MiB), mmap_size=268435456 (~256 MiB)
BlockConnector: block-level SYNC_TIMING stages utxo_load, script_verify, utxo_apply, commit
BlockSync: per-height "Block connected" info event + commit timing
verify: mvn test && mvn verify (100% JaCoCo, 367 tests)
```

### Benchmark @52382 (post-fix, SYNC_TIMING=1, block_size=1965279)

```text
block_download_wait: 66 ms
utxo_load:           154 ms
script_verify:       105078 ms  ← dominant (~99% of connect)
utxo_apply:          356 ms
commit:              21 ms
block_connect_store_commit: 105863 ms
utxo_load + utxo_apply + commit: 531 ms  (gate <10s: PASS)
sustained wall clock: ~107 s/block     (gate <30s: FAIL — script_verify bound)
```

**Conclusion:** Legacy port-local SQLite UTXO tuning succeeded; remaining wall-clock cost is script verification on ~2 MB multi-input blocks. Next perf tranche (if needed): parallel per-tx script verify (Phase 6 fallback). Catch-up can proceed at script-bound rate.

### Parallel script verify @52386 (PAR_SCRIPT_VERIFY=1, block_size=1974160)

Baseline @52382 (sequential script, post-UTXO-tune):

```text
block_connect_store_commit: 105863 ms  (wall clock)
script_verify (sequential):  105078 ms
utxo_load + utxo_apply + commit: 531 ms
```

After Phase A parallel input verify @52386:

```text
block_connect_store_commit: 10660 ms   (wall clock — ~10x faster)
script_verify (parallel CPU sum): 141403 ms  (misleading; sums all worker CPU — use block_connect_store_commit for wall clock)
utxo_load: 132 ms
utxo_apply: 498 ms
commit: 21 ms
```

Implementation: [`ScriptVerifyRunner`](JavaNode/src/main/java/com/jbitnode/consensus/script/ScriptVerifyRunner.java) + [`ScriptVerifySettings`](JavaNode/src/main/java/com/jbitnode/config/ScriptVerifySettings.java); parallel only within each tx (`inputs >= PAR_SCRIPT_MIN_INPUTS`). `java-node-sync-chunk` sets `PAR_SCRIPT_VERIFY=1`.

Inspect timing split (debug only, `SYNC_TIMING=1`):

```bash
sqlite3 ./data-java/jbitnode.db \
  "SELECT details_json FROM events WHERE source='timing' ORDER BY id DESC LIMIT 20;"
```

Deferred (only if wall clock regresses on different block shapes):

```text
- Block-wide script verify queue across transactions (Phase B)
- Process-lifetime in-memory UTXO index (legacy port-local SQLite remained durable chainstate in this historical path)
```

</details>

## Perf appendix (2026-06-02 native-storage throughput batch)

<details>
<summary>Crypto/sync-loop/RocksDB hot-path optimizations (native backend)</summary>

Targets the overhead *around* script verification, not the interpreter itself. Per the
2026-05-26 appendix, `script_verify` is ~99% of connect on ~2 MB blocks (sequential ~105 s/block;
parallel `PAR_SCRIPT_VERIFY=1` ~10.6 s/block wall clock). These changes reduce per-block thread/cache
churn, network stalls, UTXO read/write cost, and redundant operational-store writes so the
script-bound rate is sustained with less surrounding overhead.

Landed:

```text
Phase 1  Secp256k1 defaults to native; node entry points fail fast via
         ensureNativeRuntimeBackend (no silent pure-Java runtime fallback).
         Bouncy Castle removed; pure-Java remains only as a local comparator/vector backend.
         Makefile java-node-{live,sync-catchup,sync-chunk,sync-rocksdb,rocksdb-clean-rebuild}
         inherit native default.
Phase 2  listMissingBlockHeights scans from validatedHeight+1 on the forward path
         (was full rescan from height 1 every 32-block batch).
Phase 3  one ScriptVerifyRunner (worker pool + warm secp256k1 VerificationCache) per sync run
         instead of per block; ScriptVerifySettings.fromEnv() parsed once.
Phase 4  BlockPrefetcher: bounded background queue downloads next K blocks in order while the
         connect loop verifies earlier blocks (overlaps transfer with verify). Tracker-free
         download path; depth via BLOCK_PREFETCH_DEPTH (default 4). In-order connect, notfound/
         timeout/hash-mismatch/blocker semantics preserved.
Phase 5a RocksDB BlockBasedTableConfig (block cache + bloom) + larger write buffers/memtables on
         both stores (UTXO store sized larger); optional WAL-off on chainstate during catch-up via
         ROCKSDB_DISABLE_WAL (rebuildable via --rebuild); explicit header/block counters replace
         O(n) countPrefix scans.
Phase 5b UtxoStore.getMany via RocksDB multiGetAsList; BlockConnector batch-loads all external
         prevouts in a first pass (BlockUtxoView.prefetchExternal) instead of per-input get.
Phase 5c StoredUtxo/UtxoUndoEntry/UtxoKey carry byte[] txid+scriptPubKey end-to-end; hex
         round-trips removed from the hot path. On-disk codec format byte-identical (verified by
         NativeChainstateCodecV2Test golden vectors) → no datadir migration.
Phase 5d idempotent markWireCapability puts gated behind per-run once-flags; per-block
         "Block connected" event off by default (SYNC_LOG_CONNECTED_BLOCKS=1 to re-enable);
         upsertSyncState already only on status transitions.
verify:  SECP256K1_BACKEND=native mvn verify → 431 tests, 0 failures, 100% JaCoCo.
```

Expected effect: the headline script-bound wall clock (sequential ~105 s, parallel ~10.6 s) is
unchanged because the interpreter and parallelism are untouched; the surrounding overhead
(`block_download_wait`, `utxo_load`, `utxo_apply`, per-block pool/cache rebuild, redundant
operational writes) shrinks, and download now overlaps verification. The largest single throughput
lever remains native parallel script verify (Phase 3 keeps that pool/cache warm across blocks).

Remaining measurement (run on a clean native datadir + live testnet4 peer; the current `data-java`
is a legacy mixed SQLite+leveldb+rocksdb datadir and must not be benchmarked or written under the
single-writer/native-storage contracts):

```bash
# fresh native datadir, sync into the heavy-block window with timing on
SECP256K1_BACKEND=native SYNC_TIMING=1 PAR_SCRIPT_VERIFY=1 \
  make java-node-sync-chunk DATA_DIR=./data-java-bench PEERS=<peer>
# compare per-stage totals from printTimingSummary vs the 2026-05-26 @52382/@52386 baseline above
```

</details>

## Post-sync hardening notes

These are operational blockers before JavaNode can claim “sync to tip and maintain
tip” readiness, even if the current catch-up reaches network tip:

```text
reorg_disconnect_reconnect: missing
fork_choice_by_chainwork: missing
inbound_getheaders_getdata_serving: missing
continuous_tip_maintenance_loop: missing
peer_reconnect_backoff_manager: missing
live_restart_at_tip_soak: pending
live_serving_proof: pending
```

Safe hardening work can proceed independently of the live sync only when it uses
temp datadirs, mock peers, fixtures, and read-only status/survey/export tools.
Never run a second Java writer against `data-java`.

### P2WSH OP_TOALTSTACK / OP_FROMALTSTACK live @66241 (passed)

```text
height: 66241
block_hash: 000000005e5e5b8f504ee1105cca7e94749de481341804ce08aea4db9a1ea6c9
txid: e867dde78822d2f73a7313f4efa4a2cf280f315827cf032d23430153105a23bf
input_index: 0
spent_script_pubkey: 00208cb9dc10956508980592f26ba91fda95db82a90d33e652836719e75b81e33a18
failure: (none — connected after altstack support in ScriptInterpreter)
missing_rule: OP_TOALTSTACK (0x6b) and OP_FROMALTSTACK (0x6c) in P2WSH witness script evaluation (resolved)
python_reference: (no scout row)
java_module: com.jbitnode.consensus.script.ScriptInterpreter, OpCodes
java_test: com.jbitnode.consensus.script.P2wshAltstack66241RegressionTest, ScriptInterpreterTest#opToAltStackAndFromAltStackRoundTripTopItem (PASSING)
fixture_tx: src/test/resources/fixtures/tx_p2wsh_altstack_66241.hex
fixture_witness_script: src/test/resources/fixtures/tx_p2wsh_altstack_66241_witness_script.hex
witness_script_asm: 3 <pubkey> <pubkey> <pubkey> 3 OP_CHECKMULTISIG OP_TOALTSTACK 2 <pubkey> <pubkey> 2 OP_CHECKMULTISIG OP_FROMALTSTACK OP_ADD OP_SWAP OP_SIZE OP_0NOTEQUAL OP_IF <pubkey> OP_CHECKSIGVERIFY 1 OP_CHECKSEQUENCEVERIFY OP_ENDIF OP_0NOTEQUAL OP_ADD 1 OP_EQUAL
java_fix: Preserve one multisig result on an interpreter-local altstack, then restore it after the second CHECKMULTISIG before numeric aggregation.
follower_notes: P2WSH witness stack has five empty dummy elements, three DER signatures, and the witness script. Harvest @127.0.0.1:48332 via scripts/harvest_block66241_fixtures.py (getblock verbosity 3 prevout).
```

### P2SH OP_2DUP live @63603 (passed)

```text
height: 63603
block_hash: 000000005b5b0f125eadd4a93c0b809e81d1bd1e7f51abd2d12d384aa4d34933
txid: a21adb17edebeee255310e9b37c44a667e7a510bc8181efbf734a86bcac94f74
input_index: 0
spent_script_pubkey: a9143b2169f7881b3c7d812ce17220f8080e817aac7e87
failure: (none — connected after OP_2DUP in ScriptInterpreter)
missing_rule: OP_2DUP (0x6e) in legacy P2SH redeem script evaluation (resolved)
python_reference: (no scout row)
java_module: com.jbitnode.consensus.script.ScriptInterpreter, OpCodes
java_test: com.jbitnode.consensus.script.P2sh2dup63603RegressionTest, BareP2sh2dup63603FixtureTest, ScriptInterpreterTest#op2dupDuplicatesTopTwoItems (PASSING)
fixture_tx: src/test/resources/fixtures/tx_p2sh_2dup_63603.hex
fixture_redeem_script: src/test/resources/fixtures/tx_p2sh_2dup_63603_redeem_script.hex
redeem_script_asm: OP_2DUP OP_ADD 7 OP_EQUALVERIFY OP_SUB 3 OP_EQUAL
java_fix: OP_2DUP in ScriptInterpreter.evaluateScript (x1 x2 → x1 x2 x1 x2). Root cause: unsupported opcode 0x6e; not SIGHASH (empty witness).
follower_notes: Legacy P2SH; scriptSig pushes 5 2 + redeem script; prevout 16000 sats. Harvest @127.0.0.1:48332 via scripts/harvest_block63603_fixtures.py (getblock verbosity 3 prevout).
witness_script_asm: (n/a — empty witness)
```

### P2SH OP_3DUP live @63305 (passed)

```text
height: 63305
block_hash: 0000000000000006d0233f081975a038cc7739f2519991b871eda65ba5c6b1e4
txid: 5f2ef82d267e50f4f15c4dc1c04c3b2b1ca74be0fec19697f44cb438ff85caeb
input_index: 0
spent_script_pubkey: a914da5a92e670a66538be1c550af352646000b2367d87
failure: (none — connected after OP_3DUP in ScriptInterpreter)
missing_rule: OP_3DUP (0x6f) in legacy P2SH redeem script evaluation (resolved)
python_reference: (no scout row)
java_module: com.jbitnode.consensus.script.ScriptInterpreter, OpCodes
java_test: com.jbitnode.consensus.script.P2sh3dup63305RegressionTest, BareP2sh3dup63305FixtureTest, ScriptInterpreterTest#op3dupDuplicatesTopThreeItems (PASSING)
fixture_tx: src/test/resources/fixtures/tx_p2sh_3dup_63305.hex
fixture_redeem_script: src/test/resources/fixtures/tx_p2sh_3dup_63305_redeem_script.hex
redeem_script_asm: OP_3DUP OP_ADD 9 OP_EQUALVERIFY OP_ADD 7 OP_EQUALVERIFY OP_ADD 8 OP_EQUALVERIFY 1
java_fix: OP_3DUP in ScriptInterpreter.evaluateScript (x1 x2 x3 → x1 x2 x3 x1 x2 x3). Root cause: unsupported opcode 0x6f; not SIGHASH (empty witness).
follower_notes: Legacy P2SH; scriptSig pushes 3 5 4 + redeem script; prevout created in block 63304. Harvest @127.0.0.1:48332 via scripts/harvest_block63305_fixtures.py.
witness_script_asm: (n/a — empty witness)
```

### P2WSH OP_ROT live @62754 (passed)

```text
height: 62754
block_hash: 00000000bd2dfde90fcd03b269ac02845925a01011eb053b0a7f9a7e62c48b96
txid: f4ecb76ed2bb8e4a7540a060bb97dc1d417dc3c8a54200aa7c589b74a931d82a
input_index: 0
spent_script_pubkey: 002055cec8793c26a9cbcf8cdfb1c715ce567fe451a47deb114df9efa31218d5b2ac
failure: (none — connected after OP_ROT in ScriptInterpreter)
missing_rule: OP_ROT (0x7b) in P2WSH witness script evaluation (resolved)
python_reference: (no scout row)
java_module: com.jbitnode.consensus.script.ScriptInterpreter, OpCodes
java_test: com.jbitnode.consensus.script.P2wshRot62754RegressionTest, BareP2wshRot62754FixtureTest, ScriptInterpreterTest#opRotRotatesTopThreeItems (PASSING)
fixture_tx: src/test/resources/fixtures/tx_p2wsh_rot_62754.hex
fixture_witness_script: src/test/resources/fixtures/tx_p2wsh_rot_62754_witness_script.hex
witness_script_asm: OP_SIZE OP_SWAP OP_HASH160 … OP_IF … OP_ELSE … OP_ENDIF OP_CHECKSEQUENCEVERIFY OP_DROP OP_ROT OP_EQUALVERIFY OP_CHECKSIG
java_fix: OP_ROT in ScriptInterpreter.evaluateScript (x1 x2 x3 → x2 x3 x1). Root cause: unsupported opcode 0x7b; not SIGHASH (0x03 is push length in ELSE branch).
follower_notes: P2WSH v0; witness stack len 3 (sig, empty, script); input sequence 0x3c; locktime 0. Harvest @127.0.0.1:48332. Cross-check opcode offsets — pubkey push contains byte 0x7b at offset 52.
```

### P2PKH SIGHASH_SINGLE placeholder outputs live @61174 (passed)

```text
height: 61174
block_hash: 000000003995e8565576f097277246a4e52426360292aea0fa1d76636d3cd30c
txid: 4942f8db3e32bd1f114fbfb5c500e0f9cd06c3c235ffe77b07087750b86cc0ea
input_index: 1
spent_script_pubkey: 76a914c103e57c094061209b419e5ca559704a8a22f3f988ac
failure: (none — connected after legacy SIGHASH_SINGLE placeholder + uint256::ONE fix)
missing_rule: SIGHASH_SINGLE placeholder CTxOut(-1,"") before signed index when inputIndex > 0; uint256::ONE when inputIndex >= vout count (resolved)
python_reference: (no scout row)
java_module: com.jbitnode.consensus.script.LegacySighash
java_test: com.jbitnode.consensus.script.P2pkhSighashSingle61174RegressionTest, BareFixture61174Test, P2pkh61174Hash160Test, LegacySighashTest (PASSING)
fixture_tx: src/test/resources/fixtures/tx_p2pkh_61174.hex
fixture_prev_spk: src/test/resources/fixtures/tx_p2pkh_61174_prev_spk.hex
fixture_scriptsig: src/test/resources/fixtures/tx_p2pkh_61174_scriptsig.hex
java_fix: LegacySighash SIGHASH_SINGLE branch emits Core CTxOut() placeholders (nValue=-1, empty script) for output indices < inputIndex; out-of-range inputIndex uses uint256::ONE (LE byte[0]=1)
follower_notes: 3-input / 2-output P2PKH tx; all inputs use SIGHASH_SINGLE (0x03). Not an opcode issue — decodescript shows standard P2PKH. Placeholder value 0 is wrong; special hash byte[31]=1 is wrong (use LE uint256 one). Harvest @127.0.0.1:48332.
witness_script_asm: (n/a — native P2PKH)
```

### P2WSH OP_0NOTEQUAL live @58173 (passed)

```text
height: 58173
block_hash: 0000000082559fc009f52f9c28226648a820546f54d211d0ab394937b573ebbf
txid: d04fef455929e77e5e4a29b6708051037a11953fbec64240c3689bef9a1320cd
input_index: 0
spent_script_pubkey: 0020bf25d8d9e80fb053af13bc24117ea4841e38483bdc87bf2058e474f33bc4d049
failure: (none — connected after OP_0NOTEQUAL in ScriptInterpreter)
missing_rule: OP_0NOTEQUAL (0x92) in P2WSH witness script evaluation (resolved)
python_reference: (no scout row)
java_module: com.jbitnode.consensus.script.ScriptInterpreter
java_test: com.jbitnode.consensus.script.P2wshMul58173RegressionTest, BareP2wshMul58173FixtureTest (PASSING)
fixture_tx: src/test/resources/fixtures/tx_p2wsh_mul_58173.hex
fixture_witness_script: src/test/resources/fixtures/tx_p2wsh_mul_58173_witness_script.hex
witness_script_asm: 2-of-2 CHECKMULTISIG OP_SWAP OP_SIZE OP_0NOTEQUAL OP_IF … OP_0NOTEQUAL OP_ADD 1 OP_EQUAL
java_fix: OP_0NOTEQUAL in ScriptInterpreter.evaluateScript (pop; push 1 if nonzero else 0). Root cause: 0x92 is OP_0NOTEQUAL, not OP_MUL (0x95, disabled).
follower_notes: P2WSH v0; witness stack len 5; input sequence 0x3; locktime 58172. Harvest @127.0.0.1:48332. Initial misclassification as OP_MUL corrected via decodescript asm.
```

### P2WSH OP_IFDUP/CSV live @54297 (passed)

```text
height: 54297
block_hash: 0000000000e122e7b6e89ae00472ed875842fc7c32d7e7a34765f8e4dd28da63
txid: 00b7207d21c697a183da730622117a4091ccaea238976ef0341267579ac29b12
input_index: 0
spent_script_pubkey: 00202c832ce8af0a8020f3d06b18a5e2de71663c535870d99fd69a5c184d6245e441
failure: (none — connected after OP_IFDUP in ScriptInterpreter)
missing_rule: OP_IFDUP (0x73) in P2WSH witness script evaluation (resolved)
python_reference: (no scout row)
java_module: com.jbitnode.consensus.script.ScriptInterpreter
java_test: com.jbitnode.consensus.script.P2wshIfdupCsv54297RegressionTest, BareP2wshIfdupCsv54297FixtureTest (PASSING)
fixture_tx: src/test/resources/fixtures/tx_p2wsh_ifdup_csv_54297.hex
witness_script_asm: 2-of-2 CHECKMULTISIG OP_IFDUP OP_NOTIF OP_IF CSV/IF branches
java_fix: OP_IFDUP in ScriptInterpreter.evaluateScript
follower_notes: P2WSH v0; witness stack len 6; input sequence 0x2; CSV branches already in interpreter with default flags. Harvest @127.0.0.1:48332.
```

### P2WSH OP_2DROP live @54287 (passed)

```text
height: 54287
block_hash: 00000000000ad11895995f451dacfac802d36986ea2086d599b3afe4aefcb178
txid: 9281b53ec58f80387161566838fb7bf54c2412bb7b59e150ae78ff5f5a413d0c
input_index: 0
spent_script_pubkey: 002098836c6761bf75dcbf74729b4a245c61cce68e89039e38ce2a389d3f23656038
failure: (none — connected after OP_2DROP in ScriptInterpreter)
missing_rule: OP_2DROP (0x6d) in P2WSH witness script evaluation (resolved)
python_reference: (no scout row)
java_module: com.jbitnode.consensus.script.ScriptInterpreter
java_test: com.jbitnode.consensus.script.P2wsh2drop54287RegressionTest, BareP2wsh2drop54287FixtureTest (PASSING)
fixture_tx: src/test/resources/fixtures/tx_p2wsh_2drop_54287.hex
fixture_witness_script: src/test/resources/fixtures/tx_p2wsh_2drop_54287_witness_script.hex
witness_script_asm: OP_2DROP OP_HASH160 0bfbcadae145d870428db173412d2d860b9acf5e OP_EQUAL
java_fix: OP_2DROP in ScriptInterpreter.evaluateScript
follower_notes: P2WSH v0, witness stack len 4; drops top two stack items then HASH160/EQUAL on remaining push. Harvest @127.0.0.1:48332.
```

### P2TR tapscript OP_SIZE live @52497 (passed)

```text
height: 52497
block_hash: 0000000000491575f9e5d7d809369231c77a968de544b22ecc15a7e9716d47c7
txid: c62c3c4c40feb1850f17ccbd33693c26d3ce83910c5a3fe5c058f30ecec8c6e7
input_index: 0
spent_script_pubkey: 512031b46e4751f440b63193188b859158ab5560beac41d33a3251cbfa88a1192986
failure: (none — connected on live chain after OP_SIZE in Tapscript.evaluate)
missing_rule: OP_SIZE (0x82) in BIP342 tapscript (P2TR script-path dual hashlock + 2-of-2 Schnorr) (resolved)
python_reference: (no scout row; legacy OP_SIZE at 27807 only)
java_module: com.jbitnode.consensus.script.Tapscript
java_test: com.jbitnode.consensus.script.P2trTapscriptSize52497RegressionTest, BareP2trTapscriptSize52497FixtureTest (PASSING)
fixture_tx: src/test/resources/fixtures/tx_p2tr_tapscript_size_52497.hex
fixture_prev_spk: src/test/resources/fixtures/tx_p2tr_tapscript_size_52497_prev_spk.hex
fixture_tapscript: src/test/resources/fixtures/tx_p2tr_tapscript_size_52497_tapscript.hex
fixture_control_block: src/test/resources/fixtures/tx_p2tr_tapscript_size_52497_control_block.hex
fixture_witness_0..3: src/test/resources/fixtures/tx_p2tr_tapscript_size_52497_witness_*.hex
java_fix: OP_SIZE in Tapscript.evaluate (push ScriptNum.encodeScriptNum(peek.length, 4))
follower_notes: P2TR script-path, witness stack len 6: two 64B Schnorr sigs, 17B stack blob, 16B preimage, 154B tapscript, 65B control block. Tapscript: dual OP_SHA256 OP_EQUALVERIFY with OP_SIZE OP_SWAP OP_DROP 16 OP_EQUAL size checks, then OP_EQUAL 0 OP_EQUALVERIFY and two x-only OP_CHECKSIGVERIFY/CHECKSIG. Harvest @127.0.0.1:48332.
tapscript_opcode_sequence: OP_DUP OP_SHA256 PUSH(32) OP_EQUALVERIFY OP_SIZE OP_SWAP OP_DROP OP_16 OP_EQUAL ...
```

### P2TR tapscript OP_SHA256 live @52024 (passed)

```text
height: 52024
block_hash: 000000000004de650965892b4cc23811bfed92413f83e0c3acbe176e31846be6
txid: d57def620b54b9f2f31ca5c4356be2e79c15be29233151186c6944b65bbd663d
input_index: 0
spent_script_pubkey: 51208633e66a528c86ba924ac2cbe60eb53e793fead9e0df3e10982c886f102d4b64
failure: (none — connected on live chain after OP_SHA256 in Tapscript.evaluate)
missing_rule: OP_SHA256 (0xa8) in BIP342 tapscript (P2TR script-path hashlock) (resolved)
python_reference: (no scout above 38010)
java_module: com.jbitnode.consensus.script.Tapscript
java_test: com.jbitnode.consensus.script.P2trTapscriptSha25652024RegressionTest, BareP2trTapscriptSha25652024FixtureTest, TapscriptTest (PASSING)
fixture_tx: src/test/resources/fixtures/tx_p2tr_tapscript_sha256_52024.hex
fixture_prev_spk: src/test/resources/fixtures/tx_p2tr_tapscript_sha256_52024_prev_spk.hex
fixture_tapscript: src/test/resources/fixtures/tx_p2tr_tapscript_sha256_52024_tapscript.hex
fixture_control_block: src/test/resources/fixtures/tx_p2tr_tapscript_sha256_52024_control_block.hex
fixture_witness_0: src/test/resources/fixtures/tx_p2tr_tapscript_sha256_52024_witness_0.hex
fixture_witness_1: src/test/resources/fixtures/tx_p2tr_tapscript_sha256_52024_witness_1.hex
java_fix: OP_SHA256 in Tapscript.evaluate (pop item, push ScriptHash.sha256)
follower_notes: Not key-path — tx[1] input 0 native P2TR script-path. Witness stack len 4: 65B Schnorr sig + 32B preimage + tapscript + 65B control block (merkle branch). Tapscript: OP_SHA256 hash OP_EQUALVERIFY x-only OP_CHECKSIG; tx input 1 P2WPKH in same tx. Harvest @127.0.0.1:48332 before classify. Live connect @52024; catch-up +520 blocks to 52023 before fix, +10 to 52033 after fix.
tapscript_opcode_sequence: OP_SHA256 PUSH(32) OP_EQUALVERIFY PUSH(32) OP_CHECKSIG
```

### P2SH redeem OP_ADD live @51340 (passed)

```text
height: 51340
block_hash: 00000000008951628db430d112a92f8dd350a1eb3681410314c0ca9cf2ced81e
txid: 03911305033a5aa73d7d730f16ba63b53582c6a6570d8d9f86e2f2b76fa2cbc3
input_index: 0
spent_script_pubkey: a914c464d0169c41085bcf10e3ab2cf83e74859d640b87
failure: (none — connected on live chain after OP_ADD in legacy P2SH redeem path)
missing_rule: OP_ADD (0x93) in legacy ScriptInterpreter.evaluateScript (P2SH redeem) (resolved)
python_reference: (no scout above 38010)
java_module: com.jbitnode.consensus.script.ScriptInterpreter
java_test: com.jbitnode.consensus.script.P2shAdd51340RegressionTest, BareP2shAdd51340FixtureTest, ScriptInterpreterTest (PASSING)
fixture_tx: src/test/resources/fixtures/tx_p2sh_add_51340.hex
fixture_prev_spk: src/test/resources/fixtures/tx_p2sh_add_51340_prev_spk.hex
fixture_redeem_script: src/test/resources/fixtures/tx_p2sh_add_51340_redeem_script.hex
fixture_scriptsig: src/test/resources/fixtures/tx_p2sh_add_51340_scriptsig.hex
java_fix: OP_ADD in evaluateScript (pop b, pop a, push a+b as ScriptNum)
follower_notes: Not P2WSH — tx[2] input 0 native P2SH (tx[1] P2WPKH passed first). scriptSig pushes OP_1 OP_2 + redeem script OP_ADD OP_3 OP_EQUAL; empty witness; prevout 1500 sats. Live connect @51340; catch-up +164 blocks to 51503 before pause (no new blocker).
redeem_script_opcode_sequence: OP_ADD OP_3 OP_EQUAL
```

### P2WSH witness script-path live @51340 (blocked — superseded)

```text
height: 51340
block_hash: 00000000008951628db430d112a92f8dd350a1eb3681410314c0ca9cf2ced81e
txid: (pending harvest)
input_index: 0
spent_script_pubkey: (pending harvest)
failure: script verification failed for input 0
missing_rule: (pending harvest @51340)
python_reference: (no scout above 38010)
java_module: (pending)
java_test: (pending)
follower_notes: Superseded — harvest showed tx[1] P2WPKH passed; actual blocker was tx[2] P2SH OP_ADD (see passed entry above). Lesson from 46779: MUST harvest before classifying.
```

### P2WSH witness OP_SIZE/OP_LESSTHAN/OP_CODESEPARATOR live @46779 (passed)

```text
height: 46779
block_hash: 0000000000000002ed00d479b1f8f4dc5bc1d033eb6d13c3b653010ef5bdba58
txid: fb9b18c782c2b45ccb77b4e22cbdf8b8cb1b8bf603289937968da52475e28aa5
input_index: 0
spent_script_pubkey: 0020359eaf2fdfc8952db69827596cf6fe9093f203bdbbd83749a9953f58a3a93829
failure: (none — connected on live chain after OP_LESSTHAN + OP_CODESEPARATOR in legacy P2WSH witness script)
missing_rule: OP_LESSTHAN (0x9f) + OP_CODESEPARATOR (0xab) in legacy ScriptInterpreter.evaluateScript (P2WSH witness redeem path) (resolved)
python_reference: pybitnode/consensus/script/interpreter.py (OP_LESSTHAN in evaluate_script; tapscript CODESEPARATOR only)
java_module: com.jbitnode.consensus.script.ScriptInterpreter
java_test: com.jbitnode.consensus.script.P2wshSizeLessthan46779RegressionTest, BareBlock46779FixtureTest, ScriptInterpreterTest (PASSING)
fixture_tx: src/test/resources/fixtures/tx_p2wsh_size_lessthan_46779.hex
fixture_prev_spk: src/test/resources/fixtures/tx_p2wsh_size_lessthan_46779_prev_spk.hex
fixture_witness_script: src/test/resources/fixtures/tx_p2wsh_size_lessthan_46779_witness_script.hex
java_fix: OP_LESSTHAN in evaluateScript; OP_CODESEPARATOR truncates effectiveScriptCode for BIP143 sighash (EvalContext.codeSeparatorOffset)
follower_notes: Not P2TR — tx[1] input 0 native P2WSH. Witness stack [71B DER sig, 41B witnessScript]. Witness script: OP_SIZE PUSH(80) OP_LESSTHAN OP_VERIFY OP_CODESEPARATOR PUSH(33) OP_CHECKSIG; empty scriptSig; prevout 1143 sats. Live connect @46779; catch-up +4561 blocks to 51339 before next blocker @51340.
witness_script_opcode_sequence: OP_SIZE PUSH(80) OP_LESSTHAN OP_VERIFY OP_CODESEPARATOR PUSH(33) OP_CHECKSIG
```

### P2WSH witness OP_SIZE/OP_LESSTHAN/OP_CODESEPARATOR live @46779 (passed)

```text
height: 46599
block_hash: 00000000000000193205628255bc2004082bc1a83ba337f79fe4f591f99fc7e8
txid: d16704313ed3cd64f082c92b40d72ccf5ede213f739c3f217caf59f1ca6c962f
input_index: 0
spent_script_pubkey: 5120a23f913d1fc28f07abbcc72218ed00e0d149287b9e86187e54b0c6340ce584b3
failure: (none — connected on live chain after castToBool Core semantics fix)
missing_rule: castToBool treats 0x80 as false only when last byte (terminal tapscript stack 0x809e…) (resolved)
python_reference: (no scout above 38010)
java_module: com.jbitnode.consensus.script.ScriptInterpreter
java_test: com.jbitnode.consensus.script.P2trScriptPath46599RegressionTest, BareP2trScriptPath46599FixtureTest, ScriptInterpreterTest (PASSING)
fixture_tx: src/test/resources/fixtures/tx_p2tr_scriptpath_46599.hex
fixture_prev_spk: src/test/resources/fixtures/tx_p2tr_scriptpath_46599_prev_spk.hex
fixture_tapscript: src/test/resources/fixtures/tx_p2tr_scriptpath_46599_tapscript.hex
fixture_control_block: src/test/resources/fixtures/tx_p2tr_scriptpath_46599_control_block.hex
java_fix: castToBool — 0x80 false only when index == length-1 (mirror Core CastToBool)
follower_notes: Same tapscript template as @44295; terminal stack item 0x809e000000000000. Merkle + Schnorr passed; strict terminal failed before fix. Live connect @46599; catch-up +180 blocks to 46778 before next blocker @46779.
tapscript_opcode_sequence: PUSH(32) OP_CHECKSIGVERIFY PUSH(2) OP_0 OP_IF PUSH(64) PUSH(33) PUSH(49) OP_ENDIF PUSH(8) OP_NIP
```

### P2WSH witness OP_SIZE/OP_LESSTHAN/OP_CODESEPARATOR live @46779 (passed — see entry above)

```text
height: 46779
block_hash: 0000000000000002ed00d479b1f8f4dc5bc1d033eb6d13c3b653010ef5bdba58
txid: fb9b18c782c2b45ccb77b4e22cbdf8b8cb1b8bf603289937968da52475e28aa5
input_index: 0
spent_script_pubkey: 0020359eaf2fdfc8952db69827596cf6fe9093f203bdbbd83749a9953f58a3a93829
failure: (none — resolved via OP_LESSTHAN + OP_CODESEPARATOR fix; see passed entry above)
missing_rule: OP_LESSTHAN + OP_CODESEPARATOR in P2WSH witness script (resolved)
follower_notes: Superseded by "P2WSH witness OP_SIZE/OP_LESSTHAN/OP_CODESEPARATOR live @46779 (passed)" entry. Initial ledger assumed P2TR; harvest showed native P2WSH.
```

### P2TR script-path OP_NIP live @44295 (passed)

```text
height: 44295
block_hash: 00000000cb1234452fea6487434e627a26825942af62111d9dba1978ae1e9d20
txid: cb835ce1d726993515c27df94a358bf327b03323fb0e82c823c1faab31b28786
input_index: 0
spent_script_pubkey: 5120346d44aef23b267970d8c090d8fed28e2dcf772b609f566cdc56e108ff84118a
failure: (none — connected on live chain after OP_NIP in Tapscript)
missing_rule: OP_NIP (0x77) in BIP342 tapscript after CHECKSIGVERIFY + IF envelope (resolved)
python_reference: (no scout above 38010)
java_module: com.jbitnode.consensus.script.Tapscript
java_test: com.jbitnode.consensus.script.P2trScriptPath44295RegressionTest, BareP2trScriptPath44295FixtureTest, TapscriptTest (PASSING)
fixture_tx: src/test/resources/fixtures/tx_p2tr_scriptpath_44295.hex
fixture_prev_spk: src/test/resources/fixtures/tx_p2tr_scriptpath_44295_prev_spk.hex
fixture_tapscript: src/test/resources/fixtures/tx_p2tr_scriptpath_44295_tapscript.hex
fixture_control_block: src/test/resources/fixtures/tx_p2tr_scriptpath_44295_control_block.hex
java_fix: OP_NIP in Tapscript.evaluate (removes second-from-top stack item)
follower_notes: Witness stack len 3 (64B sig + 199B tapscript + 33B control block). Tapscript ends PUSH(8) OP_NIP; IF branch skipped (OP_0 selector). Live connect @44295; catch-up +2304 blocks to 46598 before next P2TR script-path blocker @46599.
tapscript_opcode_sequence: PUSH(32) OP_CHECKSIGVERIFY PUSH(2) OP_0 OP_IF PUSH(64) PUSH(33) PUSH(49) OP_ENDIF PUSH(8) OP_NIP
```

### P2TR script-path live @46599 (passed — see castToBool entry above)

```text
height: 46599
block_hash: 00000000000000193205628255bc2004082bc1a83ba337f79fe4f591f99fc7e8
txid: d16704313ed3cd64f082c92b40d72ccf5ede213f739c3f217caf59f1ca6c962f
input_index: 0
spent_script_pubkey: 5120a23f913d1fc28f07abbcc72218ed00e0d149287b9e86187e54b0c6340ce584b3
failure: (none — resolved via castToBool fix; see passed entry above)
missing_rule: castToBool terminal stack semantics (resolved)
follower_notes: Superseded by "P2TR script-path castToBool terminal stack live @46599 (passed)" entry.
```

### Bare OP_1 + data push live @41700 (passed)

```text
height: 41700
block_hash: 000000000013ae973ef034970b5a6c234338d27a0f6ed573913a6de6c9dddbbd
txid: 4a89d5d1568b5cbcb4118559cb65d2357657d361a41cd96b14e74ed3d065975c
input_index: 0
spent_script_pubkey: 51024e73
failure: (none — connected on live chain after bare OP_1 + trailing data push template)
missing_rule: bare OP_1 + single data push (OP_1 0x02 0x4e73); empty scriptSig; relaxed top-of-stack (resolved)
python_reference: pybitnode/consensus/script/interpreter.py (is_bare_op_n covers single opcode only; live discovery extends to OP_N + push)
java_module: com.jbitnode.consensus.script.{ScriptTemplates,ScriptVerify}
java_test: com.jbitnode.consensus.script.BareOp1Push41700RegressionTest, BareOp1Push41700FixtureTest, ScriptTemplatesBareOpNTest (PASSING)
fixture_block: src/test/resources/fixtures/block_41700.hex
fixture_tx: src/test/resources/fixtures/tx_bare_op1_push_41700.hex
fixture_prev_spk: src/test/resources/fixtures/tx_bare_op1_push_41700_prev_spk.hex
fixture_scriptsig: src/test/resources/fixtures/tx_bare_op1_push_41700_scriptsig.hex
java_fix: isBareOpN accepts OP_1..OP_16/OP_1NEGATE + one data push (excludes P2TR/P2WPKH/P2WSH); terminalSuccessRelaxed for multi-byte bare_op_n
follower_notes: scriptPubKey asm `1 29518` (OP_1 then 2-byte push 0x4e73); prevout 20000 sats; empty scriptSig/witness. Live connect @41700; catch-up +2595 blocks to 44294 before P2TR script-path blocker @44295 (resolved — see passed entry above).
```

### P2SH CLTV redeem live @38191 (passed)

```text
height: 38191
block_hash: 000000000000000c7f9078cb5991c06bc4d5698471920dee73aa93de7579c8f7
txid: 4e477ff4e1a12fd78e76fb7dec0d0fcd6fb0372f757fabceb83fdb041c6ee9b6
input_index: 0
spent_script_pubkey: a914bbe352f1c5366dd92bcae64f4de33e6b56df7e3d87
failure: (none — connected on live chain after BIP65 CLTV no-op on nVersion=1)
missing_rule: OP_CHECKLOCKTIMEVERIFY (0xb1) BIP65 no-op when tx nVersion < 2 in legacy P2SH redeem (resolved)
python_reference: pybitnode/consensus/script/interpreter.py (_exec_checklocktimeverify — note: Python currently throws on v1; Core/BIP65 no-op)
java_module: com.jbitnode.consensus.script.ScriptInterpreter
java_test: com.jbitnode.consensus.script.P2shCltv38191RegressionTest, BareP2shCltv38191FixtureTest, ScriptInterpreterTest (PASSING)
fixture_tx: src/test/resources/fixtures/tx_p2sh_cltv_38191.hex
fixture_prev_spk: src/test/resources/fixtures/tx_p2sh_cltv_38191_prev_spk.hex
fixture_redeem_script: src/test/resources/fixtures/tx_p2sh_cltv_38191_redeem_script.hex
fixture_scriptsig: src/test/resources/fixtures/tx_p2sh_cltv_38191_scriptsig.hex
java_fix: execCheckLockTimeVerify + execCheckSequenceVerify return early (NOP) when tx.version() < 2 (BIP65/BIP112)
follower_notes: Redeem script `30000 OP_CHECKLOCKTIMEVERIFY OP_DROP pubkey OP_CHECKSIG`; tx nVersion=1 nLockTime=30000 nSequence=0x221. Live connect proof at 38191; catch-up continued 3509 blocks to 41699 before bare-script blocker at 41700.
```

### P2PKH SIGHASH_SINGLE + nSequence live @38010 (passed)

```text
height: 38010
block_hash: 000000000000001287d6f4d832f330d1d9cddb3bb3741b25a4aeb8263a57a626
txid: ba32ba8e2d812d93317a0503d37d505a826517343f7fec3b8c2e0c715f142eb6
input_index: 0
spent_script_pubkey: 76a9149ec1ccfb40904402ee1d0a1c332c503772f22b3188ac
failure: (none — connected on live chain after LegacySighash SIGHASH_SINGLE nSequence fix)
missing_rule: SIGHASH_SINGLE (0x03) with nSequence 0xfffffffd in legacy RawSignatureHash (resolved)
python_reference: pybitnode/consensus/script/sighash.py (legacy sighash input sequence handling)
python_test: tests/test_script.py → test_real_testnet4_block38010_p2pkh_sighash_single_sequence_accepted
java_module: com.jbitnode.consensus.script.LegacySighash
java_test: com.jbitnode.consensus.script.P2pkhSighashSingle38010RegressionTest, LegacySighashTest (PASSING)
fixture_tx: src/test/resources/fixtures/tx_p2pkh_sighash_single_38010.hex
fixture_prev_spk: src/test/resources/fixtures/tx_p2pkh_sighash_single_38010_prev_spk.hex
fixture_scriptsig: src/test/resources/fixtures/tx_p2pkh_sighash_single_38010_scriptsig.hex
java_fix: LegacySighash.writeInput keeps signing input nSequence for SIGHASH_SINGLE (baseType==1 || signingInput)
follower_notes: Live connect proof at 38010; catch-up continued 181 blocks to 38190 before P2SH blocker at 38191.
```

### P2SH→P2WSH len-1 witness live @33500 (passed)

```text
height: 33500
block_hash: 0000000000000034e4c77a0972d1e032375271199ab86d3522c608fd36bf56c4
txid: f89a4629debeee9b32a3aaed72a209877a79b070ddcd4b6358312d5724b60683
input_index: 0
spent_script_pubkey: a91472c44f957fc011d97e3406667dca5b1c930c402687
failure: (none — connected on live chain after nested P2WSH minWitnessItems fix)
missing_rule: P2SH-wrapped P2WSH len(witness)==1 (nested segwit path) (resolved)
python_reference: pybitnode/consensus/script/interpreter.py (P2SH nested P2WSH branch, len(witness) >= 1)
python_test: tests/test_script.py → test_real_testnet4_block33500_p2sh_p2wsh_op1_only_witness_accepted
java_module: com.jbitnode.consensus.script.ScriptVerify (verifyP2wshWitness nested path)
java_test: com.jbitnode.consensus.script.P2shP2wshOp1Only33500RegressionTest, BareFixture33500Test (PASSING)
fixture_tx: src/test/resources/fixtures/tx_p2sh_p2wsh_op1_only_33500.hex
fixture_prev_spk: src/test/resources/fixtures/tx_p2sh_p2wsh_op1_only_33500_prev_spk.hex
fixture_witness_script: src/test/resources/fixtures/tx_p2sh_p2wsh_op1_only_33500_witness_script.hex
java_fix: verifyP2wshWitness minWitnessItems 2→1 (mirror native P2WSH @31842)
follower_notes: scriptSig pushes nested witness program `00204ae815…`; witness stack `[51]` only. Live connect proof at 33500; catch-up continued to 38009 before SIGHASH_SINGLE blocker at 38010.
```

### P2WSH witness OP_CHECKLOCKTIMEVERIFY live @32868 (passed)

```text
height: 32868
block_hash: 00000000000000609ae7ba69fd0f7b32ea44503ff9e2bebe70eb34dd13c35ac2
txid: 8add2663f689111add26c4bc52a2f6060d48e41750c143cdfa8564ac114d97dc
input_index: 0
spent_script_pubkey: 00201b3129860946f970569a12850caede1782d2c8163bb26e284bf3f4af1b4e5077
failure: (none — connected on live chain after legacy OP_CHECKLOCKTIMEVERIFY / OP_CHECKSEQUENCEVERIFY)
missing_rule: OP_CHECKLOCKTIMEVERIFY (0xb1) in legacy ScriptInterpreter.evaluateScript (P2WSH witness redeem path) (resolved)
python_reference: pybitnode/consensus/script/interpreter.py (_exec_checklocktimeverify, _exec_checksequenceverify in evaluate_script)
python_test: tests/test_script.py → test_p2wsh_cltv_roundtrip (synthetic); live tx @32868
java_module: com.jbitnode.consensus.script.ScriptInterpreter
java_test: com.jbitnode.consensus.script.P2wshCltv32868RegressionTest, BareCltv32868FixtureTest, ScriptInterpreterTest (PASSING)
fixture_tx: src/test/resources/fixtures/tx_p2wsh_cltv_32868.hex
fixture_prev_spk: src/test/resources/fixtures/tx_p2wsh_cltv_32868_prev_spk.hex
fixture_witness_script: src/test/resources/fixtures/tx_p2wsh_cltv_32868_witness_script.hex
java_fix: execCheckLockTimeVerify + execCheckSequenceVerify in legacy evaluateScript when SCRIPT_VERIFY_* flags set (mirror Tapscript BIP65/BIP112)
follower_notes: IF/ELSE witness script; ELSE branch CLTV with nLockTime 1719894876; catch-up continued 32868→33499 before P2SH nested P2WSH blocker at 33500.
```

### P2TR tapscript OP_NUMEQUAL live @32712 (passed)

```text
height: 32712
block_hash: 0000000000000013db0b030faef1dd4e341e176036db9db4365f8430aadba6a3
txid: 6b586a4f831e267749a3c2e50b866fe5badb582d3d388ea636669cbdc13acd94
input_index: 0
spent_script_pubkey: 51203a6c36818562ca3aa86741eb70dda13da67a5977255fc8af67109c8dbdd9f3ca
failure: (none — connected on live chain after OP_NUMEQUAL / OP_NUMNOTEQUAL in Tapscript)
missing_rule: OP_NUMEQUAL (0x9c) in tapscript after CHECKSIGADD 2-of-3 (resolved)
python_reference: pybitnode/consensus/script/interpreter.py (_evaluate_tapscript OP_NUMEQUAL/OP_NUMNOTEQUAL)
python_test: tests/test_script.py → test_real_testnet4_block32712_p2tr_tapscript_checksigadd_2of3_numequal_accepted
java_module: com.jbitnode.consensus.script.Tapscript
java_test: com.jbitnode.consensus.script.P2trTapscriptNumequal32712RegressionTest, BareFixture32712Test (PASSING)
fixture_tx: src/test/resources/fixtures/tx_p2tr_tapscript_numequal_32712.hex
fixture_prev_spk: src/test/resources/fixtures/tx_p2tr_tapscript_numequal_32712_prev_spk.hex
fixture_tapscript: src/test/resources/fixtures/tx_p2tr_tapscript_numequal_32712_tapscript.hex
java_fix: OP_NUMEQUAL / OP_NUMNOTEQUAL in Tapscript.evaluate (commit 86e32da)
follower_notes: Live connect proof at 32712; catch-up continued to 32867 before P2WSH CLTV blocker at 32868.
```

### P2WSH len-1 witness live @31842 (passed)

```text
height: 31842
block_hash: 0000000000000042e3cc0898fda85fbbea98fcdb9acfa17742bf72d59996dd51
txid: b6dc55194be800938ea64ceaad98c299bbfe8590b2472779218808746f4a2659
input_index: 0
spent_script_pubkey: 00204ae81572f06e1b88fd5ced7a1a000945432e83e1551e6f721ee9c00b8cc33260
failure: (none — connected on live chain; native P2WSH already accepts len-1 witness stack)
missing_rule: P2WSH witness-script-only len-1 stack (already supported in Java P2WSH path)
python_reference: pybitnode/consensus/script/interpreter.py (len(witness) >= 1 in P2WSH branch)
python_test: tests/test_script.py → test_real_testnet4_block31842_p2wsh_op1_only_witness_accepted
java_module: com.jbitnode.consensus.script.ScriptVerify (verifyP2wsh)
java_test: com.jbitnode.consensus.script.BareFixture31842Test (fixture anchor)
fixture_tx: src/test/resources/fixtures/tx_p2wsh_op1_only_31842.hex
fixture_prev_spk: src/test/resources/fixtures/tx_p2wsh_op1_only_31842_prev_spk.hex
java_fix: (none required — existing P2WSH path accepts [witnessScript] alone)
follower_notes: Scout flagged 31842 as likely blocker; Java passed without code change during 31240→32711 catch-up.
```

### Bare OP_2 + embedded pubkey live @27840 (passed)

```text
height: 27840
block_hash: 000000000000004ba29c976c33753742a34fb029eb261e146dfd31bccdadb9bc
txid: f2b2a965cac99c85f71f8705454793183e93a47b558c485dec92c1101bdacf55
input_index: 0
spent_script_pubkey: 524104ad34a2c1bbd3aec7ebae0c3cfab37c0715ec3a189597ae31b1ed1f44abe93047e2ec7a945c2a1219484bdb458068bb8a7ce13c190325357a29424a089b8bd756410478607280574ccab25285b26d225c02988b68cf2adead05f2d21a12b3006026d6e71aa2491733c8731d4ac44be2ae5eb4552180c9d0cb29f37fb0167adb51b37e4104bf81ac047f76bd187351a9dc5ea2fead1b0de39fc367e9b6ebdcc1d877dfb2da8ec28ad50dde6732dc94bdd4f26382bac4f69cda10987b43151cb613f7e06f7653ae
failure: (none — connected on live chain after bare multisig template implementation)
missing_rule: bare legacy 2-of-3 multisig (OP_2 + 3 uncompressed pubkeys + OP_3 OP_CHECKMULTISIG) (resolved)
python_reference: pybitnode/consensus/script/interpreter.py (is_bare_multisig, legacy CHECKMULTISIG path)
python_test: tests/test_script.py → test_real_testnet4_block27840_bare_multisig_accepted
java_module: com.jbitnode.consensus.script.{ScriptTemplates,ScriptVerify}
java_test: com.jbitnode.consensus.script.BareMultisig27840RegressionTest, BareMultisig27840FixtureTest (PASSING)
fixture_tx: src/test/resources/fixtures/tx_bare_multisig_27840.hex
fixture_prev_spk: src/test/resources/fixtures/tx_bare_multisig_27840_prev_spk.hex
java_fix: isBareMultisig template + legacy scriptSig/scriptPubKey evaluation (OP_0 dummy + 2 DER sigs)
follower_notes: Bare 2-of-3 multisig at input 0; live connect proof at 27840; catch-up continued 27840→31239 (3400 blocks) with no new validation blocker before manual stop.
```

### P2SH redeem IF numeric branch live @27815 (passed)

```text
height: 27815
block_hash: 00000000f649f4308fe8859ba632114ae244632461293c031cd905794981b250
txid: 2a691884927c92649b0c8759f929b931ba21d75bb21bc21f4a3b5868be0bc4d7
input_index: 0
spent_script_pubkey: a9149bd8827378f1a7dbd6f5ace4c90ab98b706fb86287
failure: (none — connected on live chain after OP_SWAP/OP_SUB/OP_GREATERTHAN implementation)
missing_rule: OP_SWAP / OP_SUB / OP_GREATERTHAN in legacy script evaluation inside P2SH IF branch (resolved)
python_reference: pybitnode/consensus/script/interpreter.py (OP_SWAP, OP_SUB, OP_GREATERTHAN in evaluate_script)
python_test: tests/test_script.py → test_real_testnet4_block27815_p2sh_if_else_numeric_branch_accepted
java_module: com.jbitnode.consensus.script.ScriptInterpreter
java_test: com.jbitnode.consensus.script.P2shIfElseNumeric27815RegressionTest, BareP2shIfElseNumeric27815FixtureTest (PASSING)
fixture_tx: src/test/resources/fixtures/tx_p2sh_ifelse_27815.hex
fixture_prev_spk: src/test/resources/fixtures/tx_p2sh_ifelse_27815_prev_spk.hex
java_fix: OP_SWAP + OP_SUB + OP_GREATERTHAN (+ existing OP_VERIFY) in legacy evaluateScript; ScriptNum encode/decode for stack arithmetic
follower_notes: IF branch selector OP_1; compares 2024 − 2001 > 18 via OP_SWAP/OP_SUB/OP_GREATERTHAN/OP_VERIFY; live connect proof at 27815; catch-up continued to 27839 before bare OP_2 blocker at 27840.
```

### P2SH redeem OP_SHA256 live @27807 (passed)

```text
height: 27807
block_hash: 000000000024e0d475a335fe6bbf8032bd342337f98bb378423bc43fb5187ffc
txid: d1a68c8f20cc0ce8297e4f4b5ec297af1c6f98630e8105fd9d63b39c004c4ff0
input_index: 0
spent_script_pubkey: a914d569ebaca3b27115a284275caae03594e3e50db687
failure: (none — connected on live chain after OP_SHA256/OP_SIZE implementation)
missing_rule: OP_SHA256 / OP_SIZE in legacy script evaluation inside P2SH redeem (resolved)
python_reference: pybitnode/consensus/script/interpreter.py (OP_SHA256, OP_SIZE in evaluate_script)
python_test: tests/test_script.py → test_real_testnet4_block27807_p2sh_if_else_sha256_accepted
java_module: com.jbitnode.consensus.script.ScriptInterpreter
java_test: com.jbitnode.consensus.script.P2shIfElseSha25627807RegressionTest (PASSING)
fixture_tx: src/test/resources/fixtures/tx_p2sh_ifelse_27807.hex
fixture_prev_spk: src/test/resources/fixtures/tx_p2sh_ifelse_27807_prev_spk.hex
java_fix: OP_SHA256 (ScriptHash.sha256) + OP_SIZE (ScriptNum.encodeScriptNum) in legacy evaluateScript
follower_notes: ELSE branch hashlock with empty-push IF selector; live connect proof at 27807; catch-up continued to 27814 before numeric IF-branch blocker at 27815.
```

### P2WSH witness OP_IF live @27251 (passed)

```text
height: 27251
block_hash: 00000000e32a5d69a7e766fa4c386b239d10aabe0837ebfddb7fb6c5578b9c78
txid: a66a655defd3f3abef44ea0ba71dd9939b4b81f894a04fc18160c9ca5e78b0a0
input_index: 0
spent_script_pubkey: 0020e51d37e194ce5fb07c41c7301cdcd6391713c93c276fe115384172e86c8ba660
failure: (none — connected on live chain after OP_IF/OP_ELSE/OP_ENDIF implementation)
missing_rule: OP_IF / OP_ELSE / OP_ENDIF in legacy witness scripts (resolved)
python_reference: pybitnode/consensus/script/interpreter.py (evaluate_script OP_IF/OP_ELSE/OP_ENDIF)
python_test: tests/test_script.py → test_real_testnet4_block27251_p2wsh_if_else_multisig_accepted
java_module: com.jbitnode.consensus.script.ScriptInterpreter
java_test: com.jbitnode.consensus.script.P2wshIfElse27251RegressionTest, BareP2wshIfElse27251FixtureTest (PASSING)
fixture_tx: src/test/resources/fixtures/tx_p2wsh_ifelse_27251.hex
fixture_prev_spk: src/test/resources/fixtures/tx_p2wsh_ifelse_27251_prev_spk.hex
java_fix: legacy conditional opcode evaluation (OP_IF/OP_NOTIF/OP_ELSE/OP_ENDIF + inactive-branch skip) in ScriptInterpreter; BlockConnector reports script_verification_failed for known templates
follower_notes: Live connect proof at 27251; catch-up continued to 27806 before P2SH OP_SHA256 blocker at 27807.
```

### P2WSH native live @27042 (passed)

```text
height: 27042
block_hash: 00000000000000048ae4dc427b255f06a0acd60eaa80bd8d9bdb223dfd9040b0
txid: 0864a600ee15635ebb60678c1f25ea043f8470a126b0fb0d7acd2e10afd1bf33
input_index: 0
spent_script_pubkey: 0020379e4b5ccd93422995b409b9c862c8bc7fd92999bb0e92dc9649c03e8ab9fb68
failure: (none — connected on live chain after native P2WSH + CHECKMULTISIG implementation)
missing_rule: P2WSH native v0 witness script hash (resolved)
python_reference: pybitnode/consensus/script/interpreter.py (is_p2wsh, verify_script P2WSH path, _exec_checkmultisig)
java_module: com.jbitnode.consensus.script.{ScriptVerify,ScriptInterpreter}
java_test: com.jbitnode.consensus.script.P2wsh27042RegressionTest, BareP2wsh27042FixtureTest (PASSING)
fixture_tx: src/test/resources/fixtures/tx_p2wsh_27042.hex
fixture_prev_spk: src/test/resources/fixtures/tx_p2wsh_27042_prev_spk.hex
java_fix: verifyP2wsh() BIP141 path (SHA256 witnessScript + BIP143 sighash) + legacy CHECKMULTISIG for 2-of-2 witness script
follower_notes: Live connect proof at 27042; catch-up continued to 27250 before OP_IF witness-script blocker at 27251.
```

### Bare OP_1 live @25207 (passed)

```text
height: 25207
block_hash: 00000000000000463dba9f98b495062219453ea8ee8e3a311ff7a8ad5e03da0b
txid: 23bf6f595cc12dde71239de913ea9a30fb60ef20a3a54246701a2dff16227f43
input_index: 1
spent_script_pubkey: 51
failure: (none — connected on live chain after bare OP_1 template implementation)
missing_rule: bare OP_1 / bare_op_n (resolved)
python_reference: pybitnode/consensus/script/interpreter.py (is_bare_op_n, legacy script evaluation)
java_module: com.jbitnode.consensus.script.{ScriptTemplates,ScriptVerify}
java_test: com.jbitnode.consensus.script.Op1_25207RegressionTest, BareOp1_25207FixtureTest (PASSING)
fixture_tx: src/test/resources/fixtures/tx_op1_25207.hex
fixture_prev_spk: src/test/resources/fixtures/tx_op1_25207_prev_spk.hex
java_fix: isBareOpN template + legacy scriptSig/scriptPubKey evaluation (empty scriptSig satisfies OP_1)
follower_notes: Input 1 spends 1-sat prevout with scriptPubKey 51; empty scriptSig + OP_1 push → terminal success. Live connect proof at 25207; catch-up continued to 27041 before P2WSH blocker.
```

### P2TR script-path live @22830 (passed)

```text
height: 22830
block_hash: 00000000000002a436f697d3411d77b66609c47a398951acc82f8307c880116d
txid: 630725d944cb0ddba2e249f248b725d1f136fc3d698e8dc4f6be61e9103fa33c
input_index: 0
spent_script_pubkey: 5120f6b00789c732c14a921e61f2b1918a8a8db262d5b0aa2fb6e8229ce3870acda5
failure: (none — connected on live chain after BIP342 tapscript implementation)
missing_rule: P2TR script-path (resolved)
python_reference: pybitnode/consensus/script/interpreter.py (_verify_p2tr_script_path, _evaluate_tapscript)
java_module: com.jbitnode.consensus.script.{Taproot,Tapscript,TaprootHash}
java_test: com.jbitnode.consensus.script.P2trScriptPath22830RegressionTest (PASSING)
fixture_tx: src/test/resources/fixtures/tx_p2tr_scriptpath_22830.hex
fixture_prev_spk: src/test/resources/fixtures/tx_p2tr_scriptpath_22830_prev_spk.hex
java_fix: BIP342 control block + tapleaf merkle verification + tapscript evaluator (OP_IF envelope at 22830)
follower_notes: Live connect proof at 22830; catch-up continued to 25206 before bare-script blocker
```

### P2SH live @18675 (passed)

```text
height: 18675
block_hash: 0000000000003969823692a8e899365b91b6c98936feeaa195c22972d786ecd1
txid: 82be4b75b218e7a62e00b8ec064f159e04449c025d6b8aa5079a89a7bc80ca7c
input_index: 0
spent_script_pubkey: a9144dae69b35b0f315f4823565a28b485d6a3609ad987
failure: (none — connected on live chain after BIP16 P2SH implementation)
missing_rule: P2SH (resolved)
python_reference: pybitnode/consensus/script/interpreter.py (is_p2sh, parse_push_only_scriptSig, redeem evaluation)
java_module: com.jbitnode.consensus.script.ScriptVerify (verifyP2sh + nested P2WPKH/P2PKH/P2WSH paths)
java_test: com.jbitnode.consensus.script.P2sh18675RegressionTest (PASSING)
fixture_tx: src/test/resources/fixtures/tx_p2sh_18675.hex
fixture_prev_spk: src/test/resources/fixtures/tx_p2sh_18675_prev_spk.hex
java_fix: BIP16 outer P2SH + inner redeem evaluation (nested P2WPKH at 18675; synthetic P2PKH/P2WPKH roundtrips)
follower_notes: Live connect proof at 18675; catch-up continued to 22829 before P2TR script-path blocker
```

### P2TR key-path live @6975 (passed)

```text
height: 6975
block_hash: 000000000170ab1f84b7e3c702778a9eb9e71fdf5065037bce65e90d553f8f91
txid: 12376f5a136a337ce4ea4025dbef2c18158945ef6aac58f2fc4d7c5fe81dff62
input_index: 0
spent_script_pubkey: (see fixtures/tx_taproot_6975_prev_spk.hex)
failure: (none — connected on live chain after quiescent single-writer catch-up)
missing_rule: P2TR key-path (implemented)
java_test: com.jbitnode.consensus.script.Taproot6975RegressionTest
follower_notes: Offline regression + live connect proof at height 6975 with DatadirLock enforced
```

### Missing UTXO resolved (parallel writers — not BlockConnector logic bug)

```text
height: (various 5099–5324 during race; e.g. 5318)
block_hash: (varies)
txid: (varies; e.g. 578f0fc3679a599f6bcd567362cac8c8f926a12d2129bf76a7b7495a8b1153b5)
input_index: (varies; e.g. vout 5)
spent_script_pubkey: (n/a — UTXO existed; lost race)
failure: ConnectBlockException missing UTXO / internal error could not capture undo
missing_rule: sync/datadir — exclusive writer enforcement
python_reference: TypeScript sync_batch_loop.lock pattern; not a consensus rule gap
java_module: com.jbitnode.storage.DatadirLock, com.jbitnode.sync.ChainConsistency
java_test: com.jbitnode.storage.DatadirLockTest, com.jbitnode.consensus.connect.BlockConnectorConcurrentRaceTest
java_fix: exclusive .jbitnode.lock on sync entry; pre-flight ChainConsistency; BlockSync height-align guard
follower_notes: Root cause = two BLOCKS_MAX=0 sync processes on ./data-java. Events show missing UTXO while undo rows prove the other writer connected the same height. Quiescent single-writer catch-up continues cleanly.
```

## Scout path (anticipated blockers above 32712)

Python scout fixtures in `PythonNode/tests/test_script.py` with `test_real_testnet4_block3*`
and height **> 32868** (lowest first). Live blocker now @41700 (bare scriptPubKey `51024e73…`);
@38191 P2SH CLTV BIP65 v1 no-op resolved in this commit. Fixtures harvested 2026-05-25 via Core RPC
`127.0.0.1:48332` (`ReferenceNode` docker).

| Height | Python test | missing_rule (scout summary) | Java fixture prefix | Status |
|--------|-------------|------------------------------|---------------------|--------|
| 33500 | `test_real_testnet4_block33500_p2sh_p2wsh_op1_only_witness_accepted` | P2SH-wrapped P2WSH len(witness)==1 (nested segwit path; same OP_1-only edge as native P2WSH @31842) | `tx_p2sh_p2wsh_op1_only_33500*` | **passed** — live connect @33500 after verifyP2wshWitness minWitnessItems fix |
| 38010 | `test_real_testnet4_block38010_p2pkh_sighash_single_sequence_accepted` | SIGHASH_SINGLE (0x03) + nSequence `0xfffffffd`; legacy sighash must keep signing input sequence (Core RawSignatureHash) | `tx_p2pkh_sighash_single_38010*` | **passed** — live connect @38010 after LegacySighash nSequence fix |

No Python `test_real_testnet4_block34*` scout fixture exists between 33500 and 38010.

## Scout path above 38191 (2026-05-25)

Grep of `PythonNode/tests/test_script.py` for `test_real_testnet4_block38*` and
`test_real_testnet4_block39*` with height **> 38191**:

**No Python scout fixtures above 38191.**

| Height | Python test | missing_rule (scout summary) | Java fixture prefix | Status |
|--------|-------------|------------------------------|---------------------|--------|
| — | — | — | — | **none** |

Scout facts:

- Highest Python `test_real_testnet4_block*` height: **38010**
  (`test_real_testnet4_block38010_p2pkh_sighash_single_sequence_accepted` — passed).
- No `block38*` scout between 38010 and live blocker **38191** (P2SH redeem).
- No `block39*` scout tests exist in Python at any height.
- Core RPC harvest @ `127.0.0.1:48332` skipped — no scout heights to anchor after 38191.
- Next work: diagnose live @38191 P2SH redeem (main agent); add Python/Java fixtures
  after exact opcode is identified.

Live @38191 blocker details remain in **P2SH redeem live @38191 (blocked)** above;
this section does not overwrite them.

### P2SH→P2WSH len-1 witness scout @33500 (passed)

```text
height: 33500
block_hash: 0000000000000034e4c77a0972d1e032375271199ab86d3522c608fd36bf56c4
txid: f89a4629debeee9b32a3aaed72a209877a79b070ddcd4b6358312d5724b60683
input_index: 0
spent_script_pubkey: a91472c44f957fc011d97e3406667dca5b1c930c402687
failure: (none — connected on live chain after verifyP2wshWitness minWitnessItems fix)
missing_rule: P2SH-wrapped P2WSH len(witness)==1 (nested segwit path) (resolved)
python_reference: pybitnode/consensus/script/interpreter.py (P2SH nested P2WSH branch, len(witness) >= 1)
python_test: tests/test_script.py → test_real_testnet4_block33500_p2sh_p2wsh_op1_only_witness_accepted
java_module: com.jbitnode.consensus.script.ScriptVerify (verifyP2wshWitness nested path)
java_test: com.jbitnode.consensus.script.P2shP2wshOp1Only33500RegressionTest (PASSING)
fixture_tx: src/test/resources/fixtures/tx_p2sh_p2wsh_op1_only_33500.hex
fixture_prev_spk: src/test/resources/fixtures/tx_p2sh_p2wsh_op1_only_33500_prev_spk.hex
fixture_witness_script: src/test/resources/fixtures/tx_p2sh_p2wsh_op1_only_33500_witness_script.hex
java_fix: verifyP2wshWitness minWitnessItems 2→1 (mirror native P2WSH @31842)
follower_notes: scriptSig pushes nested witness program `00204ae815…`; witness stack `[51]` only. Live connect proof at 33500; catch-up continued 4510 blocks to 38009.
```

### P2PKH SIGHASH_SINGLE + nSequence scout @38010 (passed)

```text
height: 38010
block_hash: 000000000000001287d6f4d832f330d1d9cddb3bb3741b25a4aeb8263a57a626
txid: ba32ba8e2d812d93317a0503d37d505a826517343f7fec3b8c2e0c715f142eb6
input_index: 0
spent_script_pubkey: 76a9149ec1ccfb40904402ee1d0a1c332c503772f22b3188ac
failure: (none — connected on live chain after LegacySighash SIGHASH_SINGLE nSequence fix)
missing_rule: SIGHASH_SINGLE (0x03) with nSequence 0xfffffffd in legacy RawSignatureHash (resolved)
python_reference: pybitnode/consensus/script/sighash.py (legacy sighash input sequence handling)
python_test: tests/test_script.py → test_real_testnet4_block38010_p2pkh_sighash_single_sequence_accepted
java_module: com.jbitnode.consensus.script.LegacySighash
java_test: com.jbitnode.consensus.script.P2pkhSighashSingle38010RegressionTest (PASSING)
fixture_tx: src/test/resources/fixtures/tx_p2pkh_sighash_single_38010.hex
fixture_prev_spk: src/test/resources/fixtures/tx_p2pkh_sighash_single_38010_prev_spk.hex
fixture_scriptsig: src/test/resources/fixtures/tx_p2pkh_sighash_single_38010_scriptsig.hex
java_fix: LegacySighash.writeInput keeps signing input nSequence for SIGHASH_SINGLE (baseType==1 || signingInput)
follower_notes: Large prevout (85922406945143 sats); signature hashtype byte 0x03; input sequence 0xfffffffd. Live connect proof at 38010; catch-up continued 181 blocks to 38190.
```

### P2WPKH resolved (height 739)

```text
height: 739
block_hash: 000000004cfba4fe6174c546086df7fb52b3d65d44788c0ee8acf436dd28de32
txid: 475ff67b2f2631c6b443635951d81127dcf21898f697d5f7c31e88df836ee756
input_index: 0
spent_script_pubkey: 0014a54e2a1ec06389203887661535ed118b7d053889
failure: (was) unsupported scriptPubKey template: P2WPKH
missing_rule: P2WPKH
python_reference: pybitnode/consensus/script/interpreter.py (is_p2wpkh + bip143 path), sighash.py bip143_sighash
java_module: com.jbitnode.consensus.script.{WitnessSighash,ScriptVerify.verifyP2wpkh}
java_test: com.jbitnode.consensus.script.P2wpkh739RegressionTest, BlockConnectorTest.connectsP2wpkhSpendBlock
java_fix: BIP143 witness verification + BlockConnector spentPrevouts list for full transaction
follower_notes: Block 739 P2WPKH spend verified; P2TR key-path wired via ScriptVerify/Taproot with spentPrevouts
```

## P2P / sync blocker

```text
peer:
command:
datadir:
advertised_start_height:
header_height:
validated_height:
deferred_handshake_sent:
failure:
missing_rule:
python_fix:
test_fixture:
follower_notes:
```

## Usage

1. Sync until the exact blocker (do not skip or assume success).
2. Fill every field you can from live DB/logs (`make java-node-status`, `make java-node-export-snapshots`).
3. Implement the **exact** missing rule with a regression fixture before resuming sync.
4. Export snapshots on a quiescent DB after the fix lands.

See workspace [`AGENTS.md`](../../AGENTS.md) for scout/follower rules and binary gate definition.
