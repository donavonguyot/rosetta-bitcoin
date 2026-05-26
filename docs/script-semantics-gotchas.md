# Script semantics gotchas from the Python / Java trail

These are the consensus details that repeatedly caused honest stops during
testnet4 sync. They are language-neutral notes for follower ports. Use the
blocker catalog for exact block and transaction facts.

## Policy is not consensus

Several spends are non-standard or unusual but still consensus-valid. A syncing
node must validate them, not reject them as policy failures.

Examples:

- Bare `OP_1`.
- Bare `OP_1` plus data push.
- Bare multisig-like scripts.
- P2SH redeem scripts that are unusual but valid.

Follower rule: standardness belongs in mempool policy, not block connection.

## Legacy sighash sequence masking

Height 38,010 exposed legacy sighash behavior around `SIGHASH_SINGLE` and
`SIGHASH_NONE`. When computing the signature hash, non-current input sequences
must be masked according to the sighash mode. A verifier that signs all original
sequences will fail otherwise valid historical spends.

Follower checklist:

- Test `SIGHASH_ALL`, `SIGHASH_NONE`, and `SIGHASH_SINGLE`.
- Test `ANYONECANPAY` combinations.
- Include a real fixture for height 38,010 if the port implements legacy script.

## CLTV and CSV edge cases

CLTV/CSV are not just opcodes; they depend on transaction fields.

Observed blockers:

- Height 32,868 required `OP_CHECKLOCKTIMEVERIFY`.
- Height 38,191 exposed CLTV no-op behavior when the transaction version is below
  the BIP65 threshold.

Follower checklist:

- Verify transaction version behavior.
- Verify locktime type matching: block height vs timestamp.
- Verify final sequence handling.
- Verify CSV sequence disable/type/mask rules.
- Add negative tests for unsatisfied locks.

## P2SH and witness nesting

Nested scripts must be unwrapped in the right order:

1. Verify `scriptSig` push-only for P2SH.
2. Extract redeem script.
3. If redeem script is a witness program, dispatch to witness verification.
4. For P2WSH, verify witness script hash before executing.

Observed blockers:

- Height 18,675: basic P2SH.
- Height 33,500: nested P2SH to P2WSH with a len-1 witness stack shape.

Follower checklist:

- Keep P2SH, P2WPKH, P2WSH, and nested witness tests separate.
- Include both acceptance and hash-mismatch rejection cases.

## Taproot key-path vs script-path

Taproot key-path and script-path are separate milestones.

Key-path requires:

- BIP340 Schnorr verification.
- Taproot key-path sighash.

Script-path additionally requires:

- Control block parsing.
- Tapleaf hash and script commitment verification.
- BIP342 tapscript opcode semantics.
- Terminal stack truthiness.

Observed blockers:

- Height 6,975: P2TR key-path.
- Height 22,830: P2TR script-path.
- Height 44,295: tapscript `OP_NIP`.
- Height 46,599: tapscript terminal stack truthiness.
- Height 52,024: tapscript `OP_SHA256`.

Follower checklist:

- Do not mark Taproot complete after only key-path support.
- Reuse shared fixture names and record control-block metadata.
- Confirm `castToBool` semantics for tapscript terminal success.

## Tapscript and legacy opcode overlap

Some opcode names exist in both legacy and tapscript contexts, but rules may
differ by verification mode.

Observed Java fixes included:

- `OP_NUMEQUAL`.
- `OP_NIP`.
- `OP_SHA256`.
- `OP_SIZE` (tapscript; dual SHA256 hashlock size checks @52497).
- `OP_CODESEPARATOR`.
- `OP_LESSTHAN`.
- `OP_0NOTEQUAL` (legacy @58173; **0x92 is not OP_MUL** — disabled `OP_MUL` is 0x95).

Follower checklist:

- Pass script version / verification flags into opcode evaluation.
- Avoid implementing an opcode only in legacy mode when the blocker is tapscript.
- Include tests that prove the opcode is active under the right script version.

## Script number and boolean semantics

Numeric and boolean casting details are consensus-sensitive.

Risk areas:

- Minimal encoding when required by flags.
- Negative zero.
- Signed little-endian script numbers.
- Boolean truthiness of byte vectors.
- Arithmetic overflow and fixed-size script number limits.

Observed blockers around 27,815, 32,712, 46,599, and 51,340 all depend on these
details directly or indirectly.

## UTXO corruption is not a consensus rule

Missing UTXO errors can look like consensus failures but usually indicate state
corruption or writer overlap.

Observed cases:

- TypeScript height 5,579 after overlapping sync writers.
- Java early development range around 4,947 to 5,324.

Follower checklist:

- Enforce one writer per datadir.
- Make block connect atomic: undo rows, UTXO mutations, and validated tip update
  should commit together.
- Rebuild/replay before adding consensus rules for missing-prevout errors.
- Record missing-prevout failures separately from script verification failures.

## Fixture discipline

Every consensus unblock should leave:

- Real block or transaction bytes.
- Prevout scriptPubKey.
- Input index.
- Amount.
- Flags / script version.
- Expected result.
- A negative test when practical.

This allows follower ports to copy the work queue without copying trust.
