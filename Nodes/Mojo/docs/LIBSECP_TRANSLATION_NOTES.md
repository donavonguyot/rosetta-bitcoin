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
  ECDSA, Schnorr, Taproot, field-operation, and point-operation loops, keeps
  native comparison off by default, and reports per-stage totals plus
  per-iteration timing so math changes can be compared without live-proof or
  shadow-corpus overhead.
- A diagnostic 5x52 field core now exists beside the live 4x64 `U256` path.
  `Fe52` uses five 52-bit limbs in `UInt64`, tracks magnitude/normalization
  metadata, keeps add/negate lazy, and normalizes only for conversion,
  equality/zero checks, and tests. The fused `fe52_mul` / `fe52_sqr` routines
  follow libsecp's fixed accumulator schedule rather than the earlier
  product-array normalize loop. The host field microbench at 100k iterations
  reported zero mismatches and showed Fe52 beating 4x64 on the isolated field
- A diagnostic 5x52 group core now exists beside the live 4x64 point path.
  It includes affine/Jacobian Fe52 points, libsecp-style `gej_double`,
  mixed `gej_add_ge_var`, and binary scalar/double-base ladders for parity and
  timing only. The host point microbench at 1000 iterations reported zero
  mismatches and showed the Fe52 binary double-base path beating the 4x64
  binary reference (`200ms` vs `1074ms` in the latest fast run).
- Pure diagnostic ECDSA now routes through Fe52 plain WNAF. The path parses
  pubkeys into Fe52, uses Fe52 sqrt/inversion for lift, table conversion, and
  final affine conversion, and converts back only for the final x-vs-r
  comparison. The 1000-iteration host ECDSA microbench reported zero Fe52
  mismatches and reduced routed WNAF result timing from the old 4x64 GLV
  `788ms` to `80ms`.
- Fe52 GLV remains microbench-only. The generator-split diagnostic now splits
  both the fixed-base and variable-point scalars, derives `betaG` and `betaP`
  tables from the single existing odd-multiple tables, and proves the loop
  length drops from the old full-width `256` to `126` on the ECDSA microbench
  vector. The GLV hot path now applies endomorphism signs during table lookup,
  so copied/negated table materialization is zero in the microbench setup
  counters. The same 1000-iteration host run stayed parity-clean but still
  measured `88ms` for Fe52 GLV result versus `78ms` for plain Fe52 WNAF, so GLV
  remains unrouted until it demonstrates a material win.
- Fe52 SIMD lane-batch is diagnostic microbench-only. The first lane core uses
  `SIMD[DType.uint64, 4]` limbs plus `SIMD[DType.uint128, 4]` accumulators for
  homogeneous K=4 ECDSA WNAF batches, with scalar Fe52 as the correctness
  oracle. It deliberately does not route into live verification and does not
  claim mixed-lane support yet, because divergent WNAF digits need masked table
  selection. The 1000-iteration host `ecdsa-batch` microbench reported zero
  mismatches and measured scalar Fe52 WNAF result at `91us` per signature versus
  homogeneous SIMD4 Fe52 WNAF result at `46us` per signature.
- Pure diagnostic Schnorr now routes `s*G + (-e)*P` through the Fe52 WNAF
  double-base path. The preserved 4x64 reference helper still feeds focused
  parity checks, and the 1000-iteration host microbench reported zero Fe52
  mismatches while reducing Schnorr verification from `998ms` to `80ms`.
- Pure Taproot tweak checks now route `tweak*G + P` through the Fe52 scalar
  path. The 4x64 reference helper remains available for parity checks, and the
  1000-iteration host microbench reported zero Fe52 mismatches while reducing
  tweak verification from `780ms` to `66ms`. Fixed-base Taproot WNAF remains
  deferred.

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
benchmark truth. The current Docker 5k and 50k diagnostic replays have zero
unsupported pure-shadow script inputs and zero disagreements; they are
live-chain diagnostics, not replacements for native `libsecp256k1` proof
evidence. The latest Docker 50k shadow replay supports all `1385632` script
inputs with `28012` shadow parallel batches. Its post-Fe52 routing timing
buckets are dominated by ECDSA-family work: `segwit_v0=115019ms`,
`p2pkh_ecdsa=52738ms`, `taproot_schnorr=13294ms`, and
`taproot_tweak=9012ms`.

This implementation does not claim constant-time hardening. It is a verifier
shadow path for differential testing and language-specific learning.

## Deferred Libsecp Shapes

The live pure verifier path still uses the existing scalar inverse algorithm.
Safegcd, Fe52 GLV routing, mixed-lane SIMD WNAF masking, Taproot fixed-G
precompute, broader fixed generator tables, tagged-hash midstates, and replay
proofs are intentionally deferred to later measured slices.
