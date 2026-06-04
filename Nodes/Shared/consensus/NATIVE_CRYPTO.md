# Native Crypto Substrate

Serious ports may use native `libsecp256k1` for consensus crypto acceleration
after passing the shared vector gate. Native crypto accelerates elliptic-curve
operations only; ports still own transaction parsing, sighash construction,
script execution, consensus state, and validation decisions.

## Required API Shape

Wrappers should expose byte-oriented methods equivalent to:

```text
verify_ecdsa(pubkey_bytes, msg_hash32, der_signature_with_optional_sighash, flags) -> result
verify_schnorr(xonly_pubkey32, msg_hash32, signature64) -> result
parse_pubkey(pubkey_bytes, flags) -> result
parse_xonly_pubkey(xonly_pubkey32) -> result
taproot_tweak_xonly(xonly_pubkey32, merkle_root32_or_empty) -> tweaked_xonly32, parity
normalize_low_s(der_signature) -> normalized_der_signature
```

Results must distinguish:

```text
valid
consensus_invalid
malformed_input
backend_unavailable
```

## libsecp256k1 Modules

Required build/module coverage:

- ECDSA verification.
- Schnorrsig verification.
- X-only public key parsing.
- Taproot tweak verification.
- DER parsing behavior compatible with Bitcoin consensus flags.
- Low-S normalization where the port's script flags require it.

## Operational Gate

Native crypto can be default only when:

```text
shared native_crypto_v1 vectors pass
differential tests against an existing local/comparator backend pass where available
backend name/version is reported in proof JSON
native backend unavailable path fails closed or falls back only when configured
timing metrics are reported separately from script interpreter timing
```

## Initial Vector Corpus

The initial shared corpus is
`Nodes/Shared/conformance/fixtures/native_crypto_v1_vectors.json`.

Vector groups:

- `ecdsa`: valid and invalid DER/pubkey/message combinations.
- `schnorr`: BIP340-style valid and invalid signatures.
- `taproot`: x-only tweak vectors and malformed-key cases.
- `parse`: public-key and DER encoding edge cases.

Ports may add local stress cases, but they must not weaken or reinterpret the
shared expected results.
