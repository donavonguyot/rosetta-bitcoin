# Mempool Contract

Rung 0 defines one strict decision: is a transaction consensus-valid against the
current chainstate plus its in-pool ancestors? Relay policy is not that
decision. Reference Core is a byte source and a policy reference. It is not the
oracle for layer 1.

## Two layers

```text
layer 1:
  strict and cross-port
  inputs exist and are unspent
  scripts verify with the port's existing spend verifier
  locktime and BIP68 against the next height and MTP
  not a coinbase
  no in-pool double spend

layer 2:
  standardness, fees, limits, RBF, relay
  pinned as policy@core-<version>
  not a pass/fail verdict
```

Core 28 defaults to full RBF. A transaction Core relays can still be a correct
layer-1 reject when it spends an input an earlier unconfirmed trace transaction
already spends.

## Mempool set hash

The set hash is the same order-independent fold as `chainstate_set_hash`.

```text
entry = SHA256(wtxid)
set_hash = XOR of every entry
```

`wtxid` is the internal byte order of `double SHA256` over the witness
serialization, not the reversed hex used on the wire display and in RPC. The
value half of the fold is empty. XOR is its own inverse: accept folds an entry
in, eviction folds it out. The port reports the set hash after every applied
event.

`core_set_hash` at a block boundary is this same fold over the wtxids
`getrawmempool` returns after Core has processed that block. It is a diagnostic.
A difference is policy, not a failed gate.

## Check order

The first failure wins. Later checks are not reported.

```text
coinbase
  one input whose prevout hash is 32 zero bytes and whose index is 0xffffffff

input_spent_in_pool
  an input outpoint is already spent by a transaction still in the pool

input_spent_on_chain
  an input outpoint was spent by a block already connected in this replay
  and is not an unspent pool output

missing_input
  an input outpoint is neither in the store nor an unspent pool output

locktime_unsatisfied
  the transaction is not final for next_height and mtp

sequence_unsatisfied
  BIP68 relative lock fails for next_height and mtp

script_failed
  the port's existing spend verifier returns any error
```

`next_height` is the validated tip height plus one. `mtp` is the median of the
last 11 header timestamps ending at the tip, or fewer when the tip is shorter.
Odd count, so the median is the middle timestamp after sorting.

A transaction is final when every input sequence is `0xffffffff`, or
`lock_time` is 0, or (`lock_time < 500000000` and `lock_time < next_height`),
or (`lock_time >= 500000000` and `lock_time < mtp`). Otherwise the reason is
`locktime_unsatisfied`.

BIP68 applies when the transaction version is at least 2. An input whose
sequence has the disable bit `0x80000000` set is skipped. Otherwise the
relative lock is compared with the spent output's confirmation height, or with
the MTP of the block that created that output when the type bit `0x00400000`
is set. Units are blocks, or 512-second steps. A failure is
`sequence_unsatisfied`.

`script_failed` uses the spend verifier the port already uses for block
connect. Rung 0 does not add a script-flag bitmask. There is no orphan pool:
a missing parent is `missing_input`, not a deferred accept.

These locktime and sequence checks are layer-1 mempool checks. They do not
change block connect. Connect still lacks `IsFinalTx` and `SequenceLocks`;
that gap is a consensus-lane must-reject item, not closed by this contract.

## Trace fixture

A trace is a directory `Nodes/Shared/fixtures/mempool/trace-<sha256>/`. The
digest is the SHA-256 of a canonical tar of that directory only: paths sorted,
mode `0644`, mtime, uid, and gid zero, owner names empty. The same
canonicalization as `Project/scripts/build_fixture_package.py` `write_tar`.
The directory is not part of the canonical fixture package. Gate provenance
keeps the package pin in `fixture_hash` and records this digest as
`trace_hash`.

```text
manifest.json
events.bin
annotations.jsonl
boundaries.jsonl
mutations.json
```

`Nodes/Shared/fixtures/mempool/index.json` is schema `mempool.trace_index.v1`
and lists one row per trace: hash, path, chain, core version, window, counts,
and the policy string. It is not an entry in `fixture_package.json`.

### manifest.json

Schema `mempool.trace.v1`.

```text
chain
core_version
policy                  policy@core-<version>, explicitly policy
fixture                 live or synthetic
window.started_unix_ms
window.ended_unix_ms
window.stop_reason      time, bytes, or reorg
start_height
start_hash              display hex of the tip at capture start
preface_count
event_count
tx_count
block_count
raw_bytes               payload bytes, preface excluded from the cap
mutation_seed
set_hash                xor-sha256-wtxid-v1
```

A window that stops for `reorg` does not produce a directory. Blocks must form
one chain: the first block's previous hash is `start_hash`, and each later
block's previous hash is the previous block's hash, with height increasing by
one. Anything else is not a fixture.

### events.bin

Apply order. Each frame is little-endian:

```text
u32 apply_seq          starts at 1
u64 capture_unix_ms
u8  kind               1 = tx, 2 = block
u32 payload_len
payload                raw transaction or raw block
```

Preface transactions occupy the first `apply_seq` values. They are the Core
mempool snapshot from `getrawmempool` and `getrawtransaction`, taken after
`start_height` and `start_hash` are recorded and before the live window. The
200MB cap does not count them.

### Apply order

On-disk order is `apply_seq`, not arrival order. Arrival order cannot be the
replay order: Core announces by ancestor feerate and delays inventory per peer,
so a child can arrive before its parent. There is no orphan pool.

Within the preface, and within each run of transaction events between blocks,
sort by in-trace dependencies. If B spends an output created by A, A is applied
first. The sort is stable. Preface ties break by lexicographic internal wtxid.
Window ties keep the earlier `capture_seq`. Block events stay in capture order
and are not pulled through the transaction sort.

### annotations.jsonl

One object per event.

```text
tx:
  capture_seq          omitted for a preface row
  apply_seq
  preface              true or false
  txid                 display hex
  wtxid                display hex
  expected_layer1      accepted or input_spent_in_pool
  fee_sat              live arrivals only, from getmempoolentry
  vsize                live arrivals only
  ancestor_count       live arrivals only

block:
  apply_seq
  capture_seq
  hash                 display hex
  prev_hash            display hex
  tx_count
```

Fee, vsize, and ancestor count are diagnostic. `expected_layer1` is computed
on apply order. It is `input_spent_in_pool` when any input outpoint is already
spent by an earlier applied transaction that has not yet been removed by a
block. Otherwise it is `accepted`. The oracle is: the port's verdict equals
`expected_layer1`.

### boundaries.jsonl

One object per block, after that block is applied:

```text
apply_seq
height
hash
core_set_hash
core_pool_count
gbt                  null, or {captured_unix_ms, fees_sat, tx_count, txids}
```

`getblocktemplate` is polled every 10 seconds during the capture. The boundary
keeps the last result from before the block. With the preface in the pool, a
difference from the port's set hash is a policy difference.

### mutations.json

Schema `mempool.mutations.v1`. Rejects are generated from the trace. They are
not taken from Core's reject log.

```text
seed        0x524F5345545441
algorithm   xorshift64*
```

Generator state is a `u64`. Each step does `x ^= x >> 12`, `x ^= x << 25`,
`x ^= x >> 27`, and the shuffle key is `x * 0x2545F4914F6CDD1D` modulo 2^64.
The next step starts from `x` after the three xors, not from the product.
Shuffle is Fisher-Yates. Per class, shuffle the eligible transactions and keep
32.

Source transactions are those whose `expected_layer1` is `accepted`. Classes
and the recorded reason:

```text
script_failed
  flip the last byte of the last signature item
  a signature item is a witness stack item or scriptSig push that is
  64 or 65 bytes, or at least 9 bytes and DER-shaped
  (first byte 0x30, declared length matching the item)
  walk items from the end; a transaction with no such item is not eligible

input_spent_in_pool
  retarget one input to an outpoint already spent by an earlier
  still-unconfirmed transaction at that apply point

input_spent_on_chain
  retarget one input to an outpoint spent by a block already applied

locktime_unsatisfied
  set lock_time to next_height + 1
  if every sequence is 0xffffffff, set input 0 sequence to 0xfffffffe

coinbase
  replace the inputs with one null prevout and keep the outputs
```

Each row records the class, the source `apply_seq`, the mutated raw bytes, and
the expected reason.

## Replay

```text
sync the store to start_height
require the tip hash to equal start_hash
apply preface, then events, in apply_seq order
after each event, report the set hash
after each tx, report the verdict and the reason
on a block, connect it with the port's own block connect
then remove pool transactions whose txid is in the block,
transactions that spend an outpoint the block spends,
and their in-pool descendants
```

A store below `start_height` is synced. It is not a reason to switch to a
synthetic trace. A tip-hash mismatch fails the gate. Synthetic traces exist
only when Reference Core was unavailable for capture. Their `fixture` field is
`synthetic`, and they carry a block preface so replay can start from an empty
store. A reorg during a live capture does not become a synthetic trace.

Disconnect does not put transactions back. A port may expose the call, and the
call must fail loudly. Re-add on disconnect waits on tip work.

## Fixture IDs

```text
mempool.trace_replay_set_hash
mempool.layer1_verdicts
mempool.mutation_rejects
mempool.block_connect_eviction
```

`mempool.trace_replay_set_hash` passes when the set hash after each block
matches across the port's stores. Core's hash is recorded beside it.
`mempool.layer1_verdicts` passes when every trace transaction's verdict equals
`expected_layer1`. `mempool.mutation_rejects` passes when every mutation is
rejected with its recorded reason. `mempool.block_connect_eviction` passes when
a connected block removes the transactions it confirms and the transactions
that conflict with it.

## Out of scope

Policy, relay, `inv`/`getdata` as a port behavior, orphan handling, RBF
replacement logic, package relay, PoW search, `mempool.dat`, and Core
`getblocktemplate` proposal mode as an oracle.
