# RosettaBitcoin claim--evidence matrix

Study boundary: Zenodo DOI `10.5281/zenodo.20738249`, published 2026-06-17,
commit `4ade801b7ca0eb06f479e096bf285f621fd5e330`.

Diagnostic supplement: Zenodo DOI `10.5281/zenodo.22114337`, version 1.

This matrix governs numerical and status claims in the manuscript. “Reproducible”
means a reader can re-run a read-only query or verify an archived file; it does
not mean an ignored runtime experiment can be regenerated from the supplement.

| ID | Manuscript claim | Class | Evidence or query | Timestamp | Limitation | Reproducibility |
|---|---|---|---|---|---|---|
| B01 | Archive publication date, filename, MD5, and DOI | observation | Zenodo record API; supplement manifest `original_snapshot` | 2026-06-17 | Zenodo metadata, not a software result | Download and compare MD5 |
| B02 | Snapshot resolves to commit `4ade801b…` | historical provenance | archive directory suffix; local Git object | 2026-06-17 | suffix resolution uses the preserved repository | `git show 4ade801` |
| B03 | Frozen Project DB and current-evidence SHA-256 values | observation | archived and commit copies of both files | 2026-06-17 | file identity does not validate semantics | `shasum -a 256` |
| B04 | Archive contains 91 tracked conformance-result files | observation | archive file inventory under `Nodes/Shared/conformance/results` | 2026-06-17 | file count, not current-evidence count | enumerate archive paths |
| S01 | 45 fixtures and 45 rule records | Project-canonical/observation | script manifest; testnet4 rule ledger | 2026-06-17 | no completeness claim | parse JSON counts |
| S02 | 111 normalized blockers | Project-canonical | `report.py --section blocker-matrix` / Project SQL | 2026-06-17 | rows may share historical origins | read-only query |
| S03 | 63 selected current-evidence entries and type breakdown | Project-canonical | `Nodes/Shared/conformance/current_evidence.json` | 2026-06-17 | selection policy is project-owned | parse JSON |
| R01 | Twelve ports have port-owned 45/45 proofs | Project-canonical | `preflight_consensus_runway.py --all --stage corpus --strict` | 2026-06-17 | fixture-bounded | re-run strict preflight |
| R02 | Twelve ports pass strict baseline 5k | Project-canonical | `preflight_port_baseline.py --all --strict` | 2026-06-17 | first comparable gate, not node completion | re-run strict preflight |
| R03 | Nine ports have clean 50k, 100k, and post-100k lanes | Project-canonical | `report.py --section benchmark-suite`; current evidence | 2026-06-17 | post-100k resumes state; not empty-state-to-tip | read-only report |
| R04 | Port lifecycle, height, and maximum lane rows in Table 1 | Project-canonical | `report.py --section port-status` and `--section benchmark-suite` | 2026-06-17 | heights are snapshot posture | read-only reports |
| R05 | Java maintenance covers 19.86 s, heights 138575--138591 | Project-canonical | selected `tip_maintenance` artifact/current evidence | 2026-06-17 | too short for durable maintenance | inspect selected artifact |
| R06 | Zero `tip_once` proofs; no binary-gate pass | Project-canonical | benchmark-suite report and status contracts | 2026-06-17 | absence is snapshot-bounded | read-only report |
| R07 | Docker/supervisor states are partial and full-node gaps remain | Project-canonical | Docker inventory, capability report, port-status | 2026-06-17 | category-level summary | read-only reports |
| H01 | Formalization span: 20 Apr--4 May, 14 calendar days, 30,549 lines | historical provenance | tagged commits and historical manifest | 2026-04-20--2026-05-04 | non-equivalent to product work; not effort | inspect endpoints and manifest |
| H02 | Process span: 3--23 May, 20 calendar days | historical provenance | repository commit/history records | 2026-05-03--2026-05-23 | not effort | inspect endpoints |
| H03 | Java product span: 23 May--8 Jun, 16 calendar days | historical provenance | product-pivot and Java evidence commits | 2026-05-23--2026-06-08 | not a controlled task duration | inspect endpoints |
| H04 | Zig scaffold-to-50k span: 3:17:57 | historical provenance | commits `2a64b70a` and `c88dd6ce` | 2026-06-05 | commit span includes unknown work/inactivity | inspect commit timestamps |
| D01 | Pure backend recorded to 5k | diagnostic supplement | DOI `10.5281/zenodo.22114337`, artifact `pure_backend_5k` | 2026-06-17 | diagnostic, noncomparable | verify archived JSON/hash |
| D02 | Pure backend fresh-state to 100000 | diagnostic supplement | DOI `10.5281/zenodo.22114337`, artifact `pure_backend_fresh_100k` | 2026-06-17 | not full-node gate | verify archived JSON/hash |
| D03 | Pure backend resumed 100000 to 140234 | diagnostic supplement | DOI `10.5281/zenodo.22114337`, artifact `pure_backend_100k_to_140234` | 2026-06-17 | not empty-state-to-tip | verify archived JSON/hash |
| D04 | Backend declares no native crypto or fallback | diagnostic supplement | D01--D03 JSON backend fields | 2026-06-17 | self-reported artifact fields | verify archived JSON/hash |
| D05 | 45-case shadow comparison | diagnostic supplement | artifact `pure_native_shadow_45` | 2026-06-17 | fixture-class bounded | verify archived JSON/hash |
| D06 | Native and pure checks reject six invalid families | diagnostic supplement | artifacts `native_reject_6`, `pure_reject_6` | 2026-06-17 | six selected families only | verify archived JSON/hash |
| D07 | Three fault modes turn reject check red (2/1/1 accepts) | diagnostic supplement | artifacts `fault_accept_ecdsa`, `fault_accept_schnorr`, `fault_accept_taptweak` | 2026-06-17 | does not measure general mutation adequacy | verify archived JSON/hash |
| D08 | Height-56447 blocker exact provenance | diagnostic supplement | `blocker_56447_provenance.json`; preserved Reference block data | recovered 2026-08-26 | post-snapshot; does not move gates | retrieve block/transaction from testnet4 Core |
| A01 | One developer; Codex/GPT-5 recorded for Mojo; Claude writing help | observation | repository records and author disclosure | through 2026-06-17 / writing 2026-08 | prompts, counts, costs, and intervention time unavailable | inspect records/disclosure |
| I01 | Ports are separately implemented but not experimental replications | observation/interpretation | repository topology and shared infrastructure | 2026-06-17 | narrow definition only | inspect code and contracts |
| P01 | A substrate may reduce time to admitted evidence | hypothesis | motivated by H01--H04 | future | no causal evidence in this case | requires controlled ablation |

## Numerical audit rule

Every manuscript height, count, duration, date, model identifier, and
independence statement must map to a row above. New numbers require a new row
before publication.
