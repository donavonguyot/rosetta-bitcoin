# AGENTS.md — Nodes workspace guide for AI agents

Quick context for agents working under `~/Nodes`. Read this before touching P2P
handshake, sync, consensus validation, datadirs, or port-following work.

---

## True North

The binary end gate for every serious node in this workspace is:

> From empty local state on Bitcoin testnet4, the node reaches and maintains tip
> while independently validating every stored connected block.

Partial sync, headers-only sync, trusted import, matching another node without
independent validation, or skipping unknown consensus rules does **not** pass.

Progress can be measured with many gauges, but the gauges are not the goal:

| Gauge | Meaning |
|-------|---------|
| `validated_height` | Current independently connected block height |
| `sync_status` | Current runtime phase |
| blocker height / tx / input | Exact next missing rule |
| script template survey | Read-only map of likely upcoming spend templates |
| wire capabilities / checkpoints | P2P surface coverage |
| snapshots | Exported checkpoint, not always live truth |

Agents should report whether a change moves the binary gate, what exact blocker
it addresses, and what remains blocked.

---

## Project layout and roles

| Path | Package | Role |
|------|---------|------|
| `~/Nodes/PythonNode` | **pybitnode** | Scout/reference implementation; discovers live-chain blockers first |
| `~/Nodes/TypeScriptNode` | **tsbitnode** | Fast follower; zero **runtime** npm deps; uses Node built-ins |
| `~/Nodes/CppNode` | **cpbitnode** | Systems follower; keep behind the proven scout/follower path |
| `~/Nodes/JavaNode` | future | Clean Java follower/product node if restarted here |

All active nodes target **Bitcoin testnet4**. They can run in parallel only with
isolated state and deliberate peer allocation.

### Scout / follower rule

Python is the scout. That means Python may hit live-chain blockers first and
produce exact handoff facts. Followers should use those facts to implement the
same rule in their own language without silently weakening validation.

Follower ports must not treat Python as an oracle for validity. They use Python's
blocker ledger, tests, and fixture details as a work queue, then independently
validate with their own code.

### Blocker ledger contract

Every consensus unblock should leave enough information for follower ports to
reproduce it without archaeology:

```text
height:
block_hash:
txid:
input_index:
spent_script_pubkey:
failure:
missing_rule:
python_fix:
test_fixture:
follower_notes:
```

For P2P/sync blockers, record the peer, command, datadir, advertised
`start_height`, header height, validated height, and whether deferred handshake
messages were sent.

---

## Critical: handshake / sync state (“too advanced” disconnects)

**Symptom:** Peers disconnect shortly after `verack`. Remote nodes treat us as “too advanced” when our `version.start_height` claims the header tip while `validated_height` is still `0`.

### Rules (both nodes — match Python `sync_runner` flow)

1. **Simple handshake first:** `version` → `verack` → `sendheaders` only.
2. **Do NOT** send `feefilter`, `mempool`, or `sendcmpct` immediately after `verack` during initial sync.
3. **Defer** `feefilter` / `mempool` until `sync_status === "headers_current"`.
4. **`completeDeferredHandshake()`** only when:
   - headers are current, **and**
   - node is in live **LISTEN** mode — **not** before block download in batch/sync-runner paths.
5. **Never advertise inflated `start_height`.** Report what we have actually validated (or a conservative height), not the header tip with zero validated blocks.

Python hit the same pitfall; TypeScript must mirror the deferred-handshake pattern in `sync_runner.py` / `header_refresh.py`.
Java/C++/C# followers should copy the same sync posture unless a later scout
finding replaces it.

---

## Peer strategy

| Topic | Python (pybitnode) | TypeScript (tsbitnode) |
|-------|--------------------|-------------------------|
| Default ops peer | Often `89.167.10.150:48333` | **Excluded by default** (parallel runs) |
| Fallback | — | DNS seed; falls back to `89.167.10.150` when seeds fail |
| Datadir | `./data` | `./data-ts` |
| SQLite DB | `pybitnode.db` | `tsbitnode.db` |

**Never share datadirs or DB files between nodes or parallel agent runs.** One writer per datadir at a time.

Prefer distinct peers per active node. Do not use Python's active ops peer for a
follower sync while Python is actively syncing unless you are intentionally
testing a known peer path and record that decision in the log/summary.

Before starting or modifying sync work, check live processes:

```bash
ps aux | rg 'pybitnode|tsbitnode|cpbitnode|syncBatchLoop|sync_batch_loop'
```

If a node is actively syncing, do not edit its consensus or P2P code underneath
that run. Prepare the fix, stop/restart cleanly, and preserve the blocker facts.

---

## How progress is reported

There is one binary end gate: testnet4 participation with independent validation
to tip. Intermediate progress is hierarchical:

| Layer | Count | Notes |
|-------|-------|-------|
| Wire capabilities | 43 required | Registry in `wire/capabilities` |
| Checkpoints | 9 (cp0–cp8) | Incremental milestones |
| Phases | 6 | Broader rollout stages |
| Runtime | `sync_status`, `validated_height` | Live sync truth |

`full_node_wire_ready` is **blocked by cp6 (serving)** until exercised on a live peer connection.

Do not present intermediate counters as completion. A useful status report says:

```text
validated_height:
header_height:
current_blocker:
current_peer:
last_committed_snapshot_height:
uncommitted_consensus_changes:
next_exact_rule:
binary_gate_status: failed | not_attempted | passed
```

---

## TypeScript constraints

- **NO** external Bitcoin libraries (no `bitcoinjs-lib`, etc.).
- **NO runtime npm dependencies** — only Node built-ins: `node:sqlite`, `node:crypto`, `node:net`, `node:http`.
- Dev deps only: TypeScript, Vitest, tsx.
- **Docker:** generic `docker-compose`; works on OrbStack.

---

## Common agent mistakes

| Mistake | Why it fails |
|---------|----------------|
| Running sync batch in a **sandbox without network** | False “broken sync” diagnosis; peers never connect |
| Calling `completeDeferredHandshake()` **before block sync** | Peers disconnect; “too advanced” |
| Advertising **inflated `start_height`** | Remote peer drops connection |
| **Two writers** on same datadir | SQLite corruption / lock errors |
| **Parallel agents** editing `peer.ts` | Merge conflicts and conflicting handshake logic |
| Editing consensus/P2P while a sync process is live | Run may mix old state with new code; blocker diagnosis becomes muddy |
| Treating snapshots as live truth | Snapshots can lag DB/logs; check live DB/status before conclusions |
| Skipping an unsupported script template | Produces false validation; stop and record the missing rule instead |
| Porting implementation details without the blocker facts | Followers drift or overfit; use the blocker ledger |

---

## How to run TypeScript sync

```bash
cd TypeScriptNode && npm run build
DATA_DIR=./data-ts node dist/cli/syncRunner.js
```

With Python’s default peer (explicit override):

```bash
cd TypeScriptNode
PEERS=89.167.10.150:48333 MAX_OUTBOUND_PEERS=1 SKIP_GETADDR=1 node dist/cli/syncRunner.js
```

Block-only pass after headers are current:

```bash
node dist/cli/syncRunner.js --no-header-refresh --blocks-max 64
```

---

## How to verify progress

```bash
cd TypeScriptNode
npm run build

# DB snapshot / heights
npx tsbitnode-db --db ./data-ts/tsbitnode.db

# Sync report
npm run sync:progress

# Export capability/wire snapshots
npm run export:snapshots -- --db ./data-ts/tsbitnode.db

# Script template survey (read-only; optional block scan ahead of tip)
npm run survey:scripts -- --db ./data-ts/tsbitnode.db --scan-blocks 20
```

Key fields: **`header_height`**, **`validated_height`**, **`sync_status`**.

For Python, prefer live DB/status when the node is running and snapshots after a
settled checkpoint:

```bash
cd PythonNode
.venv/bin/pybitnode-db --db ./data/pybitnode.db
.venv/bin/python scripts/export_snapshots.py --db ./data/pybitnode.db
```

Snapshots are committed checkpoint artifacts. They are not guaranteed to reflect
the latest live DB while sync is running.

---

## Recommended port order (TypeScript)

Work in this order to avoid handshake regressions:

```
cp0/cp1 handshake → cp3 headers → cp4 blocks → phase3 consensus
  → cp5 mempool → cp6 serving → cp8 extensions
```

Handshake timing is critical for cp5/cp6/cp8 even when code exists.

---

## Consensus script milestones (testnet4)

Script verification applies on **spend paths** (non-coinbase transactions consuming UTXOs). Coinbase outputs require **100-block maturity** (`COINBASE_MATURITY`); first spends of early coinbases appear around height **101+**. Until then, blocks connect without exercising the interpreter on real spends.

| Milestone | Height / target | Notes |
|-----------|-----------------|-------|
| First P2TR stall (documented) | **6975** | Taproot key-path spend; see [`PythonNode/docs/OPERATIONS.md`](PythonNode/docs/OPERATIONS.md) § block 6975 |
| Python batch reference | **10000** | Common `--blocks-target` for staged catch-up |
| Mainnet Taproot activation | **709632** | **Do not use** as a testnet4 sync target or milestone |

### TypeScript gaps (consensus / tests)

| Gap | Status |
|-----|--------|
| **CLTV / CSV** (BIP65 / BIP112) | Python implements full semantics; TS interpreter still **ignores** `OP_CHECKLOCKTIMEVERIFY` / `OP_CHECKSEQUENCEVERIFY` unless verify flags are set (then throws). Port from `pybitnode/consensus/script/interpreter.py` when sync stalls on timelocked redeems. |
| **Multisig test coverage** | `CHECKMULTISIG` exists in the interpreter; no dedicated multisig fixtures in `tests/script.test.ts` (Python has richer coverage in `tests/test_script.py`). |
| **Script template survey** | `npm run survey:scripts` — read-only port of Python `script_template_survey.py` |

### Consensus validation rule

If a spent output requires a script rule that is not implemented, stop with a
bounded validation blocker. Do not connect the block by assuming success. The
scout loop is:

```text
sync until exact blocker -> record blocker -> implement exact missing rule
  -> add fixture/regression test -> resume sync
```

### Parallel prep checklist (consensus / sync agents)

1. **Isolated datadirs** — Python `./data` + `pybitnode.db` vs TypeScript `./data-ts` + `tsbitnode.db`; never share or copy mid-write.
2. **One SQLite writer** per datadir; survey/export tools open **read-only**.
3. **Peer exclusion** — TS excludes Python’s default ops peer (`89.167.10.150`) unless `PEERS=` overrides; avoids cross-node interference.
4. **Honest handshake** — deferred `feefilter` / `mempool` / `sendcmpct`; conservative `start_height` (see [Critical: handshake](#critical-handshake--sync-state-too-advanced-disconnects)).
5. **Baseline survey** — before and after batch sync: `npm run survey:scripts -- --db ./data-ts/tsbitnode.db --scan-blocks 20` (requires blocks downloaded past `validated_height`).
6. **Target heights** — use testnet4 milestones above; not mainnet activation heights.
7. **Blocker ledger** — capture exact height/tx/input/template before implementing.
8. **Repo hygiene** — commit source/tests/docs/snapshots; do not commit live DBs or generated output.

---

## Current state (conversation snapshot)

Static status here will go stale quickly. Use the commands below before making
claims about current progress:

```bash
cd PythonNode && .venv/bin/pybitnode-db --db ./data/pybitnode.db
cd TypeScriptNode && npx tsbitnode-db --db ./data-ts/tsbitnode.db
tail -n 80 PythonNode/sync_batch_run.log
tail -n 80 TypeScriptNode/sync_batch_operational.log
```

Known durable lessons:

| Area | Durable lesson |
|------|----------------|
| Header sync | Verified around the testnet4 horizon in Python and TypeScript |
| Block validation | Real progress is `validated_height`, not downloaded headers |
| Consensus | Stop on missing script rules; do not skip them |
| P2P | Deferred handshake + honest `start_height` during sync |
| Snapshots | Export after settled checkpoints; DB/logs are fresher during active sync |

Re-run tests after P2P changes: `npm test` in `TypeScriptNode`.

---

## Repo hygiene

Python currently has git history. Other ports should get clean git boundaries
before serious work continues.

Rules:

- Keep live datadirs ignored: `data/`, `data-ts/`, future per-port datadirs.
- Keep generated outputs ignored: `.venv/`, `node_modules/`, `dist/`, `build/`,
  `target/`, logs, and local DB files.
- Commit source, tests, docs, fixtures, and exported snapshots only after a
  settled checkpoint.
- Do not commit partial live DBs, generated build trees, or scratch logs.
- Before checkpointing, run status and artifact checks for that port.

---

## Key files

### TypeScript (`TypeScriptNode/src/`)

| File | Purpose |
|------|---------|
| `p2p/peer.ts` | Handshake, deferred messages, disconnect logic |
| `node.ts` | Live node; when to call `completeDeferredHandshake` |
| `cli/syncRunner.ts` | Batch sync entry; mirrors Python flow |
| `sync/headerRefresh.ts` | Header download / `headers_current` transition |
| `config/peers.ts` | Peer defaults, Python peer exclusion |
| `consensus/script/interpreter.ts` | Script templates, opcode evaluation |
| `consensus/script/verify.ts` | Spend-path verification entry |
| `scripts/scriptTemplateSurvey.ts` | Offline script template survey (read-only DB) |

### Python (`PythonNode/`)

| File | Purpose |
|------|---------|
| `scripts/script_template_survey.py` | Offline script template survey (read-only DB) |
| `pybitnode/p2p/peer.py` | Reference handshake behavior |
| `pybitnode/sync_runner.py` | Reference sync orchestration |
| `pybitnode/header_refresh.py` | Reference header sync |
| `pybitnode/wire/capabilities.py` | Capability registry (43 wire caps) |
| `pybitnode/consensus/script/interpreter.py` | Reference script interpreter |
| `pybitnode/consensus/script/verify.py` | Reference spend-path verification |

---

## Quick decision tree

```
Editing P2P handshake?
  └─> Read peer.ts AND peer.py. Defer feefilter/mempool/sendcmpct until headers_current.

Sync failing with immediate disconnect?
  └─> Check start_height vs validated_height. Simplify post-verack to sendheaders only.

Running both nodes?
  └─> ./data + pybitnode.db  vs  ./data-ts + tsbitnode.db. Never mix.

Need live cp6 / serving proof?
  └─> LISTEN mode + completeDeferredHandshake after headers_current, not in syncRunner batch.
```
