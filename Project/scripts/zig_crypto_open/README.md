# Open Zig crypto campaign

This isolated experiment starts at the scoped tag recorded in `baseline.json`.
It does not select curated evidence or modify historical campaign validators.
The implementation is experimental public-input verification; the binary tip
gate remains `not_attempted`.

Run commands from the repository root. Scripts share the existing crypto replay
lock. Runtime outputs stay in ignored `Project/.campaigns/zig-open/`.

- `freeze.py` creates the scoped source archive once and snapshots canonical
  reports. It refuses to replace existing baseline metadata.
- `safety.py` builds the unchanged frozen package in ReleaseSafe and ReleaseFast
  in the pinned ARM64 builder. This is a whole-build diagnostic, not a formal
  upper bound on possible local speedups.
- `primitives.py` compares dependency-chain latency and four-stream throughput
  for widened arithmetic and checked/unchecked 5x52 kernels. It first runs the
  million-case arithmetic test inside Docker. Add/sub measurements include
  input confinement and iteration-dependent operand work; those costs are not
  subtracted. Assembly inspection is provided by `assembly.py`.
- `workloads.py` generates disjoint deterministic tuning, confirmation, and
  holdout sets using the pinned test-only reference. Generating the holdout does
  not authorize inspecting or tuning against its measurements.
- `control.py` builds upstream shared libraries with explicit windows, target
  flags and LTO settings, then measures the same public-API adapter. Shared
  linking permits GCC's LTO to finish within the library before Zig links the
  driver. These configurations must retain that linkage in final comparisons;
  they cannot silently be replaced by non-LTO static archives.
- `shared_z.py` constructs a disposable package with common-Z variable tables
  and runs package and point-equivalence tests. It does not publish this variant.

The remaining campaign gates must be completed before assembling a comparison
claim. Intermediate outputs are not `rb.zig_crypto_open_comparison.v1` results.

## Independent field derivation

Write a field value as five radix-2^52 digits, with a 48-bit high digit.
Magnitude m bounds each digit by m times its radix mask, for 1 <= m <= 8.
Convolution coefficients are below 5*(8*2^52)^2 < 2^113. Carrying the high
coefficients first allows the substitution 2^260 = 16*(2^32+977) modulo p
without exceeding u128. The low coefficients remain uncarried until reduction.

Carry the low coefficients, fold above bit 256, and carry again. After the
second fold only the low digit may exceed its mask, by at most 2^32+977.
If it does, the final carry cascade and top fold leave the low digit below
twice that complement, which is below 2^52. Other digits are masked. The result
fits 256 bits; canonicalization needs at most one subtraction of p.

Subtraction adds twice the operand magnitude times each modulus digit before
subtracting. Every modulus digit exceeds half its digit mask, so subtraction
cannot underflow under the declared input bounds. The output magnitude is
m_left + 2*m_right; addition uses m_left + m_right.

## Common-Z derivation

For Jacobian entries (X_i,Y_i,Z_i), form T as the product of nonzero Z_i.
Prefix/suffix products compute T/Z_i without division. The coordinates
(X_i*(T/Z_i)^2,Y_i*(T/Z_i)^3) lie on the common isomorphic curve with
coefficient 7*T^6. Scale generator lookup coordinates by T^2,T^3, perform
addition/doubling on that curve, and multiply the result's Z by T to return to
the original curve. Infinity is excluded from the product and preserved.
The a=0 formulas remain valid; this does not assume that raw coordinates on
different scales are equal. The cube-root endomorphism commutes with scaling.

## Batched inversion experiment

The divstep experiment uses the delta=1 Bernstein–Yang recurrence. Each batch
forms a signed 2x2 matrix for thirty steps, with row L1 norm at most 2^30.
Only the low 32 bits are needed to determine thirty branch decisions; applying
the matrix to the full signed integers and dividing exactly by 2^30 gives the
next state. Coefficients track f*2^k = v*input and g*2^k = r*input modulo m.
A package-computed table of inverse powers of two supplies the final correction.

The published bound for bit length d >= 46 is floor((49*d+57)/17); at d=256
this is 741. The implementation rounds up to 25 batches, or 750 steps, and
checks termination and gcd before returning. Random samples supplement this
bound; they do not establish it. The loop stops early on public inputs.
See the [Bernstein–Yang paper](https://gcd.cr.yp.to/papers.html#safegcd) and the
[explicit bound reproduced in the threshold-arithmetic research](https://www.mdpi.com/2410-387X/7/4/56).

The current point doubling already has two general multiplications and five
squarings. It cannot supply a separate improvement merely by being relabeled
2M+5S; any benefit must come from changed kernels or a different proved formula.

For C windows above 15, regenerate the upstream precomputed verification table
using the pinned upstream generator in test-only scratch. The release archive's
default table rejects width 16. Record the regenerated table hash and repeat
that generation in any final C image using width 16. No upstream table enters
the Zig candidate.

## Reproduction order

The full run is sequential. Do not run builds or reference work beside component
or node measurements. Commands use the ignored campaign directory for scratch.

1. `freeze.py`, `workloads.py`, `safety.py`, `profile.py`.
2. `primitives.py` for each documented correction pass; preserve prior raw output.
3. `control.py`, `confirm_control.py`, then freeze the selected C settings.
4. `shared_z.py`, `divsteps.py`, and their component measurements.
5. `sweep.py`, `choose.py`, `checkpoint.py`; build and measure `ablations.py` outputs.
6. `prepare_candidate.py`, package formatting, `arithmetic.py candidate`,
   `compile_cost.py`, `cache_diagnostic.py`, `divstep_counts.py`.
7. `holdout.py` exactly once, then `publish.py`. Failed holdout selects baseline.
8. `build.py baseline`, `build.py candidate`, `build.py c_control`; run
   `arithmetic.py candidate`, `counts.py baseline candidate`, `x86.py`, and
   `validate_candidate.py` against the final package identity.
9. `measure.py` for the rotated fresh-volume comparison, then `decisions.py`,
   `inspect_assembly.py`, and `assemble.py`.

Use `comparison.py <report>` to verify the cross-artifact gates. The JSON schema
is a structural boundary; the Python validator also checks source identities,
proof invariants, rotation, and campaign-local correctness floors. Unit tests
are `test_tooling.py` and `test_comparison.py`.

The three-operation score intentionally includes parsing both inside verification
and as its own workload. It is not an additive time budget. Cache disturbance
results are diagnostics, not cache-miss measurements. Allocations are not
instrumented; allocator-free operation APIs alone are not allocation measurements.

The comb experiment uses t teeth and ceil(129/t) rows. Tooth j represents
2^(j*rows)G. At loop position i, a table lookup selects the bits i+j*rows of
the split scalar. The generator additions occur during the last `rows`
iterations of the variable-point loop. This does not eliminate that loop's
doublings. Its packed zero entry is an infinity sentinel, checked before use.
