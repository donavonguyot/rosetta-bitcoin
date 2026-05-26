# Follower port blocker matrix

This matrix summarizes which ports are known to have cleared each shared
testnet4 consensus blocker. It is deliberately conservative: if a port's ledger
or live status did not prove a rule, the cell is `unknown` or `not_reached`.

Legend:

- `cleared`: validated past this height or has a fixture proving the rule.
- `blocked`: known current/historical stop not yet cleared in that port.
- `implemented_unverified`: code or fixture exists, but live validation past the height was not confirmed.
- `not_reached`: current validated height is below the blocker.
- `unknown`: no trustworthy status was available.

## Matrix

| Height | Rule / template | Python | Java | TypeScript | C# | Elixir | C++ |
|--------|-----------------|--------|------|------------|----|--------|-----|
| 739 | P2WPKH / BIP143 | cleared | cleared | cleared | cleared | cleared | blocked |
| 6,975 | P2TR key-path | cleared | cleared | unknown | not_reached | implemented_unverified | not_reached |
| 18,675 | P2SH | cleared | cleared | unknown | not_reached | not_reached | not_reached |
| 22,830 | P2TR script-path | cleared | cleared | unknown | not_reached | not_reached | not_reached |
| 25,207 | Bare `OP_1` | cleared | cleared | unknown | not_reached | not_reached | not_reached |
| 27,042 | P2WSH | cleared | cleared | unknown | not_reached | not_reached | not_reached |
| 27,251 | P2WSH conditionals | cleared | cleared | unknown | not_reached | not_reached | not_reached |
| 27,807 | P2SH hashlock | cleared | cleared | unknown | not_reached | not_reached | not_reached |
| 27,815 | P2SH numeric branch | cleared | cleared | unknown | not_reached | not_reached | not_reached |
| 27,840 | Bare multisig-like script | cleared | cleared | unknown | not_reached | not_reached | not_reached |
| 32,712 | Tapscript `OP_NUMEQUAL` | cleared | cleared | unknown | not_reached | not_reached | not_reached |
| 32,868 | CLTV | cleared | cleared | unknown | not_reached | not_reached | not_reached |
| 33,500 | Nested P2SH to P2WSH | cleared | cleared | unknown | not_reached | not_reached | not_reached |
| 38,010 | Legacy sighash sequence masking | cleared | cleared | unknown | not_reached | not_reached | not_reached |
| 38,191 | CLTV `nVersion` behavior | cleared | cleared | unknown | not_reached | not_reached | not_reached |
| 41,700 | Bare `OP_1` plus data push | cleared | cleared | unknown | not_reached | not_reached | not_reached |
| 44,295 | Tapscript `OP_NIP` | unknown | cleared | unknown | not_reached | not_reached | not_reached |
| 46,599 | Taproot terminal stack truthiness | unknown | cleared | unknown | not_reached | not_reached | not_reached |
| 46,779 | P2WSH `OP_CODESEPARATOR` / comparison | unknown | cleared | unknown | not_reached | not_reached | not_reached |
| 51,340 | P2SH `OP_ADD` redeem script | unknown | cleared | unknown | not_reached | not_reached | not_reached |
| 52,024 | Tapscript `OP_SHA256` | unknown | cleared | unknown | not_reached | not_reached | not_reached |

## Port notes

### Python

Python remains the scout. It was observed syncing past 43,586, so all rows up to
41,700 are marked cleared. Rows above that remain `unknown` until Python records
or validates them.

### Java

Java is the lead follower and has commits clearing the trail through 52,024. It
should be used as a reference implementation and fixture source, not as a
validity oracle.

### TypeScript

TypeScript has recovered from the 5,579 UTXO corruption issue and has substantial
script work, but this matrix only marks rules as cleared when the shared trail
has explicit proof available here. Fill cells from `tsbitnode` fixtures and live
validated heights as they are confirmed.

### C#

C# has a documented real block 739 P2WPKH fixture and sync beyond that height.
Its next matrix entries remain `not_reached` based on available ledger evidence.

### Elixir

Elixir has documented P2WPKH and P2TR key-path fixture coverage. Live sync past
6,975 was not confirmed in the evidence used for this matrix, so P2TR key-path is
`implemented_unverified` rather than `cleared`.

### C++

C++ was last known blocked at height 739. Update this matrix when C++ clears its
P2WPKH blocker and records a fixture.

## Update rule

When a port clears a row:

1. Add or identify the fixture/test.
2. Record exact blocker facts in the port ledger.
3. Update this matrix from `not_reached` or `unknown` to `cleared`.
4. Link back to the relevant catalog row in
   [consensus-blockers-testnet4.md](consensus-blockers-testnet4.md).
