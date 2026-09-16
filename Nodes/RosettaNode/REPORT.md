# RosettaNode experiment report

**Go initial result: observed improvement.** The document arm passed all evaluated families in all three attempts. Every Go control passed valid-chain composition, while the synthetic profile cases exposed differences. This is a small descriptive experiment, not a statistical or language-superiority claim.

## Initial Go submissions

Scores average semantic families within each group. Chain composition is reported separately; its 80,376 requests cannot outweigh the profile or structured families.

| Attempt | Arm | Encoding | Profile | Structured | Valid chain |
|---|---|---:|---:|---:|---:|
| D1 | document | 100% | 100% | 100% | 100% |
| D2 | document | 100% | 100% | 100% | 100% |
| D3 | document | 100% | 100% | 100% | 100% |
| C1 | control | 100% | 84% | 100% | 100% |
| C2 | control | 75% | 74% | 0% | 100% |
| C3 | control | 75% | 74% | 0% | 100% |

The control structured scores need care: C2 and C3 treated negative output amounts as unsigned or rejected them. The synthetic structured families share negative amounts, so a single signedness defect accounts for many failures. A zero here does **not** establish absence of a serializer. Signedness also causes the ordinary prefix fixture to fail its returned-object comparison; that failure does not independently demonstrate a cursor bug. Family scores are not independent. Their successful valid-chain checks illustrate why valid data alone was insufficient.

All three Go controls passed only 1 of 5 resource-precedence cases: they accepted complete over-budget objects and classified some truncated/trailing inputs as resource-limited. C1 had no signedness defect and still scored 84% on the profile group, isolating an observed profile disagreement beyond the correlated amount failures. The frozen scoring is retained unchanged.

## Separate Go repairs

Each failing control received one bounded counterexample-assisted repair opportunity. These results do not alter the initial transfer result. No repair was needed for the perfect document submissions.

| Attempt | Encoding | Profile | Structured | Valid chain |
|---|---:|---:|---:|---:|
| C1 | 100% | 92% | 100% | 100% |
| C2 | 100% | 84% | 100% | 100% |
| C3 | 100% | 84% | 100% | 100% |

## Conditional cross-language pairs

One document/control pair per language under the frozen packet and semantic evaluator. Results are exploratory and are not pooled with Go or used to rank languages. Initial scores remain separate from counterexample-assisted repairs.

| Language | Arm | Attempt | Encoding | Profile | Structured | Valid chain |
|---|---|---|---:|---:|---:|---:|
| rust | document | RD1 | 100% | 100% | 100% | 100% |
| rust | control | RC1 | 75% | 74% | 0% | 100% |
| zig | document | ZD1 | 100% | 100% | 100% | 100% |
| zig | control | ZC1 | 75% | 74% | 0% | 100% |

Both cross-language document submissions passed every evaluated family. The Rust and Zig controls showed the same unsigned interpretation of negative amounts as C2/C3, plus resource-profile disagreements. Their zero structured scores carry the same correlated-fixture limitation; both controls passed valid-chain composition. This is consistent with the Go packet effect, not evidence of a language ranking.

Cross-language repairs, separately scored:

| Attempt | Encoding | Profile | Structured | Valid chain |
|---|---:|---:|---:|---:|
| RC1 | 100% | 84% | 100% | 100% |
| ZC1 | 100% | 84% | 100% | 100% |

## Instrument evidence

- CompactSize gate: 85 cases per build, JIT/unoptimized/optimized agreement, canonicality mutation and unaffected controls, ASan seeded heap fault, rendered packet. Gate wall interval was 490.3 seconds, an upper bound on active work and below eight hours.
- Alive2: **unsupported**, because `alive-tv` was unavailable. No translation proof is claimed.
- Transaction execution: 240 cases agree across JIT/unoptimized/optimized execution, with a clean ASan lane. Eight semantic mutations have intended kills, complete matrices and passing designated controls.
- Reachability: 18/18 authored symbols reached. Block gaps remain: `cs_decode:four`, `cs_encode:loop`, `cs_encode:short`, `write_bytes:reject`, `tx_serialize:invalid`, `tx_digest:failure`. CompactSize has additional independent gate coverage; this is not exhaustive path coverage.
- Independent Python commitment checker: 45 shared blocks (16,954 transactions), 5,001 reference blocks (23,234 transactions); 40,188 transaction comparisons. It uses the last BIP141 commitment output and exact coinbase reserved-value shape. Altered commitments and transaction order are tested.
- Structured-only, modified-field and decode-history challenges prevent retained bytes alone from satisfying the contract. Bounded randomized checks supplement the frozen cohort corpus.
- Core 28.2/BIP provenance is hash-pinned. btcd is an evaluator-only comparison; disagreements and the existing Python port’s first-match commitment behavior are recorded without changing other ports.
- Fresh containers reproduce reference test manifests and normalized document text. Fresh sandbox workspaces reproduce every initial and repaired candidate semantic result. These are clean environments on the same physical host, not independent hardware qualification.

## Isolation, timing and accounting

All attempts use fresh local Codex sessions and the same model/configuration. Reading has a separate 15-minute allowance, implementation 60 minutes, and one repair 30 minutes. The candidate tool filesystem denies repository, evaluator, other attempts and user configuration reads; network probes are denied. Native image access was also tested. Compiler/library preparation is outside attempt timing. Standard-library dependencies only; no Bitcoin libraries. The model service connection is separate from denied candidate tool networking.

Agents receive the Markdown packet corresponding to the PDF’s semantic content; this tests contract transfer, not PDF-reading ability. The frozen sentence inventory specifies the information difference. Temperature and seed are not exposed by this runner.

| Attempt | Reading s | Initial s | Repair s |
|---|---:|---:|---:|
| D1 | 27.9 | 931.7 | — |
| D2 | 35.6 | 568.0 | — |
| D3 | 33.4 | 753.5 | — |
| C1 | 30.7 | 730.1 | 250.5 |
| C2 | 32.4 | 678.6 | 267.1 |
| C3 | 34.9 | 513.7 | 162.6 |
| RD1 | 43.2 | 957.9 | — |
| RC1 | 29.1 | 696.7 | 217.2 |
| ZD1 | 43.1 | 560.3 | — |
| ZC1 | 34.0 | 673.5 | 250.6 |

CLI-reported usage totals across reading, initial and repair phases (cached/reasoning fields are subsets, not additive charges):

```json
{
  "input_tokens": 6656471,
  "cached_input_tokens": 6002176,
  "cache_write_input_tokens": 0,
  "output_tokens": 265041,
  "reasoning_output_tokens": 62996
}
```

Monetary cost, parent-agent model usage, exact parent active time and per-iteration latency are unknown. Phase times are measured; they overlap and must not be summed as wall-clock campaign duration. Final gate commands and complete candidate event logs are retained; early parent exploratory tool calls were not completely counted. Candidate-reported ambiguity and completion notes are retained verbatim in `evidence/attempt-observations.json`; they are self-reports, not evaluator findings.

## Source and deliverables

| IR artifact | Ownership | Physical lines |
|---|---|---:|
| `generated/compactsize.ll` | literally extracted authored IR | 100 |
| `generated/transactions.ll` | literally extracted authored IR | 424 |
| `generated/support.ll` | mechanically generated | 148 |

The IR owns transaction byte parsing, emission and double-SHA composition. C supplies SHA-256; Python marshals JSON/ABI values, handles transport admission and presents digest display order. Those boundaries are disclosed rather than attributed to the IR.

- Full book: `.local/transaction-book/rosettanode.pdf`.
- Reconstruction packet: `.local/transaction-book/reconstruction.pdf` and `.md`.
- Frozen protocol and source identities: `evidence/cohort-freeze.json`, `evidence/cross-language-freeze.json`.
- Primary results: `evidence/transfer-report.json`, `evidence/cross-language-report.json`.
- Complete local attempts: `.local/cohort/<attempt>/`, including logs, frozen initial and repair source.
- Acceptance: `python3 tools/validate_artifacts.py` from this directory.

This result does not establish consensus validity, node readiness, completeness of Bitcoin’s specification, or an advantage for directly authored IR over an equivalent high-level source. The supported conclusion is that this packet improved the measured Go profile reconstruction in this cohort. A later source-language comparison remains a separate experiment.
