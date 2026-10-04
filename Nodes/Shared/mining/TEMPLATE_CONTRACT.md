# Template Contract

Rung 0 assembles a block from the layer-1 pool and checks it with the port's
own block connect, without proof of work and without writing state. Selection
against Core's template is a fee-ratio diagnostic, not a pass/fail.

The difficulty and time rules below are Bitcoin Core 28.2 testnet4
(`CTestNet4Params` in `src/kernel/chainparams.cpp`, `GetNextWorkRequired` in
`src/pow.cpp`, and the BIP94 check in `ContextualCheckBlockHeader`). They are
not the testnet3 rules. `enforce_BIP94` is true. `fPowAllowMinDifficultyBlocks`
is true. The subsidy interval is 210000. Target spacing is 600 seconds. The
retarget window is 2016 blocks, which is `14 * 24 * 60 * 60 / 600`.

## Assembly bytes

For a fixed ordered transaction list and fixed coinbase parameters, every port
produces the same block bytes.

```text
coinbase version: 2
scriptSig: BIP34 minimal height push, then a push of the ASCII bytes
           RosettaBitcoin/zig
witness: one stack item of 32 zero bytes
output 0: value = subsidy + fees, script = 0x51
output 1: value = 0, BIP141 witness commitment
```

The subsidy at `height` is `5000000000 >> (height / 210000)` satoshis. Fees are
the sum of layer-1 input amounts minus output amounts for the selected
transactions. The witness merkle root uses 32 zero bytes as the coinbase
wtxid. The commitment is `double SHA256(witness_merkle_root || reserved)`
with `reserved` those same 32 zero bytes, stored as
`OP_RETURN 0x6a 0x24 0xaa 0x21 0xa9 0xed || commitment`.

```text
header version: 0x20000000
prev hash: the validated tip, internal byte order
merkle root: merkleRoot of the txids, coinbase first
nonce: 0
```

The byte-exact fixture freezes time, `nBits`, the previous hash, and the
transaction list. Live assembly may use the clock for time and must compute
`nBits` from the rule below.

`Nodes/Shared/fixtures/mining/assembly_bytes_v1.bin` holds those frozen bytes.
`Nodes/Shared/fixtures/mining/index.json` records the hash. Neither file is
part of the canonical fixture package.

## Time

Header time is the maximum of `mtp + 1` and the assembly clock, where `mtp` is
the median of the last 11 header timestamps ending at the tip. Core rejects a
block whose timestamp is less than or equal to the previous block's median time
past (`time-too-old`).

When `enforce_BIP94` is set and the block height is a positive multiple of
2016, Core also rejects a timestamp earlier than the previous block's timestamp
minus `MAX_TIMEWARP` (`src/consensus/consensus.h`, value 600). Live assembly
raises time to `previous_header_time - 600` when that floor is higher. Height 0
is not a candidate. This constraint is what the testnet3 description does not
have.

## nBits

`nBits` is the port's own `GetNextWorkRequired` for testnet4. The proof-of-work
limit is compact `0x1d00ffff`
(`00000000ffffffffffffffffffffffffffffffffffffffffffffffffffffffff`).

Let `height` be the block being assembled and `prev` the tip.

```text
if height % 2016 != 0:
  if the candidate timestamp > prev.timestamp + 1200:
    nBits = 0x1d00ffff
  else:
    walk back from prev while the header has a parent,
    its height is not a multiple of 2016, and its nBits is 0x1d00ffff
    nBits = that header's nBits
else:
  retarget from the first block of the period that is ending
```

The retarget timespan is `prev.timestamp - first.timestamp`, clamped to
`1209600 / 4` and `1209600 * 4` (`1209600 = 14 * 24 * 60 * 60`). Because
`enforce_BIP94` is true, the target that is scaled is the compact target of
the first block of that period, not the tip. The last block of a period may
itself be a minimum-difficulty exception, and Core keeps the real difficulty
on the first block so the exception cannot move the next period. The scaled
target is capped at the proof-of-work limit and encoded with Core's compact
conversion.

Header validation in the port does not yet enforce this `nBits`. Checking the
hash against the compact target stored in the header is not the same check.
That gap stays on the consensus lane.

The candidate timestamp used for the 20-minute exception is the time from the
section above, after the BIP94 floor.

## testblockvalidity

A port that claims assembly must connect the template with its own block
connect, skip the proof-of-work check, and write nothing.

The connect runs through a store wrapper. The wrapper forwards every read,
including UTXO lookups and header reads, to the real store. `commitConnectedBlock`
succeeds and discards the write. The wrapper is not an empty store. A template
that spends a confirmed output must see that output.

Before connect, the port rejects a duplicate txid and a block whose weight is
above `4000000`. Connect already rejects a repeated outpoint. It does not
compare txids, and it does not measure weight. Those two rejects live in the
template check.

Proof-of-work is not evaluated. The template parser still checks the merkle
root and the witness commitment.

## Selection

Selection is ancestor-package feerate under the block limits.

```text
package = the transaction plus its in-pool ancestors
compare fee_sum / weight_sum by cross-multiply
no floating point
weight limit 4000000
sigop cost limit 80000
```

Repeatedly take the highest package that fits the weight and sigops still
available. The tie-break is the lexicographic minimum child wtxid, internal
byte order. Sigop cost is the BIP141 block sigop cost (witness scale factor 4
on legacy sigops). It is not the tapscript validation budget inside the script
interpreter.

Weight of a transaction is `stripped_size * 3 + total_size`, with the witness
marker and flag included in `total_size` and excluded from `stripped_size`.

The fee ratio versus Core's recorded `getblocktemplate` fee total at the same
trace boundary is `port_fees / core_fees` when `core_fees` is non-zero. It is
reported per boundary, with the median across the trace. It does not pass or
fail the gate. Absent template data omits that boundary from the median.

## Fixture IDs

```text
mining.assembly_bytes
mining.testblockvalidity
mining.selection_fee_ratio
```

`mining.assembly_bytes` passes when the frozen parameters reproduce
`assembly_bytes_v1.bin`. `mining.testblockvalidity` passes when every template
built from the rung-0 pool is accepted by the port's own non-mutating connect,
a duplicate txid is rejected, and a block over the weight limit is rejected.
`mining.selection_fee_ratio` passes when each boundary reports a ratio or an
explicit omission, and the median is present. The ratio's distance from 1 is
not a failure.

## Out of scope

Proof-of-work search, fee estimation, `getblocktemplate` proposal mode as an
oracle, and changing header validation or block connect to enforce `nBits` or
transaction finality. Those remain consensus-lane gaps.
