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
