# Consensus Crypto Backend Decision

Shared standardizes the crypto contract, test vectors, and serious-port
native acceleration target. Pure implementations remain valuable references,
but finish-line ports may use native `libsecp256k1` operationally after vector
and differential proof.

## Decision

```text
Required in every serious port:
  shared interface contract
  shared vector corpus
  strict failure semantics
  differential tests

Serious-port target:
  native libsecp256k1 binding for ECDSA/Schnorr/Taproot primitives

Reference/debug paths:
  pure local backend where practical
  BouncyCastle/platform/WASM comparators
```

Native crypto is allowed because Python, TypeScript, and BEAM ports are unlikely
to reach the binary gate with pure-language elliptic-curve code alone.

## Why Use One Native Target

Using native `libsecp256k1` everywhere improves performance and reduces
duplicated high-risk elliptic-curve work. The ports remain comparable because
they still own parsing, sighash construction, script evaluation flow, consensus
state transitions, P2P, sync, and blocker reporting.

The stronger shape is:

```text
shared vectors
  -> native backend wrapper
  -> optional pure/comparator backend
  -> differential proof
  -> benchmarked operational use
```

A backend that is faster but disagrees on one consensus edge case loses.

## Contract Requirements

Each port's crypto layer must define the same behavior even if method names
differ:

```text
verifyEcdsa(pubkey, msg_hash, signature, flags) -> bool/error
verifySchnorr(xonly_pubkey, msg_hash, signature) -> bool/error
taprootTweakPubkey(xonly_pubkey, merkle_root) -> tweaked_xonly/parity/error
parsePublicKey(bytes, flags) -> point/error
parseDerSignature(bytes, flags) -> signature/error
normalizeLowS(signature) -> signature/error
```

Inputs and outputs must be byte-oriented and explicit about encodings:

- compressed, uncompressed, and hybrid public keys
- x-only public keys and parity
- strict DER signature encoding
- low-S and malleability rules
- sighash-type byte handling
- BIP340 Schnorr vectors
- Taproot tweak and control-block edge cases

## Differential Test Rule

Any non-pure backend must be tested against the pure backend on the shared
fixture corpus:

```text
same input bytes
  -> pure backend result
  -> accelerated backend result
  -> exact match or backend disabled
```

The comparison must cover success, invalid-input failure, and consensus-invalid
failure. A library result that is merely "close" or accepts extra encodings is a
chain-split risk.

## Historical Port Posture

This table records the posture at the time this decision was written. Query
Project conformance results for current imported crypto proof evidence.

| Port | Historical authority | Library use | Then-next backend work |
|------|-------------------|-------------|-------------------|
| PythonNode | Pure Python secp256k1 | none for EC | Historical readable reference and fixture producer |
| TypeScriptNode | Pure TypeScript secp256k1 | `node:crypto` for hashing only | Preserve no-runtime-deps posture unless explicitly changed |
| JavaNode | Pure Java backend plus pluggable speed backend | ACINQ `libsecp256k1` JNI is available as `SECP256K1_BACKEND=native`; BouncyCastle remains a comparator | Keep pure path and differential-test BC/native accelerators |
| CSharpNode | Pure C# ECDSA today | BouncyCastle only for RIPEMD160 hash shim | Add pure BIP340 Schnorr, then optional accelerator behind an interface |
| CppNode | Not covered by current evidence | native libraries likely practical | Define pure/reference posture or an explicit conformance exception before acceleration |
| ElixirNode | Not covered by current evidence | NIF/native crypto would add packaging risk | Establish pure or audited local authority before native acceleration |

## C# Next Shape

CSharpNode should mirror Java's backend shape before Taproot work:

```text
ISecp256k1Backend
  PureCSharpSecp256k1Backend  // default authority
  optional accelerated backend
```

Add pure BIP340 Schnorr first. Only then consider BouncyCastle EC or native
`libsecp256k1` through P/Invoke, and only as an opt-in backend gated by
differential tests and replay benchmarks.

## Timing Metrics

Ports should keep crypto timing separate from script evaluation:

```text
script_ecdsa_verify
script_schnorr_verify
script_taproot_tweak_verify
script_sighash_legacy
script_sighash_witness
script_sighash_taproot
```

These timings decide accelerator priority, but they do not decide correctness.

## Independent reusable crypto lanes

`own_curve`, `ecosystem_curve`, and `c_binding` are independent dependency
categories, not readiness levels. Existing official baseline/native requirements
remain the C-binding comparison surface. The reusable own-curve 5k experiment
has separate commands, validators and Project results; it never replaces a
canonical baseline artifact or its leaderboard entry.

own_curve permits standard-library hashing, utilities and big integers, but no
existing elliptic-curve implementations, direct/transitive external production
dependencies without documented exceptions, or crypto FFI. ecosystem_curve
permits declared, pinned ecosystem curves, including Zig's standard-library
curve. C wrappers are bindings. The policy applies to standalone package
production dependencies; a node's RocksDB binding remains outside that boundary.

Each package must build independently, expose only public-input verification
operations, preserve explicit encoding/error semantics and integrate through a
thin node adapter. Test-only reference builds are pinned; candidate builds must
exclude alternative crypto backends. Trace/fault-injection builds are distinct
from measured candidate-only builds. Record library source digests, arithmetic
and hashing providers, toolchains, compiler settings and actual selected backend.

Project assembles `rb.crypto_lane_result.v1` artifacts from writer progress,
selecting results by port, lane, implementation and milestone. New evidence is
queried with `python3 Project/scripts/report.py --section crypto-lanes`.
Existing historical Zig artifacts retain their original identities and do not
become new own_curve proofs. New implementations remain experimental. A 5k
proof leaves `binary_gate_status=not_attempted`.
