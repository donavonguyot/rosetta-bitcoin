# CSharp blocker ledger

Handoff notes for csbitnode. Current consensus runway truth comes from Project
plus the Shared consensus rule ledger and script corpus; historical Python notes
are provenance only.

## Historical evidence notes

```bash
cd Nodes/CSharp
make node-status
```

This ledger preserves durable blocker facts and implementation handoff notes.
Current C# status, benchmark gates, and consensus runway posture are Project
projections; query `Project/project.db` instead of treating this ledger as live
status.

The old blocker serialization failure was not consensus. It was fixed by
persisting `ValidationBlockerRecord` instead of serializing the raw
`ValidationBlocker` exception object.

## Cleared: height 739 — P2WPKH spend (2026-05-25)

| Field | Value |
|-------|-------|
| height | 739 |
| block_hash | `000000004cfba4fe6174c546086df7fb52b3d65d44788c0ee8acf436dd28de32` |
| txid | `475ff67b2f2631c6b443635951d81127dcf21898f697d5f7c31e88df836ee756` |
| input_index | 0 |
| spent_script_pubkey | `0014a54e2a1ec06389203887661535ed118b7d053889` |
| failure (was) | `script verification not yet implemented for template P2WPKH` |
| missing_rule (was) | `script_interpreter_not_implemented` |
| python_fix | Base interpreter: P2PK / P2PKH / P2WPKH (BIP143 witness path) |
| test_fixture | `tests/CsBitNode.Tests/Fixtures/block739_tx.hex` + `ScriptVerifyTests.RealTestnet4Block739P2wpkhInput0Accepted` |
| follower_notes | Implemented `ScriptInterpreter` + `Sighash` (legacy + BIP143) + `Secp256k1.VerifyDerSignature`. Resume sync passed 739; DB may still show stale blocker row until next honest stop. |

## Cleared: height 6975 — P2TR key-path

| Field | Value |
|-------|-------|
| height | 6975 |
| status | cleared in C# supervisor run |
| template | P2TR key-path |
| missing_rule (was) | Taproot key-path spend validation |
| follower_notes | Clearing 6975 does not imply Taproot script-path support. |

## Cleared: 10k bounded range

| Field | Value |
|-------|-------|
| status | cleared past 10000 in C# supervisor run |
| storage | RocksDB native chainstate |
| crypto | native secp256k1 requested |
| new_blocker | none before 22830 |
| binary_gate_status | not_attempted |

## Blocked: height 22830 — P2TR script-path

| Field | Value |
|-------|-------|
| height | 22830 |
| block_hash | `00000000000002a436f697d3411d77b66609c47a398951acc82f8307c880116d` |
| txid | `630725d944cb0ddba2e249f248b725d1f136fc3d698e8dc4f6be61e9103fa33c` |
| input_index | 0 |
| spent_script_pubkey | `5120f6b00789c732c14a921e61f2b1918a8a8db262d5b0aa2fb6e8229ce3870acda5` |
| failure | `script verification failed for input 0` |
| missing_rule | P2TR script-path / BIP342 tapscript |
| java_fix | Java implements script-path control block, leaf hash, tapscript evaluation, and BIP342 sighash. |
| next_test_fixture | First-class C# fixture/diagnostic for block 22830 before implementing tapscript. |
| follower_notes | Do not use the one-off Python scanner as the recurring workflow. C# status/diagnostics should report witness shape and key-path vs script-path classification. |

Diagnostic contract: `../../Shared/diagnostics/BLOCKER_DIAGNOSTICS.md`.

## Supervisor lessons

- Use persistent `csbitnode_sync_data` for blocker hunting, not fresh proof
  volumes.
- Keep `POLL_SEC` for chat/operator reports and `CHECK_SEC` for fast container
  completion checks.
- Pause on blocker/error and resume from the same volume after code changes.
- Persist blocker DTOs, not exception objects.

## Template

```text
height:
block_hash:
txid:
input_index:
spent_script_pubkey:
failure:
missing_rule:
python_fix:
test_fixture:
follower_notes:
```
