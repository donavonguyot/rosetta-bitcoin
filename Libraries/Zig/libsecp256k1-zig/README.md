# libsecp256k1-zig

Experimental, verification-only secp256k1 package in the **own_curve** lane.
MIT licensed; no external production dependencies, node imports, FFI or imported
curve implementations. Not affiliated with upstream libsecp256k1.

Arithmetic: Package-owned field/scalar operations with u257/u512 intermediates. Hashing: std.crypto.hash.sha2.Sha256.
Point operations use Jacobian coordinates and variable-time public-input scalar
multiplication. Signing, ECDH, recovery and all secret-key operations are absent.
Correctness and performance tests do not establish side-channel resistance.

## Public API

The source exports public-key parsing, x-only parsing, ECDSA verification,
low-S normalization, Schnorr verification, raw x-only tweak addition and checking.
Go names are ParsePublicKey, ParseXOnly, VerifyECDSA, NormalizeLowS,
VerifySchnorr, AddXOnlyTweak, CheckXOnlyTweak; Zig uses lower camel case and
verifyEcdsa. No Bitcoin script or transaction types cross the API boundary.

- Integers and coordinates use big-endian bytes. SEC1 accepts 33-byte compressed,
  65-byte uncompressed, and parity-consistent hybrid keys; rejects infinity,
  out-of-field coordinates and off-curve points. X-only keys are exactly 32 bytes
  and lift to the even-y point.
- ECDSA takes a 32-byte digest and bare DER, with no sighash suffix. Minimal DER
  integer/length encoding and complete consumption are required. Negative or
  out-of-range structurally encoded scalars produce invalid verification;
  nonminimal integers produce malformed-input errors. Valid high-S is accepted.
- Schnorr takes a 64-byte signature and arbitrary-length message. Its challenge
  uses BIP0340/challenge tagged SHA-256. Scalar zero is evaluated by the equation.
- Tweaks are raw 32-byte scalars, not Taproot roots. Zero is allowed; values at or
  above the order and infinity results return errors. Output includes parity.
- Verification distinguishes false from malformed-input errors. Normalization
  and tweak operations additionally report invalid scalar/infinity errors.
  Inputs are borrowed only for the duration of a call; no shared mutable
  arithmetic state is exposed. Parallel independent calls are supported.

Bitcoin sighash construction, signature suffix handling, TapTweak hashing,
script flags and policy checks belong to the consumer. High-S normalization on
our differential reference is intentional: raw upstream ECDSA verify rejects
high-S, while Bitcoin consensus verification may accept it. The reference bool
API cannot represent our error categories; fixtures independently check them.

## Build and use

```sh
zig build test -Doptimize=ReleaseSafe
```

The separate project in examples/consumer imports only this package. Build it
with zig build -Doptimize=ReleaseSafe from that directory. Its protocol is:

```text
consumer ecdsa|schnorr|tweak KEY_HEX MESSAGE_OR_TWEAK_HEX SIGNATURE_HEX
```

For tweaks, pass an empty final argument. It prints valid/consensus_invalid/
malformed_input or output_x_hex:parity. The example is also the external API
consumer used by the differential tests. Development path overrides occur only
in consumer manifests. Package tests require no RosettaBitcoin files or network.

Fixture snapshots retain the Shared 33 crypto cases and 19 BIP340 cases. The
repository validation harness checks their hashes against their source files.
The test reference is bitcoin-core/secp256k1 v0.6.0, commit
0cdc758a56360bf58a851fe91085a327ec97685a; it is never a production dependency.

Arithmetic details and coordinate assumptions are in [DERIVATIONS.md](DERIVATIONS.md).
Modular inversion and scalar multiplication are both variable-time on public
inputs. Verification uses independently derived GLV splits and separate-base signed
digits, with generated immutable generator and endomorphism tables. Test-only original algorithms independently check
arithmetic equivalence; they are not runtime fallback implementations.

Regenerate and verify optimization constants with `python3 tools/derive_constants.py`.
This optional development tool uses only Python standard-library integer arithmetic;
it is not a build or production dependency. All inversion and recoding operate
on public inputs and remain variable-time.

Generator table data is packaged with the source. Audit it with `python3 tools/generate_tables.py`; normal builds remain standalone. Variable tables use a common coordinate scale without field inversion. Inversion and scalar multiplication remain variable-time on public inputs. This remains an experimental verification-only package.
