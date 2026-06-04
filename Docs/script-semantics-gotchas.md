# Script semantics gotchas from the Python / Java trail

These are the consensus details that repeatedly caused honest stops during
testnet4 sync. They are language-neutral notes for follower ports. Use the
blocker catalog for exact block and transaction facts.

## Shared script corpus and MATRIX triage

Ports that run [`Nodes/Shared/conformance/fixtures/scripts/manifest.json`](../Nodes/Shared/conformance/fixtures/scripts/manifest.json)
often misread failures as “add opcode X” because each fixture’s `missing_rule`
and many MATRIX rows are **historical harvest labels** from when Java (or another
port) was blocked. They are hints for search and grouping, not proof that the
opcode dispatch table is empty.

**Classify the failure before extending the opcode table.** Typical order:

1. **Loader / prevouts** — transaction and witness bytes, witness stack order,
   full `prevouts.json` vs a single padded prevout, `prev_spk` file vs inline
   `spent_script_pubkey` hex.
2. **Template gate** — bare legacy, P2SH → nested witness, P2TR key-path vs
   script-path; an unknown `scriptPubKey` template fails before any opcode runs.
3. **Sighash** — legacy `SIGHASH_SINGLE` / `NONE` / `ANYONECANPAY`, BIP143
   amount and `scriptCode`, taproot sighash with tapleaf digest and codeseparator
   position.
4. **Stack semantics** — `CHECKSIGVERIFY` / `CHECKMULTISIGVERIFY` must not leave a
   result on the stack; IF/ELSE inactive-branch skipping; P2SH relaxed terminal vs
   witness strict terminal; `castToBool` (only `0x80` in the last byte is false).
5. **Opcode surface** — only after the same fixture bytes pass on the Python
   corpus oracle (commits `204d707` legacy batch, `07a4367` tapscript).

### Common red herrings

| What you see | What it often is |
|--------------|------------------|
| `tapscript failed final stack check` (e.g. stack size 2) | `CHECKSIGVERIFY` / `CHECKMULTISIGVERIFY` pushed a truthy value like `CHECKSIG` instead of verifying and discarding |
| Generic `script verification failed` on a large P2TR script-path spend | Tapscript leaf rejected by the **legacy 10 000-byte script size cap** (BIP342 does not apply that cap to tapscript leaves) |
| `CHECKSEQUENCEVERIFY negative locktime` with a disable-style operand | **Narrow integer decode**; test the disable flag on the **unsigned** operand before rejecting as negative |
| `CHECKSIGVERIFY failed` on P2WSH scripts that use `OP_2DUP` / `OP_SWAP` / `OP_NIP` | Stack layout or ECDSA/BIP143 sighash, not a missing stack opcode |
| `invalid Schnorr signature length` | Wrong stack item used as the signature (order or IF-branch effects), not a missing `OP_SIZE` / `OP_DEPTH` |

### Corpus discipline

- Run with **real signature verification** (e.g. native libsecp256k1); stub crypto
  cannot honestly pass ECDSA/Schnorr fixtures.
- Surface **`ScriptError` / `ScriptVerifyError` messages** in per-fixture corpus JSON;
  a bare `verifyScript == false` hides the layer (template, sighash, stack, crypto).
- Do not treat another port’s live sync as an oracle; use the shared bytes plus
  Python corpus semantics on the trail above.
- Claim progress only with a port result JSON under
  [`Nodes/Shared/conformance/results/`](../Nodes/Shared/conformance/results/) and an updated
  [`MATRIX.md`](../Nodes/Shared/conformance/fixtures/scripts/MATRIX.md) column — `not_started`
  does not mean 0/45.

See also [`Nodes/Shared/conformance/fixtures/scripts/README.md`](../Nodes/Shared/conformance/fixtures/scripts/README.md)
for runner commands and a short debugging checklist.

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
- For `SIGHASH_SINGLE` with `inputIndex > 0`, serialize `inputIndex + 1` outputs using **empty placeholder** `CTxOut(-1, "")` (Core default null output; `nValue` is `-1`, not `0`) for indices `< inputIndex`, then the real output at `inputIndex` (Core `SerializeOutput`; not prior real outputs).
- When `inputIndex >= vout.size()` under `SIGHASH_SINGLE`, return **`uint256::ONE`** (256-bit little-endian integer 1: `hash[0]=0x01`, rest zero — not `hash[31]=1`).
- Test `ANYONECANPAY` combinations.
- Include a real fixture for height 38,010 if the port implements legacy script.
- Include height 61,174 for multi-input P2PKH `SIGHASH_SINGLE` with `inputIndex > 0`.

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
- The first shared testnet4 key-path milestone is height 6,975.

Script-path additionally requires:

- Control block parsing.
- Leaf hash calculation and taproot output key commitment verification.
- BIP342 tapscript opcode semantics.
- Terminal stack truthiness.
- The witness shape classifies key-path vs script-path: key-path spends have a
  single Schnorr signature witness item, while script-path spends end with the
  tapscript and control block items.

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
- Before implementing C# tapscript at height 22,830, add a first-class C# or
  Shared diagnostic that reports:

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
- `OP_ROT` (legacy @62754; **0x7b** rotates top three stack items `(x1 x2 x3 → x2 x3 x1)`; pubkey pushes may contain `0x7b` as data — use `decodescript` asm and byte offsets, not raw hex search).
- `OP_3DUP` (legacy @63305; **0x6f** duplicates top three stack items `(x1 x2 x3 → x1 x2 x3 x1 x2 x3)`; seen in P2SH redeem script, not witness).
- `OP_2DUP` (legacy @63603; **0x6e** duplicates top two stack items `(x1 x2 → x1 x2 x1 x2)`; seen in P2SH redeem script; do not confuse with `OP_DUP` 0x76 or disabled `OP_2MUL` 0x8d).
- `OP_TOALTSTACK` / `OP_FROMALTSTACK` (P2WSH @66241; **0x6b** / **0x6c** move items between the main stack and an interpreter-local alternate stack; do not persist altstack across script evaluations).

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
