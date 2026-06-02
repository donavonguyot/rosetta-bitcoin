# Native Crypto Contract

Ports that support native secp256k1 must report the selected backend explicitly
and prove the shared vectors locally.

## Required Status Fields

```text
native_crypto_backend
native_crypto_available
taproot_tweak_backend
```

## Rules

- Do not silently fall back to managed crypto in a native proof. If native crypto
  is requested and unavailable, fail the proof.
- Shared vectors live in `NodeCore/conformance/fixtures/`.
- Each port owns its wrapper and its local tests. Passing Java native crypto does
  not pass C# or any other port.
- Taproot x-only tweak behavior must report whether it is native-backed or
  managed; this field matters for P2TR key-path and script-path confidence.

## Current Evidence

- JavaNode uses ACINQ JNI bindings for native secp256k1 proofs.
- CSharpNode uses `Secp256k1.Net` for native secp256k1 proofs.
- Proof artifacts are categorized as smoke, storage gate, native crypto gate,
  bounded sync, and binary gate attempt.
