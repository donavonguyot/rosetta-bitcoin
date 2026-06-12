# RosettaBitcoin IL Value Audit

> **Archive Record.** This document describes a completed process and is preserved
> for provenance and decision history only. It is not active guidance. Query
> Project for current status.

Audit date: `2026-06-06`

Archive root: the retired archive workspace

Verification dependency: `Docs/rosettabitcoin-archive-snapshot.md` and
`Docs/rosettabitcoin-archive-checksums.sha256`.

This audit records what the retired IL corpus can contribute to current RosettaBitcoin.
It is not current evidence. IL does not define Bitcoin semantics, benchmark
status, Docker readiness, storage compliance, or full-node validity. Any useful
idea must be rewritten into RosettaBitcoin-owned docs, Shared contracts, fixtures, or compact
proof JSON before it can affect current claims.

## General Lesson

IL was a valuable dead end. It produced useful vocabulary, extraction discipline,
package maps, and proof-boundary language, but it did not become the engine that
could carry the project to operational node evidence. RosettaBitcoin's current consensus
framework is the current approach: fixture-backed rule cards, port-owned proof
artifacts, Project imports, and independent validation gates.

The right harvest is therefore not to continue the old IL machinery. It is to
preserve the lessons that made the new framework possible while treating the IL
corpus as historical provenance.

## Classification Key

| Classification | Meaning |
|----------------|---------|
| `promote-now` | Rewrite a small lesson into current RosettaBitcoin docs, contracts, fixtures, or compact evidence soon. |
| `preserve-only` | Keep as archaeology in the retired archive; no current RosettaBitcoin action. |
| `reject-as-authority` | May be interesting language, but cannot support current RosettaBitcoin behavior or claims. |
| `defer` | Potentially useful after a Core/btcg comparison lane or active port need exists. |

## Surface Audit

| Archive surface | Classification | RosettaBitcoin-native disposition |
|-----------------|----------------|-----------------------|
| `rosetta-bitcoin/archive/001-chainhash-poc` | `preserve-only` | Useful origin story for tiny cross-language proof experiments. Current RosettaBitcoin already owns hash, fixture, and port evidence through Shared contracts and port tests, so no import is needed. |
| `rosetta-bitcoin/archive/002-btcd-il-harvest` | `defer` | The btcd-derived package map, assertion counts, tiering, and dependency edges are useful as a historical extraction map. Do not promote assertions as semantics. Revisit only when a current port, Shared fixture, or Core/btcg comparison needs a specific package-level clue. |
| `rosetta-bitcoin/archive/002-btcd-il-harvest/language-ports` | `reject-as-authority` | Language-port experiments are not RosettaBitcoin ports, not current runtime evidence, and not portability proof. Keep external. |
| `rosetta-bitcoin/archive/002-btcd-il-harvest/source-overlay` | `defer` | The overlay's seed/provenance boundary matches RosettaBitcoin's current archive rules. Reuse only as wording for provenance-vs-promotion policy if a later doc needs it. |
| `rosetta-bitcoin/archive/003-port-grid-experiment` | `promote-now` | Harvest the durable port-grid lesson: port comparisons need explicit gates, provenance, Docker/runtime posture, and no validation oracle. Fold only the concept into RosettaBitcoin comparison-lane docs. |
| `rosetta-bitcoin/archive/004-methodology-notes` | `promote-now` | Preserve the useful methodology language around deep verification, semantic compression, and proof boundaries. Rewrite as RosettaBitcoin evidence discipline, not as IL doctrine. |
| `rosetta-bitcoin/docs/full-node-participation-proof.md` and related proof-ladder docs | `defer` | Useful predecessor to RosettaBitcoin's binary full-node gate. Revisit during rename/open-source prep or live tip proof planning, but do not treat the old ladder as current benchmark evidence. |
| `rosetta-bitcoin/docs/archive/runtime-proof.md` and `witness-harness.md` | `defer` | May help phrase future witness/reference lanes. Must be reconciled with current Project, Docker, and Shared conformance contracts before use. |
| `rosetta-bitcoin/src/rosetta_bitcoin/schemas/*provenance*.json` and old hypothesis schemas | `reject-as-authority` | Do not import old schema machinery. Current claims must use RosettaBitcoin's Project index, Shared contracts, and compact result JSON. |

## Promotion Queue

1. Add a Core/btcg comparison lane doc that borrows the old port-grid lesson:
   witnesses and references are separate from RosettaBitcoin ports, and Reference Core is a
   byte source or comparison surface, not a validity oracle.
2. Add a short provenance rule to the rename/open-source prep: historical IL may
   be cited as archive context, but every public claim must point at current RosettaBitcoin
   evidence or explicitly say it is archaeology.
3. If a future consensus blocker needs btcd context, promote only the specific
   fact into a Shared fixture, rule card, or compact proof artifact. Do not
   promote an IL assertion directly.

## Decisions

- Promote concepts that strengthen RosettaBitcoin's evidence boundary: authority language,
  fixture/contract promotion rules, provenance-vs-proof distinctions, and
  port-grid lessons aligned with current Project benchmark gates.
- Do not promote old IL assertions as Bitcoin semantics.
- Do not copy generated old ports, language-port experiments, proof runners,
  SQLite state, reports, or old schemas into active RosettaBitcoin systems.
- Treat btcd-derived IL as a historical extraction map, not as a validation
  oracle.
- A useful IL-derived idea affects Project claims only after it becomes an
  RosettaBitcoin-native doc, Shared fixture/contract, port durable artifact, or compact
  proof JSON.
