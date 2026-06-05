# Test fixtures (harvested from scout nodes)

Hex and flat-file fixtures copied from Python and TypeScript tests for
independent Java consensus prep (tx parsing, merkle, block storage).

| Fixture | Source |
|---------|--------|
| `blocks/blk00000.dat` | `Nodes/TypeScript/tests/fixtures/blocks/blk00000.dat` (same file as `Nodes/Python/tests/fixtures/blocks/` when present) |
| `block1_wire.hex` … `block5_wire.hex` | Extracted wire payloads from `blk00000.dat` (258-byte testnet4 blocks 1–5) |
| `block1_hash.txt` | `Nodes/TypeScript/tests/consensus.test.ts` — expected block 1 hash |
| `tx_taproot_6975.hex` | `Nodes/TypeScript/tests/script.test.ts` and `Nodes/Python/tests/test_script.py` (`test_real_testnet4_block6975_taproot_keypath_accepted`) |
| `tx_taproot_6975_prev_spk.hex` | Same sources — prevout scriptPubKey for input 0 (64.3 BTC P2TR output) |
| `block_22830.hex` | Local Core RPC `getblock` @ height 22830 (`127.0.0.1:48332`, block hash `00000000000002a4…`) |
| `tx_p2tr_scriptpath_22830.hex` | Same RPC `getrawtransaction` for tx `630725d9…` (block index 2; wtxid `dca917fc…`); cross-checked against `Nodes/Python/tests/test_script.py` (`test_real_testnet4_block22830_taproot_script_path_if_accepted`) |
| `tx_p2tr_scriptpath_22830_prev_spk.hex` | RPC prevout tx `745ba1ca…` vout 0 — P2TR `5120f6b0…` (798 sats, created in same block) |
| `tx_p2tr_scriptpath_22830_prevouts.json` | Prevout amount + scriptPubKey for BIP341/342 sighash (`amount`: 798 sats) |
| `tx_p2tr_scriptpath_22830_witness_0.hex` | Witness stack item 0 — 64-byte Schnorr signature for tapscript path |
| `tx_p2tr_scriptpath_22830_tapscript.hex` | Witness stack item 1 — 0xc0 leaf with Ordinals-style `OP_IF`/`OP_ENDIF` envelope + checksig |
| `tx_p2tr_scriptpath_22830_control_block.hex` | Witness stack item 2 — 33-byte control block (leaf version `0xc0`, internal key `7c6cea56…`) |
| `block_25207.hex` | Local Core RPC `getblock` @ height 25207 (`0000000000000046…da0b`) |
| `tx_op1_25207.hex` | Same RPC `getrawtransaction` for tx `23bf6f59…` (block index 1); cross-checked against `Nodes/Python/tests/test_script.py` (`test_real_testnet4_block25207_bare_op1_and_p2tr_spend_accepted`) |
| `tx_op1_25207_prevouts.json` | All six prevouts: input 0 P2TR 725313 sats; inputs 1–5 bare `OP_1` (`51`) at 1 sat each (created block 25200 tx `056aad3e…`) |
| `tx_op1_25207_prev_spk_input1.hex` | Prevout for input 1 — bare `OP_1` scriptPubKey `51` |
| `tx_op1_25207_scriptsig_input1.hex` | Input 1 scriptSig (empty — bare OP_1 spends require push-only empty scriptSig) |
| `tx_op1_25207_witness_input0.hex` | Input 0 witness item 0 — 64-byte Schnorr signature (P2TR key-path in same tx) |
| `block_27042.hex` | Local Core RPC `getblock` @ height 27042 (`0000000000000048…040b0`) |
| `tx_p2wsh_27042.hex` | Same RPC `getrawtransaction` for tx `0864a600…` (block index 1); no Python scout fixture at this height (nearest P2WSH scout: block 27251 in `Nodes/Python/tests/test_script.py`) |
| `tx_p2wsh_27042_prevouts.json` | Prevout tx `6274e40d…` vout 0 from block 27038 — 94800 sats, native P2WSH `0020379e4b…` |
| `tx_p2wsh_27042_prev_spk.hex` | Prevout scriptPubKey — `OP_0` + 32-byte witness-script hash |
| `tx_p2wsh_27042_witness_0.hex` | Witness stack item 0 — empty push (CHECKMULTISIG dummy) |
| `tx_p2wsh_27042_witness_1.hex` | Witness stack item 1 — DER signature (key 1) |
| `tx_p2wsh_27042_witness_2.hex` | Witness stack item 2 — DER signature (key 2) |
| `tx_p2wsh_27042_witness_script.hex` | Witness stack item 3 — redeem script `OP_2 <pk1> <pk2> OP_2 OP_CHECKMULTISIG` (2-of-2 multisig; SHA256 matches program hash) |
| `block_27251.hex` | Local Core RPC `getblock` @ height 27251 (`00000000e32a5d69…8b9c78`) |
| `tx_p2wsh_ifelse_27251.hex` | `Nodes/Python/tests/test_script.py` (`test_real_testnet4_block27251_p2wsh_if_else_multisig_accepted`); cross-checked against Core block verbose tx `a66a655d…` |
| `tx_p2wsh_ifelse_27251_prevouts.json` | Three prevouts (10000 / 10000 / 79761 sats), same P2WSH program `0020e51d37e1…` on all inputs |
| `tx_p2wsh_ifelse_27251_prev_spk.hex` | Prevout scriptPubKey — native P2WSH `OP_0` + SHA256(witnessScript) |
| `tx_p2wsh_ifelse_27251_witness_input{N}_{W}.hex` | Per-input witness stack (3 items each): DER sig, branch selector `0x01`, witnessScript |
| `tx_p2wsh_ifelse_27251_witness_script.hex` | Witness stack item 2 (input 0) — `OP_IF <pk> OP_CHECKSIG OP_ELSE OP_2 <pk>×3 OP_3 OP_CHECKMULTISIG OP_ENDIF` |
| `block_27807.hex` | Local Core RPC `getblock` @ height 27807 (`000000000024e0d4…87ffc`) |
| `tx_p2sh_ifelse_sha256_27807.hex` | `Nodes/Python/tests/test_script.py` (`test_real_testnet4_block27807_p2sh_if_else_sha256_accepted`); cross-checked against Core block verbose tx `d1a68c8f…` (index 1) |
| `tx_p2sh_ifelse_sha256_27807_prevouts.json` | Prevout tx `52ceb80c…` vout 0 — 489171 sats, P2SH `a914d569…` |
| `tx_p2sh_ifelse_sha256_27807_prev_spk.hex` | Prevout scriptPubKey — bare P2SH `OP_HASH160` + `HASH160(redeemScript)` |
| `tx_p2sh_ifelse_sha256_27807_scriptsig.hex` | Full input-0 scriptSig (DER sig, preimage push, `OP_0` branch selector, redeemScript push) |
| `tx_p2sh_ifelse_sha256_27807_scriptsig_sig.hex` | scriptSig item 0 — 71-byte DER+hashtype signature |
| `tx_p2sh_ifelse_sha256_27807_scriptsig_preimage.hex` | scriptSig item 1 — ASCII preimage `810899055` (9 bytes) |
| `tx_p2sh_ifelse_sha256_27807_scriptsig_branch.hex` | scriptSig item 2 — empty (`OP_0`, takes `OP_ELSE` hashlock branch) |
| `tx_p2sh_ifelse_sha256_27807_redeem_script.hex` | scriptSig item 3 — full redeem script (114 bytes) |
| `tx_p2sh_ifelse_sha256_27807_redeem_if_branch.hex` | Inactive `OP_IF` body — `PUSH(2) OP_SWAP OP_SUB PUSH(1) OP_GREATERTHAN` (numeric path) |
| `tx_p2sh_ifelse_sha256_27807_redeem_else_branch.hex` | Active `OP_ELSE` body — `OP_SHA256 PUSH(32) OP_EQUALVERIFY` |
| `tx_p2sh_ifelse_sha256_27807_sha256_digest.hex` | `SHA256(preimage)` — `6009b3c19a19f84e6b5208493a411939d0f49a90b462aa55b5b32466602c80b4` |
| `tx_p2sh_ifelse_sha256_27807_branch.json` | Machine-readable IF/ELSE branch metadata (height, txid, branch selector, python_test name) |
| `block_27815.hex` | Local Core RPC `getblock` @ height 27815 (`00000000f649f430…1b250`) |
| `tx_p2sh_ifelse_numeric_27815.hex` | `Nodes/Python/tests/test_script.py` (`test_real_testnet4_block27815_p2sh_if_else_numeric_branch_accepted`); cross-checked against Core block verbose tx `2a691884…` (index 1) |
| `tx_p2sh_ifelse_27815.hex` | Alias of `tx_p2sh_ifelse_numeric_27815.hex` (regression-test naming parity with 27807) |
| `tx_p2sh_ifelse_numeric_27815_prevouts.json` | Prevout tx `f0c81358…` vout 0 — 740492 sats, P2SH `a9149bd8…` |
| `tx_p2sh_ifelse_numeric_27815_prev_spk.hex` | Prevout scriptPubKey — bare P2SH `OP_HASH160` + `HASH160(redeemScript)` |
| `tx_p2sh_ifelse_27815_prev_spk.hex` | Alias of numeric prev_spk fixture |
| `tx_p2sh_ifelse_numeric_27815_scriptsig.hex` | Full input-0 scriptSig (DER sig, operand push `2001`, `OP_1` branch selector, redeemScript push) |
| `tx_p2sh_ifelse_numeric_27815_scriptsig_sig.hex` | scriptSig item 0 — 72-byte DER+hashtype signature |
| `tx_p2sh_ifelse_numeric_27815_scriptsig_operand.hex` | scriptSig item 1 — LE scriptnum push `d107` (2001) |
| `tx_p2sh_ifelse_numeric_27815_scriptsig_branch.hex` | scriptSig item 2 — `OP_1` (takes IF numeric path) |
| `tx_p2sh_ifelse_numeric_27815_redeem_script.hex` | scriptSig item 3 — full redeem script (114 bytes) |
| `tx_p2sh_ifelse_numeric_27815_redeem_if_branch.hex` | Active `OP_IF` body — `PUSH(2024) OP_SWAP OP_SUB PUSH(18) OP_GREATERTHAN OP_VERIFY` |
| `tx_p2sh_ifelse_numeric_27815_redeem_else_branch.hex` | Inactive `OP_ELSE` body — `OP_SHA256 PUSH(32) OP_EQUALVERIFY` |
| `tx_p2sh_ifelse_numeric_27815_branch.json` | Machine-readable IF/ELSE branch metadata (height, txid, operand 2001 vs constant 2024, python_test name) |
| `block_27840.hex` | Local Core RPC `getblock` @ height 27840 (`000000000000004b…db9bc`) |
| `tx_bare_multisig_27840.hex` | `Nodes/Python/tests/test_script.py` (`test_real_testnet4_block27840_bare_multisig_accepted`); cross-checked against Core block verbose tx `f2b2a965…` (index 1) |
| `tx_bare_multisig_27840_prevouts.json` | Prevout tx `65d9e145…` vout 0 — 477645 sats, bare 2-of-3 multisig scriptPubKey |
| `tx_bare_multisig_27840_prev_spk.hex` | Prevout scriptPubKey — `OP_2` + three `PUSH(65)` uncompressed pubkeys + `OP_3 OP_CHECKMULTISIG` (201 bytes) |
| `tx_bare_multisig_27840_scriptsig.hex` | Full input-0 scriptSig (147 bytes) |
| `tx_bare_multisig_27840_scriptsig_dummy.hex` | scriptSig item 0 — empty (`OP_0`, CHECKMULTISIG dummy) |
| `tx_bare_multisig_27840_scriptsig_sig1.hex` | scriptSig item 1 — 72-byte DER+hashtype signature |
| `tx_bare_multisig_27840_scriptsig_sig2.hex` | scriptSig item 2 — 72-byte DER+hashtype signature |
| `tx_bare_multisig_27840_meta.json` | Machine-readable bare-multisig metadata (height, txid, prevout, python_test name) |
| `block_31842.hex` | Local Core RPC `getblock` @ height 31842 (`0000000000000042…dd51`) |
| `tx_p2wsh_op1_only_31842.hex` | `Nodes/Python/tests/test_script.py` (`test_real_testnet4_block31842_p2wsh_op1_only_witness_accepted`); cross-checked against Core block verbose tx `b6dc5519…` (index 1) |
| `tx_p2wsh_op1_only_31842_prevouts.json` | Prevout tx `4cb3e118…` vout 1 — 69179 sats, native P2WSH `00204ae815…` |
| `tx_p2wsh_op1_only_31842_prev_spk.hex` | Prevout scriptPubKey — `OP_0` + SHA256(`OP_1`) |
| `tx_p2wsh_op1_only_31842_witness_0.hex` | Witness stack item 0 — witnessScript only (`51`, len-1 stack) |
| `tx_p2wsh_op1_only_31842_witness_script.hex` | Alias of witness item 0 — single-byte `OP_1` witness script |
| `tx_p2wsh_op1_only_31842_meta.json` | Machine-readable P2WSH len-1 metadata (height, txid, python_test name) |
| `block_32712.hex` | Local Core RPC `getblock` @ height 32712 (`0000000000000013…a6a3`) |
| `tx_p2tr_tapscript_numequal_32712.hex` | `Nodes/Python/tests/test_script.py` (`test_real_testnet4_block32712_p2tr_tapscript_checksigadd_2of3_numequal_accepted`); cross-checked against Core block verbose tx `6b586a4f…` (index 1) |
| `tx_p2tr_tapscript_numequal_32712_prevouts.json` | Prevout tx `ad635a2c…` vout 1 — 50000 sats, P2TR `51203a6c36…` |
| `tx_p2tr_tapscript_numequal_32712_prev_spk.hex` | Prevout scriptPubKey — P2TR output key |
| `tx_p2tr_tapscript_numequal_32712_witness_{0..4}.hex` | Script-path stack: empty, sig1, sig2, tapscript, control block |
| `tx_p2tr_tapscript_numequal_32712_tapscript.hex` | Witness item 3 — 2-of-3 tapscript ending `OP_2 OP_NUMEQUAL` |
| `tx_p2tr_tapscript_numequal_32712_control_block.hex` | Witness item 4 — 33-byte control block (`0xc0` + internal key + merkle path) |
| `tx_p2tr_tapscript_numequal_32712_meta.json` | Machine-readable tapscript NUMEQUAL metadata (height, txid, opcode sequence, python_test name) |
| `block_32868.hex` | Local Core RPC `getblock` @ height 32868 (`0000000000000060…35ac2`) |
| `tx_p2wsh_cltv_32868.hex` | Same RPC `getrawtransaction` for tx `8add2663…` (block index 8); live Java blocker @32867→32868; no dedicated Python block32868 test yet (related: `test_p2wsh_cltv_roundtrip`, `test_real_testnet4_block30695_p2wsh_if_hashlock_op_size_accepted`) |
| `tx_p2wsh_cltv_32868_prevouts.json` | Prevout tx `9f8ad847…` vout 0 — 10000 sats, native P2WSH `00201b3129…` (created block 32861) |
| `tx_p2wsh_cltv_32868_prev_spk.hex` | Prevout scriptPubKey — `OP_0` + SHA256(witnessScript) |
| `tx_p2wsh_cltv_32868_witness_{0..3}.hex` | Witness stack: DER sig, compressed pubkey, empty branch selector (`OP_0` → ELSE/CLTV path), witnessScript |
| `tx_p2wsh_cltv_32868_witness_script.hex` | Full witness script — `OP_IF` hashlock (`OP_SIZE`/`OP_SHA256`) / `OP_ELSE` CLTV / `OP_ENDIF OP_EQUALVERIFY OP_CHECKSIG` |
| `tx_p2wsh_cltv_32868_witness_script_if_branch.hex` | Inactive IF body — `OP_SIZE PUSH(1) OP_EQUALVERIFY OP_SHA256 PUSH(32) OP_EQUALVERIFY OP_DUP OP_HASH160 PUSH(20)` |
| `tx_p2wsh_cltv_32868_witness_script_else_branch.hex` | Active ELSE body — `PUSH(1719894876) OP_CHECKLOCKTIMEVERIFY OP_DROP OP_DUP OP_HASH160 PUSH(20)` |
| `tx_p2wsh_cltv_32868_witness_script_post_endif.hex` | Post-`OP_ENDIF` tail — `OP_EQUALVERIFY OP_CHECKSIG` |
| `tx_p2wsh_cltv_32868_branch.json` | Machine-readable IF/ELSE branch metadata (branch selector, locktime 1719894876, python_test references) |
| `tx_p2wsh_cltv_32868_meta.json` | Machine-readable P2WSH CLTV metadata (height, txid, opcode sequence, missing_rule) |
| `block_33500.hex` | Local Core RPC `getblock` @ height 33500 (`0000000000000034…56c4`) |
| `tx_p2sh_p2wsh_op1_only_33500.hex` | `Nodes/Python/tests/test_script.py` (`test_real_testnet4_block33500_p2sh_p2wsh_op1_only_witness_accepted`); cross-checked against Core block verbose tx `f89a4629…` (index 3) |
| `tx_p2sh_p2wsh_op1_only_33500_prevouts.json` | Prevout tx `c240434e…` vout 0 — 62819 sats, P2SH `a91472c4…` |
| `tx_p2sh_p2wsh_op1_only_33500_prev_spk.hex` | Prevout scriptPubKey — bare P2SH `OP_HASH160` + `HASH160(nested P2WSH program)` |
| `tx_p2sh_p2wsh_op1_only_33500_scriptsig.hex` | Input-0 scriptSig — push-only redeem script `OP_0` + 32-byte witness-script hash (nested P2WSH program) |
| `tx_p2sh_p2wsh_op1_only_33500_witness_0.hex` | Witness stack item 0 — witnessScript only (`51`, len-1 stack on nested path) |
| `tx_p2sh_p2wsh_op1_only_33500_witness_script.hex` | Alias of witness item 0 — single-byte `OP_1` witness script |
| `tx_p2sh_p2wsh_op1_only_33500_meta.json` | Machine-readable P2SH→P2WSH len-1 metadata (height, txid, python_test name) |
| `block_38010.hex` | Local Core RPC `getblock` @ height 38010 (`0000000000000012…a626`) |
| `tx_p2pkh_sighash_single_38010.hex` | `Nodes/Python/tests/test_script.py` (`test_real_testnet4_block38010_p2pkh_sighash_single_sequence_accepted`); cross-checked against Core block verbose tx `ba32ba8e…` (index 1) |
| `tx_p2pkh_sighash_single_38010_prevouts.json` | Prevout tx `95fe33f9…` vout 0 — 85922406945143 sats, P2PKH `76a9149ec1…` |
| `tx_p2pkh_sighash_single_38010_prev_spk.hex` | Prevout scriptPubKey — legacy P2PKH `OP_DUP OP_HASH160 … OP_EQUALVERIFY OP_CHECKSIG` |
| `tx_p2pkh_sighash_single_38010_scriptsig.hex` | Input-0 scriptSig — 71-byte DER+SIGHASH_SINGLE (0x03) + 33-byte compressed pubkey |
| `tx_p2pkh_sighash_single_38010_meta.json` | Machine-readable P2PKH SIGHASH_SINGLE metadata (height, txid, nSequence `0xfffffffd`, python_test name) |
| `block_41700.hex` | Local Core RPC `getblock` @ height 41700 (`000000000013ae97…dddbbd`) |
| `tx_bare_op1_push_41700.hex` | Same RPC block verbose tx `4a89d5d1…` (index 1); live Java bare OP_1 + push @41700 |
| `tx_bare_op1_push_41700_prev_spk.hex` | Prevout scriptPubKey `51024e73` (OP_1 + 2-byte push) |
| `tx_bare_op1_push_41700_scriptsig.hex` | Input-0 scriptSig (empty) |
| `block_44295.hex` | Local Core RPC `getblock` @ height 44295 (`00000000cb123445…e9d20`) |
| `tx_p2tr_scriptpath_44295.hex` | Same RPC block verbose tx `cb835ce1…` (index 15); live Java P2TR script-path @44295 (OP_NIP fix) |
| `tx_p2tr_scriptpath_44295_prevouts.json` | Prevout tx `2c716236…` vout 0 — 716 sats, P2TR `5120346d…` (same-block coinbase child) |
| `tx_p2tr_scriptpath_44295_prev_spk.hex` | Prevout scriptPubKey — P2TR output key |
| `tx_p2tr_scriptpath_44295_witness_{0..2}.hex` | Script-path stack: 64-byte Schnorr sig, tapscript (199 B), 33-byte control block |
| `tx_p2tr_scriptpath_44295_tapscript.hex` | Witness item 1 — `PUSH(32)` x-only key + `OP_CHECKSIGVERIFY` + `OP_0 OP_IF` envelope + `OP_ENDIF` + `PUSH(8) OP_NIP` |
| `tx_p2tr_scriptpath_44295_control_block.hex` | Witness item 2 — leaf version `0xc0`, internal key `6a446563…`, zero merkle siblings |
| `tx_p2tr_scriptpath_44295_meta.json` | Machine-readable P2TR script-path metadata (tapleaf hash, opcode sequence, java_blocker) |
| `block_46599.hex` | Local Core RPC `getblock` @ height 46599 (`0000000000000019…fc7e8`) |
| `tx_p2tr_scriptpath_46599.hex` | Same RPC block verbose tx `d1670431…` (index 18); live Java P2TR script-path @46599 (castToBool fix) |
| `tx_p2tr_scriptpath_46599_prevouts.json` | Prevout tx `f50a140a…` vout 0 — 716 sats, P2TR `5120a23f…` (same-block coinbase child) |
| `tx_p2tr_scriptpath_46599_prev_spk.hex` | Prevout scriptPubKey — P2TR output key |
| `tx_p2tr_scriptpath_46599_witness_{0..2}.hex` | Script-path stack: 64-byte Schnorr sig, tapscript (199 B), 33-byte control block |
| `tx_p2tr_scriptpath_46599_tapscript.hex` | Witness item 1 — `PUSH(32)` x-only key + `OP_CHECKSIGVERIFY` + `OP_0 OP_IF` envelope + `OP_ENDIF` + `PUSH(8) OP_NIP` |
| `tx_p2tr_scriptpath_46599_control_block.hex` | Witness item 2 — leaf version `0xc0`, internal key `bafdef44…`, zero merkle siblings |
| `tx_p2tr_scriptpath_46599_meta.json` | Machine-readable P2TR script-path metadata (tapleaf hash, opcode sequence, java_blocker) |
| `block_46779.hex` | Local Core RPC `getblock` @ height 46779 (`0000000000000002…dba58`) |
| `tx_p2wsh_size_lessthan_46779.hex` | Same RPC block verbose tx `fb9b18c7…` (index 1, input 0); live Java P2WSH blocker @46779 |
| `tx_p2wsh_size_lessthan_46779_prevouts.json` | Prevout tx `fb7659cf…` vout 0 — 1143 sats, native P2WSH `0020359eaf…` (created block 46682) |
| `tx_p2wsh_size_lessthan_46779_prev_spk.hex` | Prevout scriptPubKey — `OP_0` + SHA256(witnessScript) |
| `tx_p2wsh_size_lessthan_46779_scriptsig.hex` | Input-0 scriptSig (empty) |
| `tx_p2wsh_size_lessthan_46779_witness_{0..1}.hex` | Witness stack: DER sig, witnessScript |
| `tx_p2wsh_size_lessthan_46779_witness_script.hex` | Witness script — `OP_SIZE PUSH(1) OP_LESSTHAN OP_VERIFY OP_CODESEPARATOR PUSH(33) OP_CHECKSIG` |
| `tx_p2wsh_size_lessthan_46779_meta.json` | Machine-readable P2WSH SIZE/LESSTHAN metadata (height, txid, opcode sequence, java_blocker) |
| `block_51340.hex` | Local Core RPC `getblock` @ height 51340 (`0000000000895162…ced81e`) |
| `tx_p2sh_add_51340.hex` | Same RPC block verbose tx `03911305…` (index 2, input 0); live Java P2SH blocker @51340 |
| `tx_p2sh_add_51340_prevouts.json` | Prevout tx `9497c5cf…` vout 0 — 1500 sats, P2SH `a914c464…` |
| `tx_p2sh_add_51340_prev_spk.hex` | Prevout scriptPubKey — bare P2SH `OP_HASH160` + `HASH160(redeemScript)` |
| `tx_p2sh_add_51340_scriptsig.hex` | Input-0 scriptSig — `OP_1 OP_2` pushes plus redeem script push (`515203935387`) |
| `tx_p2sh_add_51340_redeem_script.hex` | Redeem script — `OP_ADD OP_3 OP_EQUAL` (`935387`; stack `[1,2]` → `3 == 3`) |
| `tx_p2sh_add_51340_meta.json` | Machine-readable P2SH OP_ADD metadata (height, txid, opcode sequence, java_blocker) |

## Scout above 38191 (2026-05-25)

Grep of `Nodes/Python/tests/test_script.py` for `test_real_testnet4_block38*` and
`test_real_testnet4_block39*` with height **> 38191**:

**No Python scout fixtures above 38010** (live-only blockers 38191–44295 harvested via Core RPC).

| Height | Python test | missing_rule (scout summary) | Java fixture prefix | Status |
|--------|-------------|------------------------------|---------------------|--------|
| 44295 | — | P2TR script-path OP_NIP (witness len 3; CHECKSIGVERIFY + IF envelope + OP_NIP) | `tx_p2tr_scriptpath_44295*` | **passed** — live connect @44295 after OP_NIP tapscript fix |
| 46599 | — | P2TR script-path castToBool terminal stack (same opcode template as 44295; terminal item 0x809e…) | `tx_p2tr_scriptpath_46599*` | **passed** — live connect @46599 after castToBool Core semantics fix |
| 46779 | — | P2WSH witness script OP_SIZE + OP_LESSTHAN + OP_VERIFY + OP_CODESEPARATOR (first non-coinbase spend; not P2TR) | `tx_p2wsh_size_lessthan_46779*` | **passed** — live connect @46779 after OP_LESSTHAN + OP_CODESEPARATOR fix |
| 51340 | — | P2SH redeem `OP_ADD OP_3 OP_EQUAL` (tx[2] input 0; tx[1] P2WPKH passes) | `tx_p2sh_add_51340*` | **passed** — live connect @51340 after OP_ADD in legacy P2SH redeem |

Highest Python `test_real_testnet4_block*` height: **38010**
(`test_real_testnet4_block38010_p2pkh_sighash_single_sequence_accepted`). Live
blockers @38191 (P2SH CLTV), @41700 (bare OP_1 + push), @44295 (P2TR
script-path OP_NIP), and @46599 (P2TR script-path) have Core RPC fixtures at
`127.0.0.1:48332` but no Python scout tests.

Do not treat these as live chain truth; they are regression anchors for parsing,
merkle verification, **P2TR key-path script verification** (Python `dd65c78`), and
**P2TR script-path / BIP342 tapscript** (block 22830 live blocker), **bare
OP_1 legacy output template** (block 25207 live blocker), and **native P2WSH
witness v0 script hash** (block 27042 live blocker), and **P2WSH witness-script
OP_IF / OP_ELSE / OP_ENDIF + 2-of-3 CHECKMULTISIG** (block 27251 live blocker;
branch selector `0x01` takes IF single-sig path), and **P2SH redeem
OP_IF / OP_ELSE with OP_SHA256 hashlock + post-ENDIF CHECKSIG** (block 27807 live
blocker; branch selector `OP_0` takes ELSE SHA256 path; preimage `810899055`), and
**P2SH redeem OP_IF numeric branch with OP_SWAP / OP_SUB / OP_GREATERTHAN** (block
27815 live blocker; branch selector `OP_1` takes IF path; scriptSig operand `2001` vs
redeem constant `2024`, threshold `18`), and **bare legacy 2-of-3 CHECKMULTISIG**
(block 27840 live blocker; scriptPubKey `OP_2` + three uncompressed pubkeys + `OP_3
OP_CHECKMULTISIG`; scriptSig `OP_0` dummy + two DER signatures), and **native P2WSH
witness-script-only len-1 stack** (block 31842 live blocker; witness stack
`[witnessScript]` where script is single `OP_1`; minimum length 1 not 2), and
**P2TR script-path 2-of-3 tapscript with CHECKSIGADD + OP_2 OP_NUMEQUAL** (block
32712 live blocker; tapscript ends with exact-count numeric equality not
OP_GREATERTHANOREQUAL), and **native P2WSH IF/ELSE witness script with
OP_CHECKLOCKTIMEVERIFY on the ELSE branch** (block 32868 live blocker; branch selector
`OP_0` takes CLTV path; witnessScript locktime push `1719894876` matches tx
`nLockTime`; same IF/SHA256 + ELSE/CLTV template family as Python block 30695), and
**P2SH-wrapped P2WSH witness-script-only len-1 stack**
(block 33500 scout path; nested segwit must accept `[witnessScript]` where script is
single `OP_1`, same edge as native P2WSH @31842), and **P2PKH legacy sighash with
SIGHASH_SINGLE and non-zero nSequence** (block 38010 scout path; signing input
sequence `0xfffffffd` must participate in RawSignatureHash, not be zeroed), and
**P2TR script-path with CHECKSIGVERIFY + OP_IF envelope and OP_NIP** (block 44295 live
blocker; witness stack `[sig, tapscript, control_block]`; tapscript ends with
`PUSH(8) OP_NIP` after skipped IF branch), and **P2TR script-path @46599**
(same tapscript opcode template as 44295 with different internal key; live stall
after OP_NIP fix cleared 44295→46598), and **P2WSH witness script with OP_SIZE,
OP_LESSTHAN, OP_VERIFY, and OP_CODESEPARATOR** (block 46779 live blocker; witness
stack `[sig, witnessScript]`; compares stack top size against 80 before checksig), and
**P2SH redeem with OP_ADD numeric stack arithmetic** (block 51340 live blocker; scriptSig
pushes `OP_1 OP_2` onto stack before redeem `OP_ADD OP_3 OP_EQUAL`; prevout 1500 sats).
