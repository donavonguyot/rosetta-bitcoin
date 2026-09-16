# libsecp256k1-go

Experimental, verification-only secp256k1 package in the **own_curve** lane.
MIT licensed; no external production dependencies, node imports, FFI or imported
curve implementations. Not affiliated with upstream libsecp256k1.

Arithmetic: Go math/big; this package does not implement custom integer arithmetic. Hashing: crypto/sha256.
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
CGO_ENABLED=0 GOWORK=off go test ./...
```

The separate project in examples/consumer imports only this package. Build it
with GOWORK=off CGO_ENABLED=0 go build . from that directory. Its protocol is:

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
