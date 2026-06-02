# Blocker ledger (testnet4 scout)

Searchable handoff for follower ports. Canonical truth remains code, tests, live DB, and reproducible sync commands — not this file alone.

**Live status:**

```bash
cd PythonNode
.venv/bin/pybitnode-db --state-path ./data/chainstate-rocksdb
tail -n 40 sync_batch_run.log
```

**Resume sync (single writer; do not overlap with an active batch loop):**

```bash
MAX_OUTBOUND_PEERS=1 PARALLEL_BLOCK_DOWNLOADS=0 SKIP_GETADDR=1 \
  .venv/bin/pybitnode-sync --datadir ./data \
  --blocks-target 136343 --blocks-max 200 --no-header-refresh \
  --peers 89.167.10.150:48333
```

---

## Cleared: height 52497 — P2TR tapscript `OP_SIZE`

| Field | Value |
|-------|-------|
| height | 52497 |
| block_hash | `0000000000491575f9e5d7d809369231c77a968de544b22ecc15a7e9716d47c7` |
| txid | `c62c3c4c40feb1850f17ccbd33693c26d3ce83910c5a3fe5c058f30ecec8c6e7` |
| input_index | 0 |
| spent_script_pubkey | P2TR script-path (`512031b46e4751f440b63193188b859158ab5560beac41d33a3251cbfa88a1192986`) |
| failure | `script verification failed for input 0`; Java fixture replay identified tapscript `OP_SIZE` in a dual SHA256 16-byte preimage + 2-of-2 Schnorr script path. |
| missing_rule | BIP342 tapscript `OP_SIZE` (`0x82`). Tapscript must push the byte length of the top stack item as a minimally encoded ScriptNum without consuming that item. |
| python_fix | Add `OP_SIZE` handling to `_evaluate_tapscript()` using the same ScriptNum encoding semantics as the legacy script path. No validation skip or P2TR bypass was added. |
| test_fixture | `tests/fixtures/tx_p2tr_tapscript_size_52497*.{hex,json}` and `tests/test_script.py` -> `test_real_testnet4_block52497_p2tr_tapscript_size_accepted`. |
| follower_notes | Port tapscript `OP_SIZE` as a normal stack-inspection opcode. Java fixtures under `tx_p2tr_tapscript_size_52497*` supplied the handoff bytes; Python independently validates the spend. Proof chunk connected through height 52996 after the fix. |

---

## Cleared: height 52024 — P2TR tapscript `OP_SHA256`

| Field | Value |
|-------|-------|
| height | 52024 |
| block_hash | `000000000004de650965892b4cc23811bfed92413f83e0c3acbe176e31846be6` |
| txid | `d57def620b54b9f2f31ca5c4356be2e79c15be29233151186c6944b65bbd663d` |
| input_index | 0 |
| spent_script_pubkey | P2TR script-path (`51208633e66a528c86ba924ac2cbe60eb53e793fead9e0df3e10982c886f102d4b64`) |
| failure | `script verification failed for input 0`; replay of the tapscript path showed missing tapscript `OP_SHA256` handling while the leaf starts with opcode `0xa8`. |
| missing_rule | BIP342 tapscript hash opcode `OP_SHA256` (`0xa8`). The leaf is `OP_SHA256 <32-byte hash> OP_EQUALVERIFY <x-only pubkey> OP_CHECKSIG`; tapscript must pop the 32-byte preimage witness item, push its SHA256 digest, compare it, and then verify the Schnorr signature. |
| python_fix | Add `OP_SHA256` handling to `_evaluate_tapscript()` using the same consensus hash primitive as the legacy script path. No validation skip or P2TR bypass was added. |
| test_fixture | `tests/fixtures/tx_p2tr_tapscript_sha256_52024*.{hex,json}` and `tests/test_script.py` -> `test_real_testnet4_block52024_p2tr_tapscript_sha256_accepted`. |
| follower_notes | Port tapscript `OP_SHA256` as a normal stack hash opcode, not as a special-case success for this leaf. Java already has equivalent fixture coverage under `tx_p2tr_tapscript_sha256_52024*`. |

---

## Cleared: height 51340 — P2SH `OP_ADD`

| Field | Value |
|-------|-------|
| height | 51340 |
| block_hash | `00000000008951628db430d112a92f8dd350a1eb3681410314c0ca9cf2ced81e` |
| txid | `03911305033a5aa73d7d730f16ba63b53582c6a6570d8d9f86e2f2b76fa2cbc3` |
| input_index | 0 |
| spent_script_pubkey | P2SH (`a914c464d0169c41085bcf10e3ab2cf83e74859d640b87`) |
| failure | `script verification failed for input 0`; read-only replay of the redeem path showed `unsupported opcode 0x93`. |
| missing_rule | Legacy script arithmetic `OP_ADD` (`0x93`) during P2SH redeem-script evaluation. The `scriptSig` pushes `1`, `2`, and redeem script `935387` (`OP_ADD OP_3 OP_EQUAL`), so the redeem script must pop `2` and `1`, push script number `3`, and compare it to `OP_3`. |
| python_fix | Add legacy `OP_ADD` to `evaluate_script()` using existing ScriptNum operand decoding and 5-byte result encoding for arithmetic outputs. No validation skip or template bypass was added. |
| test_fixture | `tests/fixtures/tx_p2sh_add_51340*.{hex,json}` and `tests/test_script.py` -> `test_real_testnet4_block51340_p2sh_op_add_accepted`; synthetic coverage in `test_legacy_script_op_add_semantics_and_underflow`. |
| follower_notes | Port `OP_ADD` as a legacy numeric opcode with normal stack-underflow and ScriptNum operand-size failures. Arithmetic results may encode wider than the 4-byte operand limit; later numeric consumers enforce their own operand limits. |

---

## Cleared: height 46779 — P2WSH `OP_CODESEPARATOR`

| Field | Value |
|-------|-------|
| height | 46779 |
| block_hash | `0000000000000002ed00d479b1f8f4dc5bc1d033eb6d13c3b653010ef5bdba58` |
| txid | `fb9b18c782c2b45ccb77b4e22cbdf8b8cb1b8bf603289937968da52475e28aa5` |
| input_index | 0 |
| spent_script_pubkey | P2WSH (`0020359eaf2fdfc8952db69827596cf6fe9093f203bdbbd83749a9953f58a3a93829`) |
| failure | `script verification failed for input 0`; read-only replay showed `unsupported opcode 0xab` while evaluating the witness script. |
| missing_rule | SegWit v0 / legacy script `OP_CODESEPARATOR` semantics. The witness script is `OP_SIZE 80 OP_LESSTHAN OP_CODESEPARATOR <pubkey> OP_CHECKSIG`; the executed separator is not a terminal opcode and must update the active subscript used by the following ECDSA signature check. |
| python_fix | Implement `OP_CODESEPARATOR` in `evaluate_script()` by tracking the byte offset after the last executed separator, then pass that active subscript to ECDSA `OP_CHECKSIG` and `OP_CHECKMULTISIG`. No validation skip or template bypass was added. |
| test_fixture | `tests/test_script.py` -> `test_real_testnet4_block46779_p2wsh_codeseparator_accepted`. |
| follower_notes | Port this as sighash-subscript behavior for legacy/SegWit v0 script evaluation. For the block-46779 witness script, the signature commits to `<pubkey> OP_CHECKSIG` after the executed `OP_CODESEPARATOR`; hashing the full witness script fails. Keep tapscript `OP_CODESEPARATOR` position handling separate. |

---

## Cleared: height 46599 — script truthiness with `0x80` prefix

| Field | Value |
|-------|-------|
| height | 46599 |
| block_hash | `00000000000000193205628255bc2004082bc1a83ba337f79fe4f591f99fc7e8` |
| txid | `d16704313ed3cd64f082c92b40d72ccf5ede213f739c3f217caf59f1ca6c962f` |
| input_index | 0 |
| spent_script_pubkey | P2TR script-path (`5120a23f913d1fc28f07abbcc72218ed00e0d149287b9e86187e54b0c6340ce584b3`) |
| failure | `script verification failed for input 0` |
| missing_rule | Bitcoin script boolean casting treats only the final byte `0x80` of an otherwise-zero vector as false negative zero. The tapscript executed successfully and left one stack item, `809e000000000000`, which Python incorrectly treated as false because `_cast_to_bool()` rejected any nonzero byte equal to `0x80`, even when it was not the final sign byte. |
| python_fix | Update `_cast_to_bool()` to return false for `0x80` only when that nonzero byte is the final byte. Earlier `0x80` bytes, and any later nonzero bytes, make the vector truthy. No validation skip or template bypass was added. |
| test_fixture | `tests/test_script.py` -> `test_real_testnet4_block46599_p2tr_tapscript_truthy_0x80_prefix_accepted` and `test_script_bool_cast_only_treats_final_0x80_as_negative_zero`. |
| follower_notes | Port the script truthiness rule exactly in both legacy and tapscript paths: scan bytes from low to high; the first nonzero byte is false only if it is the last byte and equals `0x80`, otherwise it is true. This is not an `OP_NIP` issue, although the leaf also ends with `OP_NIP`. |

---

## Cleared: height 44295 — P2TR tapscript `OP_NIP`

| Field | Value |
|-------|-------|
| height | 44295 |
| block_hash | `00000000cb1234452fea6487434e627a26825942af62111d9dba1978ae1e9d20` |
| txid | `cb835ce1d726993515c27df94a358bf327b03323fb0e82c823c1faab31b28786` |
| input_index | 0 |
| spent_script_pubkey | P2TR script-path (`5120346d44aef23b267970d8c090d8fed28e2dcf772b609f566cdc56e108ff84118a`) |
| failure | `script verification failed for input 0` |
| missing_rule | Tapscript used `OP_NIP` (`0x77`) near the end of the leaf. Bitcoin script `OP_NIP` removes the second item from the top of the stack and leaves the top item; it fails when fewer than two stack items are present. |
| python_fix | Add `OP_NIP` to script opcode constants and implement the same stack semantics in both `_evaluate_tapscript()` and the legacy `evaluate_script()` path, with explicit stack-underflow failure. No validation skip or template bypass was added. |
| test_fixture | `tests/test_script.py` -> `test_real_testnet4_block44295_p2tr_tapscript_op_nip_accepted`, plus synthetic tapscript success/underflow and legacy semantics tests containing `op_nip` in their names. |
| follower_notes | Port `OP_NIP` as a stack-manipulation opcode, not as a tapscript-only success rule. In tapscript and legacy script, require at least two stack items, delete stack item `-2`, and continue evaluating the remaining script normally. |

---

## Cleared: height 41700 — unknown native SegWit v1 program

| Field | Value |
|-------|-------|
| height | 41700 |
| block_hash | `000000000013ae973ef034970b5a6c234338d27a0f6ed573913a6de6c9dddbbd` |
| txid | `4a89d5d1568b5cbcb4118559cb65d2357657d361a41cd96b14e74ed3d065975c` |
| input_index | 0 |
| spent_script_pubkey | native SegWit v1, non-P2TR 2-byte program (`51024e73`) |
| failure | `unsupported scriptPubKey template` |
| missing_rule | BIP141 reserved witness-program semantics for native SegWit v1 programs that are **not** BIP341 P2TR (`OP_1` + 32-byte program). The spend has empty `scriptSig` and no witness stack; Python incorrectly treated the v1/2-byte program as an unsupported template instead of accepting the reserved witness program without script execution. |
| python_fix | Allow witness version 1 non-P2TR programs through `verify_transaction_input()` and accept them in `verify_script()` when the native witness `scriptSig` is empty. P2TR (`OP_1` + 32-byte program), witness v0, and witness v2+ behavior remain separate; unsupported v2+ still reports `unsupported witness program version N`. |
| test_fixture | `tests/test_script.py` -> `test_real_testnet4_block41700_unknown_witness_v1_program_accepted` and `test_unknown_witness_v1_program_rejects_non_empty_script_sig` |
| follower_notes | Port reserved witness v1 non-P2TR semantics directly from BIP141/BIP341. Do not treat Python or any follower as an oracle; independently verify that native v1 non-32-byte programs require empty `scriptSig` and do not execute legacy/tapscript opcodes. |

---

## Cleared: height 38191 — P2SH CLTV no-op on tx nVersion 1

| Field | Value |
|-------|-------|
| height | 38191 |
| block_hash | `000000000000000c7f9078cb5991c06bc4d5698471920dee73aa93de7579c8f7` |
| txid | `4e477ff4e1a12fd78e76fb7dec0d0fcd6fb0372f757fabceb83fdb041c6ee9b6` |
| input_index | 0 |
| spent_script_pubkey | P2SH (`a914bbe352f1c5366dd92bcae64f4de33e6b56df7e3d87`) |
| failure | `script verification failed for input 0` |
| missing_rule | BIP65 `OP_CHECKLOCKTIMEVERIFY` must be a no-op when the spending transaction has `nVersion < 2`. The redeem script is `30000 OP_CHECKLOCKTIMEVERIFY OP_DROP <pubkey> OP_CHECKSIG`; Python incorrectly rejected version-1 spends before verifying the remaining script. |
| python_fix | Return successfully from `_exec_checklocktimeverify()` for `tx.version < 2`; mirror the same no-op for BIP112 `_exec_checksequenceverify()` on version-1 transactions. Signature verification and normal CLTV failures for version-2+ transactions remain active. |
| test_fixture | `tests/fixtures/tx_p2sh_cltv_38191*.{hex,json}` and `tests/test_script.py` → `test_real_testnet4_block38191_p2sh_cltv_version1_noop_accepted` |
| follower_notes | Java commit `0fb03ee` independently cleared the same blocker and provided the transaction fixture. Followers should port the BIP65/BIP112 version-gate semantics, not skip P2SH or bypass signature checks. |

---

## Cleared: height 38010 — P2PKH legacy `SIGHASH_SINGLE` sequence

| Field | Value |
|-------|-------|
| height | 38010 |
| block_hash | `000000000000001287d6f4d832f330d1d9cddb3bb3741b25a4aeb8263a57a626` |
| txid | `ba32ba8e2d812d93317a0503d37d505a826517343f7fec3b8c2e0c715f142eb6` |
| input_index | 0 |
| spent_script_pubkey | P2PKH (`76a9149ec1ccfb40904402ee1d0a1c332c503772f22b3188ac`) |
| failure | `script verification failed for input 0` |
| missing_rule | Legacy `legacy_sighash()` zeroed **all** input sequences for `SIGHASH_NONE`/`SIGHASH_SINGLE`; Bitcoin Core only zeroes **non-signing** inputs (signing input keeps e.g. `0xfffffffd`). Also use placeholder empty outputs before the signed index for `SIGHASH_SINGLE`, not prior real outputs. |
| python_fix | Match Core `RawSignatureHash` sequence and output masking in `pybitnode/consensus/script/sighash.py`. |
| test_fixture | `tests/test_script.py` → `test_real_testnet4_block38010_p2pkh_sighash_single_sequence_accepted` |
| follower_notes | Port legacy sighash NONE/SINGLE semantics to TS/C++ followers (`legacySighash` had same bug). |

---

## Cleared: height 33500 — P2SH→P2WSH len-1 witness stack

| Field | Value |
|-------|-------|
| height | 33500 |
| block_hash | `0000000000000034e4c77a0972d1e032375271199ab86d3522c608fd36bf56c4` |
| txid | `f89a4629debeee9b32a3aaed72a209877a79b070ddcd4b6358312d5724b60683` |
| input_index | 0 |
| spent_script_pubkey | P2SH (`a91472c44f957fc011d97e3406667dca5b1c930c402687`) wrapping P2WSH |
| failure | `script verification failed for input 0` |
| missing_rule | Native P2WSH len-1 fix (31842) did not apply to **nested P2SH→P2WSH** path; still required `len(witness) >= 2`. |
| python_fix | Allow `len(witness) >= 1` in nested `is_p2wsh(redeem_candidate)` branch. |
| test_fixture | `tests/test_script.py` → `test_real_testnet4_block33500_p2sh_p2wsh_op1_only_witness_accepted` |
| follower_notes | Mirror native P2WSH minimum witness length in P2SH-nested segwit verification. |

---

## Cleared: height 32712 — P2TR tapscript `OP_NUMEQUAL` 2-of-3

| Field | Value |
|-------|-------|
| height | 32712 |
| block_hash | `0000000000000013db0b030faef1dd4e341e176036db9db4365f8430aadba6a3` |
| txid | `6b586a4f831e267749a3c2e50b866fe5badb582d3d388ea636669cbdc13acd94` |
| input_index | 0 |
| spent_script_pubkey | P2TR script-path (`51203a6c36818562ca3aa86741eb70dda13da67a5977255fc8af67109c8dbdd9f3ca`) |
| failure | `script verification failed for input 0` |
| missing_rule | Tapscript 2-of-3 multisig used `OP_CHECKSIGADD` + `OP_2` **`OP_NUMEQUAL` (0x9c)**; interpreter lacked numeric equality opcodes in tapscript (30622 used `OP_GREATERTHANOREQUAL` instead). |
| python_fix | `OP_NUMEQUAL` / `OP_NUMNOTEQUAL` in `_evaluate_tapscript`. |
| test_fixture | `tests/test_script.py` → `test_real_testnet4_block32712_p2tr_tapscript_checksigadd_2of3_numequal_accepted` |
| follower_notes | Tapscript CHECKSIGADD multisig may end with **`OP_NUMEQUAL`** (exact count) not only **`OP_GREATERTHANOREQUAL`**. Decode script numbers for both operands. |

---

## Cleared: height 31842 — P2WSH witness script only (`OP_1`, len-1 stack)

| Field | Value |
|-------|-------|
| height | 31842 |
| block_hash | `0000000000000042e3cc0898fda85fbbea98fcdb9acfa17742bf72d59996dd51` |
| txid | `b6dc55194be800938ea64ceaad98c299bbfe8590b2472779218808746f4a2659` |
| input_index | 0 |
| spent_script_pubkey | P2WSH (`00204ae81572f06e1b88fd5ced7a1a000945432e83e1551e6f721ee9c00b8cc33260`) |
| failure | `script verification failed for input 0` |
| missing_rule | P2WSH path required `len(witness) >= 2`; valid spends may use `[witnessScript]` alone when the script needs no witness arguments (here witness script = single byte `OP_1`). |
| python_fix | Allow `len(witness) >= 1` in `pybitnode/consensus/script/interpreter.py` P2WSH branch. |
| test_fixture | `tests/test_script.py` → `test_real_testnet4_block31842_p2wsh_op1_only_witness_accepted` |
| follower_notes | Segwit witness vector is stack items plus trailing witnessScript; minimum length is 1, not 2. Empty pre-script stack is valid. |

---

## Cleared: height 30695 — P2WSH IF-branch `OP_SIZE` hashlock

| Field | Value |
|-------|-------|
| height | 30695 |
| block_hash | `000000007f7a62c1032d13f5c54bcce73c20a13af939e1d715bc1c8cbbf1fe52` |
| txid | `1ec1f5f5…` (full hex in fixture) |
| input_index | 0 |
| spent_script_pubkey | P2WSH (`002062583e521abfb23c6c0e2d0cc900f74a1f9b7c9e06739dd61c4ab95cb07a2af9`) |
| failure | `script verification failed for input 0` |
| missing_rule | Legacy interpreter lacked `OP_SIZE` (0x82): witness script IF branch asserts 32-byte SHA256 preimage length before P2PKH `OP_EQUALVERIFY`. |
| python_fix | `f3324dc` — `OP_SIZE` stack semantics in `pybitnode/consensus/script/interpreter.py` |
| test_fixture | `tests/test_script.py` → `test_real_testnet4_block30695_p2wsh_if_hashlock_op_size_accepted` |
| follower_notes | Implement `OP_SIZE` in legacy (non-tapscript) redeem evaluation: push length of top stack item as minimal number; empty stack → verify failure. TypeScript/Java/C++ ports should mirror stack semantics, not Python control flow. |

---

## Cleared: height 30622 — P2TR tapscript `OP_CHECKSIGADD` 2-of-3

| Field | Value |
|-------|-------|
| height | 30622 |
| txid | `c185ee54…` |
| input_index | 0 |
| spent_script_pubkey | P2TR script-path (`51205ba9446d820fa0f14c80fee3bd48168866fc7365964eb2fc130323e3ee70f577`) |
| failure | `script verification failed for input 0` |
| missing_rule | Tapscript 2-of-3 used `OP_CHECKSIGADD` and `OP_GREATERTHANOREQUAL` (0xa2); interpreter lacked CHECKSIGADD and had wrong comparison opcode mapping. |
| python_fix | Unreleased on main at ledger write — see CHANGELOG [Unreleased]; CHECKSIGADD + opcode value fix in tapscript path. |
| test_fixture | `tests/test_script.py` → `test_real_testnet4_block30622_p2tr_tapscript_checksigadd_2of3_accepted` |
| follower_notes | BIP342 CHECKSIGADD: pop count and pubkey, verify sig against pubkey, push count+1 or 0. Ensure `OP_GREATERTHANOREQUAL` is 0xa2, not 0xa1. Affects all tapscript ports. |

---

## Cleared: height 30445 — P2WSH `OP_CHECKSIGVERIFY` clean-stack

| Field | Value |
|-------|-------|
| height | 30445 |
| txid | `fbfa79f1…` |
| input_index | 0 |
| spent_script_pubkey | P2WSH |
| failure | `script verification failed for input 0` |
| missing_rule | `OP_CHECKSIGVERIFY` / `OP_CHECKMULTISIGVERIFY` incorrectly pushed `true` after success; witness v0 requires exactly one stack item at end. |
| python_fix | See CHANGELOG [Unreleased] |
| test_fixture | `tests/test_script.py` → `test_real_testnet4_block30445_p2wsh_checksigverify_ordinals_envelope_accepted` |
| follower_notes | VERIFY-family opcodes must not leave a success push on the stack in legacy or tapscript paths. |

---

## Earlier milestones (see CHANGELOG + OPERATIONS.md)

| Height | Rule | Test fixture prefix |
|--------|------|---------------------|
| 6975 | P2TR key-path (Schnorr) | `test_real_testnet4_block6975_taproot_keypath_accepted` |
| 25207 | Bare `OP_1` output template | `test_real_testnet4_block25207_bare_op1_and_p2tr_spend_accepted` |
| 27840 | Bare 2-of-3 multisig | `test_real_testnet4_block27840_bare_multisig_accepted` |
| 27903 | P2SH→P2WPKH nested segwit | `test_real_testnet4_block27903_p2sh_p2wpkh_nested_segwit_accepted` |
| 28527 | Large tapscript (>10k) | `test_real_testnet4_block28527_p2tr_large_tapscript_accepted` |
