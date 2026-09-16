# Independent Zig optimization results

Experimental verification-only own_curve implementation. No C code or tables were copied or translated. Public behavior and package dependency policy are unchanged.

| Variant | 5k elapsed median (range), s | Script wall median, s | Thread CPU, µs/script job | ECDSA median, µs/op |
| --- | ---: | ---: | ---: | ---: |
| original | 18.213 (18.073–18.409) | 16.506 | 605.351 | 589.921 |
| optimized | 3.279 (3.205–3.391) | 1.742 | 56.180 | 46.745 |
| c_control | 2.287 (2.239–2.308) | 0.777 | 20.670 | 17.248 |

All nine measured runs reached height 5000, the expected hash, and 4,574 UTXOs. Each warmup and measured run used a distinct fresh volume. The sequence rotated original/optimized/C, optimized/C/original, C/original/optimized under one replay lock.

The optimized node is about 5.6× faster end to end than the original, with about 9.5× less script wall time. It remains about 1.43× slower overall than the fresh C control. Worker CPU includes interpreter, hashing, and scheduling; it is not pure signature cost.

Final comparisons used Docker ARM64, Zig 0.16.0 ReleaseSafe, four workers, prefetch four, RocksDB 7.8.3-2 with WAL enabled, and local Reference P2P. Components used identical inputs and five repetitions of 1,024 operations. The C control was rebuilt from pinned v0.6.0 with the same instrumented node source; June evidence was not reused.

Stage measurements were separate host ARM64 runs, two batches of five repetitions each. Do not compare their absolute timings directly with the final Docker component timings.

| Stage | Target | Median before → after, µs (batch 1 / batch 2) | Targeted count before → after |
| --- | --- | --- | --- |
| stage1 | schnorr/valid | 94.99 → 90.50 / 94.21 → 89.04 | field_mul: 12707 → 8832 |
| stage2 | ecdsa/valid | 636.97 → 94.68 / 640.41 → 95.74 | scalar_fermat: 1 → 0 |
| stage3 | ecdsa/valid | 94.68 → 93.28 / 95.74 → 92.51 | binary_inverse: 2 → 1 |
| stage4 | ecdsa/valid | 93.28 → 41.75 / 92.51 → 42.15 | field_mul: 8325 → 3379 |

The final counted ECDSA path used 3,379 field multiplications, 258 doublings, seven variable-table additions, and 84 mixed additions. Counters existed only in disposable test builds.

Validation passed: 52 shared vectors; 10,000 deterministic arithmetic iterations; 10,005 generated API differential cases; 600 malformed subprocess cases; offline package and external-consumer builds; parallel use; 45/45 script corpus; backend rejection; and 104,146 traced calls without reference differences. Fault injection stopped at validated height 738 before committing failing block 739.

The package uses variable-time binary inversion, inversion-free ECDSA comparison, independently derived mixed addition, and separate-base width-5 Straus multiplication. Generator tables are calculated at compile time, not pasted. Original algorithms are test-only comparators.

Existing current-evidence selections and canonical baseline/leaderboard output are unchanged. New candidate artifacts are uncurated. This comparison label is campaign-local and cannot establish canonical baseline eligibility. Binary tip gate: `not_attempted`. No signing or side-channel-resistance claim.

The documentation drift check still reports the pre-existing missing `Docs/substrate_pipeline.pdf`; no new broken documentation links were found.

[Machine-readable comparison](zig_optimization_20260916T053740Z.json) · [Reproduction instructions](../../../../Project/scripts/zig_crypto_campaign/README.md)
