# Mojo Pure Secp Translation Notes

This note documents the diagnostic pure Mojo secp256k1 path. It is not a
replacement for the comparable `libsecp256k1` proof lane.

## Source References

The implementation follows formulas and structure from Bitcoin Core's
`secp256k1` project:

- `src/field_5x52_impl.h` and field entrypoints: field normalization and
  multiplication discipline.
- `src/scalar_4x64_impl.h`: fixed-width scalar parsing/order checks and
  complement-fold product reduction.
- `src/group_impl.h`: affine/Jacobian point operations.
- `src/ecmult_impl.h`: double-base multiplication and wNAF verification shape.
- `modules/schnorrsig/main_impl.h`: BIP340 verification flow.
- `modules/extrakeys/main_impl.h`: x-only Taproot tweak verification flow.

## Mojo Translation Choices

- The public byte-facing type remains `U256`, but its internal representation is
  now a stack-resident `InlineArray[UInt64, 4]` with little-endian limbs. The
  helper API still accepts and emits 32-byte big-endian values, so current tests
  and backend wrappers stay stable while the hot path avoids heap-backed
  `List[UInt32]` field/scalar temporaries.
- Field multiplication now uses fixed-limb schoolbook multiplication plus a
  fixed two-fold reducer for the secp256k1 pseudo-Mersenne identity
  `2^256 = 2^32 + 977`. The old iterative high-limb fold/normalize loop is
  not in the verifier hot path. A bounded final carry fold preserves any
  remaining limb above `2^256` before the conditional subtract step, so the
  reducer never treats the top carry as zero.
- Field squaring has a dedicated 4x64 square product: four diagonal products
  plus six doubled cross-products, followed by the same fixed field reducer.
  `_fe_sqr` no longer routes through `_fe_mul(a, a)`.
- Scalar multiplication/reduction now uses the same 4x64 product shape with
  `UInt128` carry handling plus the libsecp 4x64 complement constants
  `N_C_0 = 0x402DA1732FC9BEBF`, `N_C_1 = 0x4551231950B75FC4`, and `N_C_2 = 1`.
  The old shifted compare/subtract scalar reducer is not in the verifier hot
  path. As with field elements, remaining high scalar limbs are folded back
  with the complement constants before final overflow correction. Field/scalar
  callers route directly to their modulus-specific multiplication paths instead
  of paying runtime modulus dispatch.
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
  reference. The old wNAF path remains as a parity oracle. The diagnostic path
  now routes through a libsecp-guided wNAF/GLV
  verifier: scalar recoding follows the `secp256k1_ecmult_wnaf` shape, generator
  odd multiples are precomputed for small windows, and arbitrary public-key odd
  multiples are built per verification call. The per-call public-key table is
  now built in Jacobian form and converted with one Montgomery-style batched
  field inversion, mirroring `ge_set_all_gej`, instead of paying one affine
  inversion per odd multiple. The ECDSA variable scalar is split with the
  libsecp lambda constants, sign-folded against `n/2`, and evaluated as
  `u1*G + s1*Q + s2*betaQ`; the `betaQ` table is derived from the one `Q` table
  by multiplying affine x coordinates by beta, so no second table inversion is
  introduced.
- Field inverse and square-root now use the secp256k1 addition-chain block
  structure rather than generic Fermat exponentiation. `_pow_mod_field` remains
  as a reference/test helper, but live `_fe_inv` and `_fe_sqrt` route through
  the addition-chain tails.
- `pure-crypto-profile` records stage timings for DER parse, pubkey parse/lift,
  high-S normalization, scalar inverse, scalar multiplication, reference
  double-base, old wNAF double-base, GLV double-base, affine conversion, and
  native-result comparison. Profile JSON is Mojo-local diagnostic output under
  `.benchmark-results/`.
- `pure-crypto-microbench` is the tuning instrument. It runs fixed pure-only
  ECDSA, Schnorr, and Taproot vectors in fast loops, keeps native comparison off
  by default, and reports per-stage totals plus per-iteration timing so math
  changes can be compared without live-proof or shadow-corpus overhead.

## Evidence Boundary

The pure backend is diagnostic-only. Native `libsecp256k1` remains the default
and comparable backend for script corpus, 5k, 50k, and later proof lanes. Pure
ECDSA/DER is enabled only for focused diagnostic vectors, the three timing-gated
P2PKH shadow rows: `scripts.p2pkh_sighash_single_38010`,
`scripts.p2pkh_61174`, and `scripts.p2pkh_107951`, the first bare legacy and
bare multisig rows: `scripts.bare_legacy_118555` and
`scripts.bare_multisig_27840`, the 10 simple P2SH legacy rows, and all SegWit
v0/P2WSH rows. P2PKH shadow rows emit ECDSA sighash, verify, total, and
signature-count timing fields. Full corpus shadow support remains diagnostic
and native-first; the pure backend must not fall back to native.

The live `local-reference-proof --shadow-crypto` path follows the same boundary:
native validation remains the block-acceptance oracle, while pure Mojo crypto
only produces diagnostic replay counts and disagreement context. Its proof JSON
is explicitly `diagnostic_non_comparable` and must not be imported as Project
benchmark truth. The current Docker 5k diagnostic replay has zero unsupported
pure-shadow script inputs and zero disagreements; it is a live-chain diagnostic,
not a replacement for native `libsecp256k1` proof evidence.

This implementation does not claim constant-time hardening. It is a verifier
shadow path for differential testing and language-specific learning.

## Deferred Libsecp Shapes

The current pure path still uses the existing scalar inverse algorithm, the
current Schnorr/Taproot multiplication routing, and exact 4x64 normalization
after each operation. Safegcd, Schnorr wNAF/GLV routing, Taproot fixed-G
precompute, broader fixed generator tables, tagged-hash midstates, and any
5x52 lazy field representation are intentionally deferred to later measured
slices.
