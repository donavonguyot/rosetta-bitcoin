# RosettaBitcoin Archive Harvest

This document records the Stage 1 harvest boundary for the retired
`/Users/donavonguyot/RosettaBitcoin` workspace. A compressed backup exists, so
this workspace can now be treated as source archaeology instead of active
project state.

`/Users/donavonguyot/RB` remains the deliverable workspace. Old RosettaBitcoin
material may inform language, contracts, fixtures, and compact evidence only
after it is re-expressed in RB-owned form and reviewed under the current
Project, Shared, and artifact-retention rules.

## Surface Classification

| Old surface | Stage 1 classification |
|-------------|------------------------|
| Root roadmap wrapper | Retired coordination memory. Useful for authority-boundary language and decision history, not current mission control. |
| `rosetta-bitcoin` proof repo | Historical proof-machine and custody archive. Reuse concepts only after rewriting them as RB-native docs, fixtures, contracts, or compact evidence. |
| Archive and IL corpus | Hypothesis and provenance material. IL is not behavior authority and does not define Bitcoin semantics. |
| Java product snapshot | Historical product-pressure evidence. Current RB port status must come from RB Project reports and port-owned proof artifacts. |
| Portal, book, and audio workspaces | Narrative and stewardship archive. Keep external unless a small summary is deliberately written into RB docs. |
| Nested Git histories | External archaeology. Do not recreate nested repositories inside RB. |
| Generated/runtime state | Excluded from RB. Dependency trees, build output, logs, live DBs, blocks, chainstate, and proof scratch stay out. |

## Stage 1 Decisions

- Promote language and lessons only. Do not copy old source trees, DBs, proof
  runners, generated artifacts, portal assets, book assets, audio assets, or
  nested `.git` directories into RB.
- Keep the old archive external. RB may point to the existence of the retired
  workspace, but the future public repository should not absorb it wholesale.
- Treat IL as hypothesis and provenance only. Any current behavior claim must
  come from RB-owned consensus ledgers, fixtures, port evidence, or compact
  proof JSON.
- Treat old proof ladders as history. They are not current benchmark,
  consensus, Docker, storage, or full-node evidence.
- Preserve RB's evidence boundary: Project imports current curated evidence by
  default, and historical archaeology remains explicit.

## Next Stage Queue

1. Archive manifest/checksum snapshot: completed in
   `Docs/rosettabitcoin-archive-snapshot.md` and
   `Docs/rosettabitcoin-archive-checksums.sha256`.
2. Run an IL value audit that maps old IL-derived ideas to current RB fixtures,
   docs, blocker facts, or rejected assumptions.
3. Design a Core/btcg comparison lane as a separate witness/reference surface,
   not as an RB port and not as a validity oracle.
4. Prepare the rename/open-source pass: repository name, README posture,
   responsible-disclosure language, ignored artifacts, and public archive
   boundary.
