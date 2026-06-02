# Changelog

All notable milestones for the pybitnode testnet4 node. Format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Durable detached sync supervisor (`scripts/sync_persistent_supervisor.sh`) with fcntl lock, stall JSON, and infinite batch-loop retries until `TARGET` height.
- Companion stall watcher (`scripts/sync_fix_agent_loop.sh`) and in-session fix worker (`scripts/sync_session_fix_agent.sh`).
- Block flat-file index repair tool (`scripts/repair_block_file_offsets.py`) for corrupted `file_offset` metadata after parallel downloads.
- Taproot (P2TR) script-path verification (BIP341/BIP342 subset) alongside existing key-path spends.
- Tapscript conditional branches (`OP_IF`/`OP_NOTIF`/`OP_ELSE`/`OP_ENDIF`, BIP342) unblocking block **22830** (`088ee6b`).
- Tapscript `OP_CHECKLOCKTIMEVERIFY` and `OP_CHECKSEQUENCEVERIFY` (BIP65/BIP112 via Schnorr sighash) (`f394ad0`).
- Explicit rejection of witness v2+ programs with version-specific error (BIP141) (`600f086`).
- Sequential sync batch orchestrator (`scripts/sync_batch_loop.py`) with fcntl exclusive lock and native-state height polling.
- Native-state script template survey helper for diagnosing consensus stalls.
- Wire capability registry and `GET /metrics` ops reference documentation.
- RocksDB-backed native tracker, bounded RocksDB proof command, native `coincurve` crypto backend, and Docker proof/supervisor helpers.

### Fixed
- Header-sync stall when refreshing headers during block catch-up (`--no-header-refresh` batch recipe).
- Lightweight P2P handshake path for single-peer block download batches.
- Sync batch orchestration false positives (datadir flock + RO URI polling instead of naive `pgrep`).
- Bare `OP_1` legacy output template acceptance unblocking block **25207** (`678c046`); error `unsupported scriptPubKey template`; test `test_real_testnet4_block25207_bare_op1_and_p2tr_spend_accepted`.
- **Block 27840** — tx `f2b2a965…`, input 0, error `script verification failed for input 0`; bare 2-of-3 multisig (`OP_2` + 3 pubkeys + `OP_3` `OP_CHECKMULTISIG`) was rejected as unsupported template; enabled bare multisig scriptPubKey acceptance in legacy path. Test: `test_real_testnet4_block27840_bare_multisig_accepted`.
- **Block 27903** — tx `0ec62ece…`, input 0, error `script verification failed for input 0`; P2SH-wrapped P2WPKH nested segwit spend (redeem `0x0014{hash160}`, witness sig+pubkey) was not verified after P2SH outer check; added P2SH→P2WPKH/P2WSH nested witness verification (BIP141). Test: `test_real_testnet4_block27903_p2sh_p2wpkh_nested_segwit_accepted`.
- **Block 28527** — tx `d459f9eb…`, input 0, error `script verification failed for input 0`; P2TR script-path tapscript (~15444 bytes, Ordinals `text/plain` envelope) rejected by `MAX_CONSENSUS_SCRIPT_SIZE` (10000) in `_verify_p2tr_script_path`; removed 10k cap for tapscript leaves per BIP342 (cap still applies to P2WSH witness scripts). Test: `test_real_testnet4_block28527_p2tr_large_tapscript_accepted`.
- **Block 30445** — tx `fbfa79f1…`, input 0, error `script verification failed for input 0`; P2WSH witness script used `OP_CHECKSIGVERIFY` with Ordinals `OP_IF` envelope but interpreter always pushed a true stack item after VERIFY (Bitcoin Core pops it), failing witness v0 clean-stack; fixed `OP_CHECKSIGVERIFY` / `OP_CHECKMULTISIGVERIFY` to omit success push in legacy and tapscript paths. Test: `test_real_testnet4_block30445_p2wsh_checksigverify_ordinals_envelope_accepted`.
- **Block 30622** — tx `c185ee54…`, input 0, error `script verification failed for input 0`; P2TR script-path 2-of-3 tapscript used `OP_CHECKSIGADD` and `OP_GREATERTHANOREQUAL` (0xa2) but interpreter lacked CHECKSIGADD and mapped `OP_GREATERTHANOREQUAL` to 0xa1; added BIP342 CHECKSIGADD semantics and corrected comparison opcode values in tapscript. Test: `test_real_testnet4_block30622_p2tr_tapscript_checksigadd_2of3_accepted`.
- **Block 30695** — tx `1ec1f5f5…`, input 0, error `script verification failed for input 0`; P2WSH witness script IF-branch hashlock path used `OP_SIZE` (0x82) to assert a 32-byte SHA256 preimage before P2PKH `OP_EQUALVERIFY`, but legacy interpreter treated 0x82 as an unsupported opcode; added `OP_SIZE` stack semantics. Test: `test_real_testnet4_block30695_p2wsh_if_hashlock_op_size_accepted`.
- Batch sync loop early exit on consensus stall (`validated_delta=0`, sync exit 0): logs STALL marker and returns exit code **5** (`660d788`).
- **Block 31842** — tx `b6dc5519…`, input 0, error `script verification failed for input 0`; P2WSH spend with witness script `OP_1` only and witness stack length 1 was rejected because verification required `len(witness) >= 2`; allow minimum length 1. Test: `test_real_testnet4_block31842_p2wsh_op1_only_witness_accepted`.
- **Block 32712** — tx `6b586a4f…`, input 0, error `script verification failed for input 0`; P2TR script-path 2-of-3 tapscript used `OP_2 OP_NUMEQUAL` after CHECKSIGADD but tapscript evaluator lacked `OP_NUMEQUAL`/`OP_NUMNOTEQUAL`. Test: `test_real_testnet4_block32712_p2tr_tapscript_checksigadd_2of3_numequal_accepted`.
- **Block 33500** — tx `f89a4629…`, input 0, error `script verification failed for input 0`; P2SH-wrapped P2WSH with `OP_1`-only witness stack (len 1) rejected in nested path; align with native P2WSH minimum length 1. Test: `test_real_testnet4_block33500_p2sh_p2wsh_op1_only_witness_accepted`.
- **Block 38010** — tx `ba32ba8e…`, input 0, error `script verification failed for input 0`; P2PKH spend with `SIGHASH_SINGLE` and `nSequence=0xfffffffd` rejected because legacy sighash zeroed the signing input sequence for NONE/SINGLE; fixed to match Core `RawSignatureHash` (also placeholder empty outputs before signed index for SINGLE). Test: `test_real_testnet4_block38010_p2pkh_sighash_single_sequence_accepted`.

### Changed
- Snapshot exports checkpoint validated chain state at heights **10000** (`85ca98c`) and **25000** (`b457771`).
- Prior snapshot milestone at height **7974**; Taproot key-path unblock at height **6975**.
- Live sync resumed after block **30445** fix; validated through **30621** before stall at **30622** (CHECKSIGADD); fix applied 2026-05-25. Block **30695** stall (P2WSH `OP_SIZE` hashlock) fixed same day.

### Documentation
- Consensus stall playbook including Taproot sync case study.
- Post-10k batch sync toward header horizon (`docs/OPERATIONS.md`).
