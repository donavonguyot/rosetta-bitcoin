# Port Status Baseline

This is the shared workspace status baseline for cleanup and handoff work. Live
DB/status commands are fresher than this file; committed snapshots and proof
artifacts are durable checkpoint evidence.

## Current Baseline

| Port | Role | Durable status | Current blocker / next rule | Notes |
|------|------|----------------|-----------------------------|-------|
| PythonNode | Scout | Snapshot evidence around `validated_height=52996` | Later rows above 52k are partly unknown in shared matrix | Scout facts seed follower work, not validity for other ports. |
| JavaNode | Lead follower | Ledger records `validated_height=136863`, `binary_gate_status=passed`; Docker native proofs pass 10k and 50k | None at 136863; tip maintenance remains separate | Docs/proof naming need cleanup around RocksDB/native storage. |
| CSharpNode | Follower | Persistent Docker supervisor reached `validated_height=22829` | Blocked at `22830` P2TR script-path / BIP342 | Cleared 6975 and 10k; first-class blocker diagnostics still needed. |
| TypeScriptNode | Fast follower | Snapshot evidence around `validated_height=5578` | Matrix remains conservative above known fixtures | Has known 5579 dual-writer repair lesson in `AGENTS.md`. |
| CppNode | Systems follower | Static docs indicate blocked at 739; snapshots placeholder only | P2WPKH/BIP143 path | Clear consensus path before storage gate claims. |
| ElixirNode | Supervised follower | `make node-status` exists; no shared snapshots yet | Matrix marks P2TR key-path as implemented but unverified live | Needs export/status contract alignment. |

## Status Rules

- Use each port's own status command for live truth.
- Treat committed snapshots as checkpoint artifacts, not live truth.
- Record blockers with exact height, block hash, txid, input index, spent
  scriptPubKey, failure, and missing rule.
- Do not use another port's chainstate as proof of local validity.

## Immediate Cleanup Facts

- Root repo currently owns `docs/`, `NodeCore/`, `Project/`, and
  `ReferenceNode/`; port repos remain independent.
- `NodeCore/` and `Project/` must be promoted as root-owned infrastructure with
  intentional ignores and selected artifacts.
- C# blocker inspection at 22830 used a temporary Python scanner; recurring
  blocker inspection needs native C# or NodeCore tooling.
