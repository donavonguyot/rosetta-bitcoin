# Port Status Baseline

This is the shared workspace status baseline for cleanup and handoff work. Live
DB/status commands are fresher than this file; committed snapshots and proof
artifacts are durable checkpoint evidence.

## Current Baseline

Consensus status, Core storage compliance, and Docker compliance are separate.
Do not promote a port to Core Node compliant because it clears a consensus
fixture, emits a partial storage proof, or has a Dockerfile.

| Port | Role | Consensus / runtime status | Core storage status | Docker status | Current blocker / next rule |
|------|------|----------------------------|---------------------|---------------|-----------------------------|
| Python | Full-break native target | Legacy SQLite-scout evidence around `validated_height=52996` is historical only; forward parity must rerun blockers from empty native state in a later replay plan | RocksDB/native-crypto path implemented for bounded native proof; full replay not claimed | supervisor_partial | Validate bounded proof/supervisor, then hand off to empty-native replay plan |
| Java | Lead follower | Ledger records `validated_height=136863`, `binary_gate_status=passed`; bounded Docker native proof still passes to height 2 | RocksDB/native evidence exists; continue auditing no legacy DB dependency in native mode | supervisor_partial | Tip maintenance and proof naming cleanup |
| CSharp | Follower | Persistent Docker supervisor reached `validated_height=22829`; latest bounded Docker proof passes to height 2; cleared 6975 and 10k | RocksDB/native evidence exists | supervisor_partial | Blocked at `22830` P2TR script-path / BIP342; native blocker diagnostics still needed |
| TypeScript | Native/Core migration target | Snapshot evidence around `validated_height=5578`; matrix remains conservative above known fixtures and must be replayed from empty native state | proof_partial: RocksDB storage proof path and native dependency boundary exist; SQLite runtime remains legacy/non-Core | supervisor_partial | Complete SQLite runtime exit, standardize external probe, and rediscover blockers under native state |
| Go | Core-native scaffold follower | Docker local-reference RPC proof stores and independently connects blocks through `validated_height=10000`; native Go script corpus passes `45/45`; no live P2P sync or tip-maintenance claim | proof_partial: RocksDB-backed storage proof, Docker local-reference replay through 10000, and native secp256k1/libsecp256k1 script verification evidence exist | proof_partial | Optimize replay/supervisor path and add live P2P sync; binary gate remains not_attempted |
| Rust | Core-native scaffold follower | Docker local-reference RPC proof stores and independently connects blocks through `validated_height=10000`; native Rust script corpus passes `45/45`; no live P2P sync, tip maintenance, or binary-gate claim | proof_partial: RocksDB-backed storage proof, Codec v2 vectors, native crypto vectors, optimized batch connect substrate, Docker local-reference replay through 10000, and native Rust script verification evidence exist | proof_partial | Add live P2P sync/supervisor path and continue replay beyond Go parity; binary gate remains not_attempted |
| Cpp | Systems follower | Height 739 fixture regression passes; bounded Docker RocksDB storage proof passes; live datadir still needs rerun beyond 738 | proof_partial: RocksDB-only operational store and proof artifact exist; live staged sync rerun still pending | proof_partial | Keep native builds SQLite-free, then resume staged sync |
| Elixir | Supervised follower | `make status` reports RocksDB backend fields; no shared snapshots yet | proof_partial: RocksDB chainstate boundary and bounded storage proof exist; native secp256k1 NIF still unavailable | proof_partial | Replace storage abstraction with real RocksDB NIF binding, add native secp256k1 NIF, then rerun live sync/blocker discovery |

## Status Rules

- User-facing native inspection commands should use `status`; bounded native
  storage proofs should use `storage-proof`; old SQLite evidence should be
  explicitly labeled `legacy-sqlite`.
- Use each port's own status command for live truth.
- Treat committed snapshots as checkpoint artifacts, not live truth.
- Keep consensus progress, Core storage compliance, and Docker runtime
  compliance as separate fields.
- Record blockers with exact height, block hash, txid, input index, spent
  scriptPubKey, failure, and missing rule.
- Do not use another port's chainstate as proof of local validity.
- Do not claim Core Node compliance if native/Core mode depends on SQLite for
  any operational node truth.
- Do not claim Docker compliance unless the port has an inventory row and passes
  the Docker runtime contract in `NodeCore/docker/DOCKER_RUNTIME_CONTRACT.md`.
- Docker status should be checked against the port manifest in
  `NodeCore/docker/ports/<port>.docker.json` and the report-only validator:

```bash
python3 NodeCore/docker/validate_docker_contract.py
```

## Artifact Retention

Project-level evidence should be compact JSON under
`NodeCore/conformance/results/`. Port-local datadirs, logs, build trees, and
scratch proof directories are runtime artifacts and should stay ignored or be
deleted after their evidence is centralized. See
[`artifact-retention.md`](artifact-retention.md) and
[`../NodeCore/conformance/ARTIFACT_INVENTORY.md`](../NodeCore/conformance/ARTIFACT_INVENTORY.md).

## Immediate Cleanup Facts

- Root repo currently owns `docs/`, `NodeCore/`, `Project/`, and
  `Nodes/Reference/`; implementation repos remain under `Nodes/`.
- `NodeCore/` and `Project/` must be promoted as root-owned infrastructure with
  intentional ignores and selected artifacts.
- Docker-capable ports use `Nodes/<Port>/docker/` for Dockerfiles, compose
  files, and Docker ignore declarations; validate with the Docker contract
  report before claiming Docker surface changes.
- 2026-06-02 cleanup proof pass: default and strict Docker contract validation
  reported `errors=0 warnings=0`; compose config passed for every Docker-capable
  port; Cpp, C#, Elixir, Java, Python, and TypeScript images built; bounded
  Cpp/C#/Elixir/Java/Python/TypeScript proofs passed against local Reference or
  storage gates.
- C# blocker inspection at 22830 used a temporary Python scanner; recurring
  blocker inspection needs native C# or NodeCore tooling.
