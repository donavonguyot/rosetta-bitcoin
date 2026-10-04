# Challenges

RosettaBitcoin is structured so that its remaining experiments can be run by
anyone. This page is the signup sheet. The rules are the same ones the project
applies to itself: claims require artifacts, failures get ledgered with
provenance, and Reference Core is a byte source, never a validity oracle.
Security-relevant findings follow [`SECURITY.md`](SECURITY.md).

## 1. Race the ports

The benchmark suite defines comparable lanes with fixed knobs. The normative
contract is
[`Nodes/Shared/conformance/BENCHMARK_CONTRACT.md`](Nodes/Shared/conformance/BENCHMARK_CONTRACT.md);
leaderboards are generated only from canonical artifacts that satisfy the shared
validator.

```bash
python3 Project/scripts/report.py --db Project/project.db --section benchmark-suite
python3 Project/scripts/report.py --db Project/project.db --section leaderboard --gate shakedown_50k
python3 Project/scripts/preflight_port_baseline.py --db Project/project.db --port <port> --strict
```

Faster runs — on your hardware, with your model budget — are admissible the
moment they import cleanly.

## 2. Add a language

The follower path is a repeatable experiment: blocker ledger in, fixtures in,
contracts in, independent implementation out. Each new port doubles as a
measurement of the substrate's completeness — a port that needs discovery-priced
intervention has found a gap in the compiled ledger, which is itself an
importable finding. Start with the canonical read order in
[`README.md`](README.md).

One exception: the Mojo follower run is preregistered to the project, because a
first run can only happen once and its scientific value lies in its invocation
instrumentation. Every other language ecosystem is open ground.

## 3. Build the negative corpus

The substrate's least-developed organ. Replaying the valid chain proves the
absence of false rejections; only crafted must-reject cases address false
acceptance. Wanted: invalid-case fixtures the live chain never supplies — DER
strictness edges, high-s signatures, BIP340 lift_x bounds, hybrid encodings, and
per-blocker forgeries — added to the shared conformance corpus with provenance.
This is the highest-value, lowest-glamour contribution available, and it is the
admission gate for the standing dares below.

## 4. Reusable secp256k1 verification components

Build an independently importable verification library and a thin node adapter.
The library owns public-key parsing, ECDSA/Schnorr verification and raw x-only
public tweaks. The node owns Bitcoin sighashes, script flags and Taproot rules.
Signing and secret-key operations are separate future work. Describe new
implementations as experimental; correctness does not establish side-channel
resistance.

Three independent lanes are open:

| Lane | Curve implementation |
| --- | --- |
| `own_curve` | Implemented in the package, with standard-library utilities, hashing and big integers allowed; imported curves and FFI prohibited. |
| `ecosystem_curve` | Imported from the language ecosystem, including standard-library curves; record and pin dependencies. |
| `c_binding` | C libsecp256k1 behind an explicitly named binding. |

These lanes are not a ladder. An ecosystem entry is valid without qualifying
for own_curve. Zig's existing standard-library backend belongs to ecosystem_curve;
its historical `pure` name does not mean package-owned arithmetic.

A submission includes package metadata, API/error/encoding documentation, license,
tests, usage example, isolated offline build and an external public-API consumer.
Production dependencies must be disclosed transitively. own_curve initially uses
only allowed standard-library facilities; external utilities require a documented
exception before adoption. Test references never become runtime fallbacks.

Admission to the bounded 5k experiment requires shared crypto vectors, negative
and boundary cases, pinned-upstream differential tests, adapter usage and failure
injection, the 45-fixture script corpus, and candidate-only fresh Docker P2P
proofs through 5000. Component and node benchmarks are separate. Full-chain
replay and tip participation remain further evidence, not implied by 5k.
Divergences remain blockers with input bytes and reference provenance.

The initial own_curve packages live under `Libraries/Go/libsecp256k1-go` and
`Libraries/Zig/libsecp256k1-zig`. Current results come from Project's `crypto-lanes`
report, separately from the canonical C-backed baseline leaderboard. The pinned
reference is test-only; default node backends remain independently selectable.

## 5. Standing dare: native storage in your language

The other shared dependency. The dare: a chainstate engine in the port's own
language, **added** behind the storage codec contract
([`Nodes/Shared/storage/`](Nodes/Shared/storage/)), with RocksDB remaining the
permanent differential truth. Admission requires codec-contract conformance,
full-replay equivalence with chainstate-hash parity at every checkpoint, and
crash-recovery evidence under the existing datadir disciplines.

Together, dares 4 and 5 define a sovereignty ladder any port can climb:
contract-compliant port, then native-crypto backend, then native-storage
backend, then a fully self-hosted port — zero C dependencies, the entire node in
its own language. No one can scoop anyone: every language has its own rungs, and
every attempt deposits fixtures into the substrate whether it passes or not.

## 6. The binary gate

No port yet holds live tip from empty state on the public network. The gate is
defined in [`Nodes/Shared/SPEC.md`](Nodes/Shared/SPEC.md), the evidence path is
defined, and that leaderboard is empty.

## 7. Open experiments, ranked

Each of these has a binary oracle and a known cost class, so each can be run,
priced, and ledgered the same way. Ranked by what a pass deposits into the
substrate, not by how impressive it sounds. Compute-only means no model budget is
required to judge the result.

1. **Set hash across every port.** Add the incremental, order-independent
   `chainstate_set_hash` (first landed in ZigNode's store seam) to each port's
   commit path and proof JSON. Oracle: every active port reports the same hash at
   5k, 50k, and 100k. Cost: compute only. Deposits: a consensus oracle that
   depends on no storage engine, no single port, and not on Reference Core; and
   one near-identical ladder task in every language. Stretch rung: MuHash parity
   with Core's `gettxoutsetinfo`, which makes the hash externally checkable.

2. **Mechanical optimization campaigns.** One hot stage, one metric, a fixed
   oracle, one commit per shape change with the measured delta in the message,
   and anything that does not move the metric outside noise is reverted and
   recorded. The ZigNode `utxo_load` allocation campaign is the template. Run the
   same shape on `block_parse_validate`, script dispatch, and P2P prefetch, in
   more than one port. Deposits: measured cost-in, gain-out rows for repeatable
   optimizations.

3. **Snapshot as a verified starting state.** A native-store snapshot carries
   its set hash. Oracle: load, recompute, match, then run the gate from there.
   Cost: compute only, and it lowers the compute of every later long gate by
   letting 100k start from a verified 50k. Once the format is in Shared, a
   snapshot that another port loads and hashes identically is a stronger storage
   proof than the storage gate itself.

4. **Fuzzing with differential oracles.** Fuzz the script interpreter, tx/block
   parsers, Codec v2, and commit-log replay. Oracle: the other ports, plus the
   cross-port set hash. Cost: compute only. Deposits: must-reject fixtures found
   by disagreement rather than imagination; every finding lands in Shared whether
   or not anyone fixes it that day.

5. **Fresh-port races at the 5k gate.** The original port race, now with
   fixtures pinned by content hash. Oracle: the 5k baseline. Cost: model budget.
   Deposits: volume. This is the cheapest place to learn harness effects; it does
   not stand in for the long gates.

6. **Native-store test shapes as Shared fixtures.** Torn tail, crash before and
   after the log append, snapshot rename before log truncate, as fixture IDs
   under the storage gate. Cost: small, one-time. Deposits: an admission test for
   dare #5 instead of an argument.

7. **Zero-C audit and reproducible builds.** For any port claiming the
   self-hosted rung: no libc where the language can avoid it, a binary hash and
   source commit in every gate line, and a CI build-twice check. Cost: small.
   Deposits: a sovereignty claim anyone can verify mechanically.

8. **Real peers, reorg, tip.** Required for the binary gate, not optional, but
   its oracle is partly environmental and its runs are long and noisy. Do it when
   a lane needs it, not as a standalone experiment.

If you only pick two: #1 is the broadest cheap grid available, and #3 lowers
the price of everything after it.
