# Port Architecture Outline

Use this outline when authoring or expanding `Nodes/<Port>/docs/ARCHITECTURE.md`.
Keep live status, benchmark rank, and binary-gate posture in Project reports,
not in the architecture doc.

## Recommended Sections

1. **Opening** — map the implementation; link README for commands; defer posture to Project.
2. **Shared contract links** — `CODE_DOCUMENTATION.md`, validation, chainstate, status, Docker, consensus runway as relevant.
3. **Package layers** — mermaid diagram plus table of packages/modules and responsibilities.
4. **Entrypoints** — sync, live node, status, proof/CLI surfaces and what each owns.
5. **P2P handshake** — simple path, deferred advanced negotiation, honest `start_height`.
6. **Header sync** — locator/build, validation, separation of header height vs validated height.
7. **Block acquisition** — ordered download, prefetch vs connect ordering.
8. **Block connect** — validation boundary, block-local UTXO view, atomic chainstate commit, validation blocker behavior.
9. **UTXO, undo, rebuild** — durable store roles and replay/rebuild posture if applicable.
10. **Script verification and sighash** — dispatcher, fixture alignment, common traps.
11. **Chainstate and runtime truth** — session/open path, store split, Project projection boundary.
12. **Single-writer datadir lock** — lock file, overlap risks, which entrypoints acquire it.
13. **Status, export, and proof surfaces** — what operators read; what proof CLIs emit; no pass/fail claims.
14. **Docker and local Reference** — manifest pointer, fresh proof vs supervisor modes.
15. **Language-specific design choices** — idioms that express the shared pipeline in this port.
16. **Mission-control queries** — Project commands for the port; no status tables in prose.

## Examples

- [Python ARCHITECTURE.md](../../Python/docs/ARCHITECTURE.md) — operational depth and data flows.
- [Java ARCHITECTURE.md](../../Java/docs/ARCHITECTURE.md) — reference native/Core map with canonical vocabulary.
- [TypeScript ARCHITECTURE.md](../../TypeScript/docs/ARCHITECTURE.md) — native/Core TypeScript expression of the same pipeline.
- [Go ARCHITECTURE.md](../../Go/docs/ARCHITECTURE.md) — comparator-first fetch/connect architecture.
- [Rust ARCHITECTURE.md](../../Rust/docs/ARCHITECTURE.md) — pipeline proof and Rayon script pool.
- [Cpp ARCHITECTURE.md](../../Cpp/docs/ARCHITECTURE.md) — full live node, sync, and mempool surfaces.
