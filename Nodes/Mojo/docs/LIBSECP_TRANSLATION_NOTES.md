# Mojo Pure Secp Translation Notes

This note documents the diagnostic pure Mojo secp256k1 path. It is not a
replacement for the comparable `libsecp256k1` proof lane.

## Source References

The implementation follows formulas and structure from Bitcoin Core's
`secp256k1` project:

- `src/field_10x26_impl.h`: field normalization and multiplication discipline.
- `src/scalar_8x32_impl.h`: fixed-width scalar parsing/order checks.
- `src/group_impl.h`: affine/Jacobian point operations.
- `src/ecmult_impl.h`: double-base multiplication and wNAF verification shape.
- `modules/schnorrsig/main_impl.h`: BIP340 verification flow.
- `modules/extrakeys/main_impl.h`: x-only Taproot tweak verification flow.

## Mojo Translation Choices

- The public byte-facing type remains the existing `U256` with eight
  little-endian `UInt32` limbs. This keeps current tests and backend wrappers
  stable while replacing the slow repeated-add field multiplication.
- Field multiplication now uses fixed-limb schoolbook multiplication plus the
  secp256k1 pseudo-Mersenne fold `2^256 = 2^32 + 977`.
- Group operations use Jacobian points internally, with mixed affine additions,
  so scalar multiplication no longer performs a field inversion for every
  point add/double.
- Schnorr verification computes `s*G + (-e)*P` in one interleaved double-base
  pass, then applies the BIP340 x-coordinate and even-y checks.
- Taproot tweak verification computes `Q = P + tweak*G` with Jacobian/mixed
  operations and preserves the native-style result classes.
- ECDSA/DER parsing is strict and diagnostic-only. Pure verification normalizes
  high-S signatures to match the current native vector/corpus result classes,
  rejects malformed DER/pubkeys and zero/out-of-range scalars, and reports
  unsupported rather than falling back to native.
- ECDSA keeps the original bit-by-bit double-base verifier as a correctness
  reference. The diagnostic path now also has a libsecp-guided wNAF verifier:
  scalar recoding follows the `secp256k1_ecmult_wnaf` shape, generator odd
  multiples are precomputed for small windows, and arbitrary public-key odd
  multiples are built per verification call.
- `pure-crypto-profile` records stage timings for DER parse, pubkey parse/lift,
  high-S normalization, scalar inverse, scalar multiplication, reference
  double-base, wNAF double-base, affine conversion, and native-result
  comparison. Profile JSON is Mojo-local diagnostic output under
  `.benchmark-results/`.

## Evidence Boundary

The pure backend is diagnostic-only. Native `libsecp256k1` remains the default
and comparable backend for script corpus, 5k, 50k, and later proof lanes. Pure
ECDSA/DER is enabled only for focused diagnostic vectors and the three
timing-gated P2PKH shadow rows: `scripts.p2pkh_sighash_single_38010`,
`scripts.p2pkh_61174`, and `scripts.p2pkh_107951`. P2PKH shadow rows emit
ECDSA sighash, verify, total, and signature-count timing fields. Other
ECDSA-bearing non-Taproot corpus shapes remain unsupported until a later
measured slice proves zero disagreements and the 5000ms per-row shadow
guardrail. The pure backend must not fall back to native.

This implementation does not claim constant-time hardening. It is a verifier
shadow path for differential testing and language-specific learning.
