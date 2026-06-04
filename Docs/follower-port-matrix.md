# Follower port blocker matrix

This matrix summarizes which ports are known to have cleared each shared
testnet4 consensus blocker. It is deliberately conservative: if a port's ledger
or live status did not prove a rule, the cell is `unknown` or `not_reached`.

This matrix is not a Core Node compliance table. Consensus blocker clearance,
native storage compliance, and Docker runtime compliance are tracked separately
in [port-status.md](port-status.md) and the Shared contracts.

Legend:

- `cleared`: validated past this height or has a fixture proving the rule.
- `blocked`: known current/historical stop not yet cleared in that port.
- `implemented_unverified`: code or fixture exists, but live validation past the height was not confirmed.
- `not_reached`: current validated height is below the blocker.
- `unknown`: no trustworthy status was available.

## Matrix

| Height | Rule / template | Python | Java | TypeScript | C# | Elixir | C++ |
|--------|-----------------|--------|------|------------|----|--------|-----|
| 739 | P2WPKH / BIP143 | cleared | cleared | cleared | cleared | cleared | cleared |
| 6,975 | P2TR key-path | cleared | cleared | unknown | cleared | implemented_unverified | not_reached |
| 18,675 | P2SH | cleared | cleared | unknown | cleared | not_reached | not_reached |
| 22,830 | P2TR script-path | cleared | cleared | unknown | blocked | not_reached | not_reached |
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
| 63,305 | P2SH redeem `OP_3DUP` | unknown | cleared | unknown | not_reached | not_reached | not_reached |
| 87,214 | P2TR tapscript `OP_IFDUP` | unknown | cleared | unknown | not_reached | not_reached | not_reached |
| 89,632 | P2TR tapscript CLTV/CSV v1 no-op | unknown | cleared | unknown | not_reached | not_reached | not_reached |
| 98,025 | P2WSH `OP_WITHIN` | unknown | cleared | unknown | not_reached | not_reached | not_reached |
| 98,631 | P2WSH `OP_NIP` | unknown | cleared | unknown | not_reached | not_reached | not_reached |
| 100,372 | P2TR tapscript `OP_0NOTEQUAL` | unknown | cleared | unknown | not_reached | not_reached | not_reached |
| 107,951 | P2PKH relaxed terminal stack | unknown | cleared | unknown | not_reached | not_reached | not_reached |
| 108,508 | P2TR tapscript `OP_1SUB` | unknown | cleared | unknown | not_reached | not_reached | not_reached |
| 108,972 | P2SH stack ops | unknown | cleared | unknown | not_reached | not_reached | not_reached |
| 116,040 | P2SH `OP_RIPEMD160` | unknown | cleared | unknown | not_reached | not_reached | not_reached |
| 118,555 | Bare legacy mega-script | unknown | cleared | unknown | not_reached | not_reached | not_reached |
| 121,035 | P2TR tapscript `OP_BOOLOR` | unknown | cleared | unknown | not_reached | not_reached | not_reached |
| 126,975 | P2TR tapscript `OP_2OVER`/`OP_OVER` | unknown | cleared | unknown | not_reached | not_reached | not_reached |
| 132,361 | P2SH `OP_ABS` | unknown | cleared | unknown | not_reached | not_reached | not_reached |
| 133,634 | P2TR tapscript CSV stack disable | unknown | cleared | unknown | not_reached | not_reached | not_reached |
| 136,369 | P2WSH `OP_BOOLAND` | unknown | cleared | unknown | not_reached | not_reached | not_reached |

## Port notes

### Python

Python rows are historical SQLite-scout evidence. Python's forward parity path is
a full-break RocksDB/native-crypto runtime, so these cells must be rediscovered
from an empty native datadir before they count as current Python parity proof.
The old scout was observed syncing past 43,586, so all rows up to 41,700 remain
useful handoff facts; rows above that remain `unknown` until a current Python
runtime records or validates them.

### Java

Java is the lead follower with live validation through **136,863** and
`binary_gate_status: passed` on `data-java` (Core-aligned chain, 2026-05-29).
Use fixtures and ledger rows through **136,369** as the follower queue, not as a
validity oracle.

### TypeScript

TypeScript has recovered from the 5,579 UTXO corruption issue and has substantial
script work, but this matrix only marks rules as cleared when the shared trail
has explicit proof available here. Fill cells from `tsbitnode` fixtures and live
validated heights as they are confirmed.

### C#

C# has a documented real block 739 P2WPKH fixture and persistent supervisor
evidence through `validated_height=22829`. It cleared P2TR key-path at 6975 and
P2SH at 18675, then stopped honestly at 22830 on P2TR script-path / BIP342.

### Elixir

Elixir has documented P2WPKH and P2TR key-path fixture coverage. Live sync past
6,975 was not confirmed in the evidence used for this matrix, so P2TR key-path is
`implemented_unverified` rather than `cleared`.

### C++

C++ now has RocksDB/native secp256k1 proof infrastructure, a first-class
height-739 diagnostic CLI, and a native fixture regression for tx index 1 input
142 from `tests/fixtures/block739.hex`. Runtime sync still needs to be rerun
from height 738 to advance the live Cpp datadir. C++ Core storage status is
proof-pending after the RocksDB-only state cutover; fresh artifacts must show
RocksDB owns all operational truth without opening SQLite.

## Update rule

When a port clears a row:

1. Add or identify the fixture/test.
2. Record exact blocker facts in the port ledger.
3. Update this matrix from `not_reached` or `unknown` to `cleared`.
4. Link back to the relevant catalog row in
   [consensus-blockers-testnet4.md](consensus-blockers-testnet4.md).

Do not update this matrix to imply storage or Docker compliance. Those require
separate evidence under `Nodes/Shared/storage/`, `Nodes/Shared/chainstate/`, and
`Nodes/Shared/docker/`.
