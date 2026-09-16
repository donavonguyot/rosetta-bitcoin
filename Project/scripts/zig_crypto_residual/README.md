# Zig residual-performance campaign

This Project-owned campaign compares the first campaign's optimized package,
one independently derived candidate, and a fresh pinned C binding. It produces
`rb.zig_crypto_residual_comparison.v1` reports named `zig_residual_*`. It does
not change historical validators, canonical baseline claims, or current evidence.

The annotated tag in `baseline.json` preserves only the Zig package and node
changes. HEAD, the real Git index, and unrelated working changes are preserved.
The archive is reconstructible with `git archive` of that commit and its two
recorded paths. Runtime scratch stays under `Project/.campaigns/zig-residual`.

## Reproduction

Commands run from the repository root with Python 3, Zig 0.16.0, Docker/OrbStack,
and the existing local Reference P2P service. The prior campaign's pinned own-curve
builder supplies the initial profiling toolchain; record its immutable image ID.
New final images are built from the copied pinned Dockerfile and toolchain lock.
The C reference archive and host reference build are the verified test-only
artifacts prepared by the crypto-lanes tooling.

1. `freeze.py` creates a new freeze only when no baseline metadata exists. To
   reproduce this campaign, reconstruct the tagged archive into the scratch
   `frozen/` directory instead of freezing a later package.
2. `profile.py` profiles disposable frozen copies and records operation counts,
   nested timing, assembly, and the blocking roster. Fine timing has substantial
   observer cost; coarse timing decides the inversion trigger. Neither selects
   a winner. Exclusive child costs partition each measured root; inclusive
   ancestor costs must not be added again.
3. `workloads.py` creates deterministic tuning and separately seeded holdout
   workloads using the pinned reference only in test tooling. `variants.py`
   constructs named experiments from the frozen package; `experiments.py` runs
   the mandatory matrix and width sweep. `ablations.py` checks the selected
   width configuration with each helper removed. Measurements hold the shared
   replay lock. Never run independent correctness/profiling jobs alongside them.
4. `selection.py` applies paired component rules. `finalize.py WINNER` prepares
   the single package and standalone mathematical regeneration tool.
   `holdout.py` consumes the holdout once and publishes only after confirmation.
   A failed holdout selects the frozen baseline; do not retune against it.
5. Run `arithmetic.py candidate`, `counts.py baseline candidate`, and
   `build.py` for `baseline`, `candidate`, and `c_control`. Run
   `validate_candidate.py` and `x86.py` sequentially. Reference material and probes
   stay outside measured images. The JSONL differential consumer leaves the
   existing standalone consumer protocol unchanged.
6. `measure.py` warms each image once and performs nine rotated rounds, with a
   fresh volume for every run and one shared lock. An inconclusive elapsed
   interval causes one complete repeat. `assemble.py` writes compact comparison
   evidence only after all gates pass.

Experimental construction and rejection are recorded, including source digests,
operation counts, binary size, compiler settings, and the table-size tie-break.
A retained optimization is not a signing or side-channel claim. The binary tip
gate remains `not_attempted`.

## Independent mathematics

`derive.py` generates cube roots, pairs the endomorphism eigenvalue using affine
curve equations, reduces an exact integer lattice, and proves residual bounds.
It also symbolically checks the square-root chain and scalar-fold bound.
`glv.zig.in`, `field.zig`, and `inverse_limbs.zig` contain independently authored
experiments. No C code, optimization constants, tables, or recoding is copied or
translated. Published mathematical sources are documented in the package.

The canonical four-limb experiment retains runtime checks and canonicalizes every
operation. Losing experiments remain here as reproducible test tooling; they
are not runtime options in the reusable package.
