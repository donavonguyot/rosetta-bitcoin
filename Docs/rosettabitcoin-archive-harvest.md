# RosettaBitcoin Archive Harvest

This document records the Stage 1 harvest boundary for the retired
the retired archive workspace workspace. A compressed backup exists, so
this workspace can now be treated as source archaeology instead of active
project state.

The current RosettaBitcoin workspace remains the deliverable workspace. Old
RosettaBitcoin material may inform language, contracts, fixtures, and compact
evidence only after it is re-expressed in RosettaBitcoin-owned form and reviewed under the
current Project, Shared, and artifact-retention rules.

## Surface Classification

| Old surface | Stage 1 classification |
|-------------|------------------------|
| Root roadmap wrapper | Retired coordination memory. Useful for authority-boundary language and decision history, not current mission control. |
| `rosetta-bitcoin` proof repo | Historical proof-machine and custody archive. Reuse concepts only after rewriting them as RosettaBitcoin-native docs, fixtures, contracts, or compact evidence. |
| Archive and IL corpus | Hypothesis and provenance material. IL is not behavior authority and does not define Bitcoin semantics. |
| Java product snapshot | Historical product-pressure evidence. Current RosettaBitcoin port status must come from RosettaBitcoin Project reports and port-owned proof artifacts. |
| Portal, book, and audio workspaces | Narrative and stewardship archive. Keep external unless a small summary is deliberately written into RosettaBitcoin docs. |
| Nested Git histories | External archaeology. Do not recreate nested repositories inside RosettaBitcoin. |
| Generated/runtime state | Excluded from RosettaBitcoin. Dependency trees, build output, logs, live DBs, blocks, chainstate, and proof scratch stay out. |

## Stage 1 Decisions

- Promote language and lessons only. Do not copy old source trees, DBs, proof
  runners, generated artifacts, portal assets, book assets, audio assets, or
  nested `.git` directories into RosettaBitcoin.
- Keep the old archive external. RosettaBitcoin may point to the existence of the retired
  workspace, but the future public repository should not absorb it wholesale.
- Treat IL as hypothesis and provenance only. Any current behavior claim must
  come from RosettaBitcoin-owned consensus ledgers, fixtures, port evidence, or compact
  proof JSON.
- Treat old proof ladders as history. They are not current benchmark,
  consensus, Docker, storage, or full-node evidence.
- Preserve RosettaBitcoin's evidence boundary: Project imports current curated evidence by
  default, and historical archaeology remains explicit.

## Next Stage Queue

1. Archive manifest/checksum snapshot: completed in
   `Docs/rosettabitcoin-archive-snapshot.md` and
   `Docs/rosettabitcoin-archive-checksums.sha256`.
2. IL value audit: completed in
   `Docs/rosettabitcoin-il-value-audit.md`. Old IL is historical extraction
   material; useful ideas must still be rewritten into RosettaBitcoin-native docs,
   fixtures, contracts, or compact proof artifacts before use.
3. Core/btcg comparison lane: completed in
   `Docs/core-btcg-comparison-lane.md`. Reference and witness surfaces may
   calibrate claims, but they are not RosettaBitcoin ports and not validity oracles.
4. Rename/open-source prep: documented in
   `Docs/rename-open-source-prep.md`. The workspace rename is complete;
   publication and security/disclosure setup remain future operational steps.
