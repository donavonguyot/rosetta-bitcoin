# Blocker ledger (CppNode follower)

Handoff from live sync. PythonNode is the scout; reproduce rules independently in C++.

## Cleared locally: height 739 — P2WPKH ECDSA verify (secp256k1)

| Field | Value |
|-------|-------|
| height | 739 |
| block_hash | `000000004cfba4fe6174c546086df7fb52b3d65d44788c0ee8acf436dd28de32` |
| tx | block tx index 1 (563-input consolidation) |
| input_index | 142 |
| spent_script_pubkey | P2WPKH `0014a54e2a1ec06389203887661535ed118b7d053889` |
| prevout | `4398b3e2745292e847d577f89a3fdb6e05b97c83ba0798c82a252c793981b29d:0` (display txid) |
| amount | 5000000000 sat |
| failure | `script verification failed for input 142` |
| missing_rule | In-tree `verifyDerSignature` rejects a valid mainnet/testnet4 DER signature that Python accepts; BIP143 digest matches Python (`f8bd78ac…522c1`). Native libsecp256k1 backend is now available for proof builds and should be used for the rerun. |
| python_fix | N/A — Python validates this spend today (`verify_script` → True). |
| test_fixture | `tests/fixtures/block739.hex`; isolate with tx1 input 142 P2WPKH vectors above. |
| follower_notes | Do not skip the block. `cpbitnode-blocker-inspect --height 739` now emits first-class Cpp diagnostic JSON. Native secp256k1 vector tests pass; next step is a live RocksDB/native sync rerun to prove height 739 connects locally. |

**Cpp local proof:** `testBlock739P2wpkhInput142AcceptedWithNativeCrypto` deserializes
`tests/fixtures/block739.hex` and verifies tx index 1 input 142 against the
documented P2WPKH prevout with native libsecp256k1.

**Sync command used:**

```bash
MAX_OUTBOUND_PEERS=1 SKIP_GETADDR=1 ./build/cpbitnode-sync \
  --datadir ./data-cpp --peers 127.0.0.1:48333 \
  --blocks-target 1000 --blocks-max 200 --no-header-refresh
```

**Peer:** `127.0.0.1:48333` (local Bitcoin Core testnet4)

**Handshake posture (AGENTS.md):** `version` → `verack` → `sendheaders`; defer `feefilter`/`mempool` until headers current. `resolveBootstrapStartHeight` reports validated height during block-only sync.

## C++ target-readiness coverage map through 50k

This section is the C++ preflight anchor for long target runs. A row here means
the documented blocker family has either an exact shared script-corpus fixture or
a native C++ semantic regression in `cpbitnode_tests` before the port attempts a
long sync target.

| Height | Rule family | C++ coverage anchor |
|--------|-------------|---------------------|
| 6975 | P2TR key-path/script verification | `testRealTestnet4TaprootKeypath`; `testTaprootScriptPathOpSuccess` |
| 18675 | P2SH redeem script | `testP2shSpendRoundtrip`; `testP2shScriptPubkeyHashMismatchRejected` |
| 22830 | P2TR script path / BIP342 | `testTaprootScriptPathTapscriptCltvAccepted`; `testTaprootScriptPathTapscriptCsvAccepted`; shared corpus `scripts.p2tr_scriptpath_44295` and `scripts.p2tr_scriptpath_46599` |
| 25207 | Bare `OP_1` | `testBareOpNPlusPushTemplate41700`; `testBareOpNPlusPush41700Accepted` |
| 27042 | Native P2WSH | `testP2wshSpendRoundtrip`; `testP2wshCltvRoundtrip` |
| 27251 | P2WSH conditional branch | `testEvaluateScriptVerifyAndEqualVerifyFailures`; `testP2wshCsvRoundtrip` |
| 27807 | P2SH hashlock | `testLegacyEvaluateScriptHashOpcodes`; `testP2shSpendRoundtrip` |
| 27815 | P2SH numeric branch | `testLegacyEvaluateScriptStackArithmeticOpcodes`; `testP2shCltvRejectsUnsatisfiedLocktime` |
| 27840 | Bare multisig-like script | shared corpus `scripts.bare_multisig_27840` |
| 32712 | Tapscript `OP_NUMEQUAL` | shared corpus `scripts.p2tr_tapscript_numequal_32712` |
| 32868 | CLTV | shared corpus `scripts.p2wsh_cltv_32868` |
| 33500 | Nested P2SH to P2WSH | shared corpus `scripts.p2sh_p2wsh_op1_only_33500` |
| 38010 | Legacy sighash sequence masking | shared corpus `scripts.p2pkh_sighash_single_38010` |
| 38191 | CLTV nVersion behavior | shared corpus `scripts.p2sh_cltv_38191` |
| 41700 | Bare `OP_1` plus data push | `testBareOpNPlusPushTemplate41700`; `testBareOpNPlusPush41700Accepted` |
| 44295 | Tapscript `OP_NIP` | shared corpus `scripts.p2tr_scriptpath_44295` |
| 46599 | Taproot script-path terminal stack truthiness | shared corpus `scripts.p2tr_scriptpath_46599`; `testCastToBoolRejectsNegativeZero` |
| 46779 | P2WSH `OP_CODESEPARATOR` / comparison | shared corpus `scripts.p2wsh_size_lessthan_46779` |
