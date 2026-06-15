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

## 4. Standing dare: secp256k1 verification in your language

Every port's canonical path runs on one cryptography dependency behind a contract
seam: libsecp256k1. The dare: a verification-only secp256k1 backend in the port's
own language — ECDSA and BIP340 Schnorr verification, field and scalar arithmetic,
point decompression. No signing, no key handling: validation research, never for
use with funds.

Reference instance: the Zig port already ships a pure-Zig verification backend
(`Nodes/Zig/src/pure_secp.zig`) running as a shadow against libsecp256k1. Note
that Zig's standard library provides the secp256k1 curve, so that is the easy end
of the dare; the open frontier is languages with no curve in the standard library
(hand-rolled field arithmetic), and — for every backend, Zig included — surviving
the must-reject corpus of challenge 3, which does not yet exist.

Rails (all three are mandatory):

1. The backend is **added** behind the existing crypto-backend contract, never
   substituted; libsecp256k1 remains the permanent differential oracle.
2. Admission requires the shared native-crypto vector contracts **and** the
   must-reject corpus (challenge 3) **and** full-chain differential replay
   against the native backend.
3. Any divergence is ledgered as a blocker with provenance, pass or fail.

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
