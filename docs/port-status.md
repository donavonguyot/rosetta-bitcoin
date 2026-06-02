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
| TypeScript | Fast follower | Snapshot evidence around `validated_height=5578`; matrix remains conservative above known fixtures | SQLite by design; no native/Core storage claim | daemon_only | Known 5579 dual-writer repair lesson remains in `AGENTS.md` |
| Cpp | Systems follower | Height 739 fixture regression passes; bounded Docker RocksDB storage proof passes; live datadir still needs rerun beyond 738 | proof_partial: RocksDB-only operational store and proof artifact exist; live staged sync rerun still pending | proof_partial | Keep native builds SQLite-free, then resume staged sync |
| Elixir | Supervised follower | `make node-status` exists; no shared snapshots yet | no native/Core storage evidence | missing | Needs Docker surface and export/status contract alignment |

## Status Rules

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
  port; Cpp, C#, Java, Python, and TypeScript images built; bounded Cpp/C#/Java
  Docker proofs passed against local Reference.
- C# blocker inspection at 22830 used a temporary Python scanner; recurring
  blocker inspection needs native C# or NodeCore tooling.
