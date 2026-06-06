# AGENTS.md — Nodes workspace guide for AI agents

Quick context for agents working under `~/RB`. Read this before touching P2P
handshake, sync, consensus validation, datadirs, or port-following work.

---

## True North

The binary end gate for every serious node in this workspace is:

> From empty local state on Bitcoin testnet4, the node reaches and maintains tip
> while independently validating every stored connected block.

Partial sync, headers-only sync, trusted import, matching another node without
independent validation, or skipping unknown consensus rules does **not** pass.

## Canonical read order

Before editing a port, read:

1. `README.md` at the workspace root.
2. `Docs/README.md`.
3. `Docs/git-topology.md`.
4. `Docs/port-baseline-5k.md` before new-port, benchmark, or readiness work.
5. `Nodes/Shared/consensus/CONSENSUS_RUNWAY.md` before consensus, corpus, or long-sync readiness work.
6. `Docs/port-status.md` and Project reports for current imported status.
7. `Nodes/Shared/testing/TEST_COVERAGE_CONTRACT.md` before test coverage or par-level work.
8. `Nodes/Shared/STATUS_CONTRACT.md`.
9. `Nodes/Shared/storage/STORAGE_GATE.md`.
10. `Nodes/Shared/chainstate/CHAINSTATE_STORE.md`.
11. `Nodes/Shared/docker/DOCKER_RUNTIME_CONTRACT.md`.
12. The target port manifest in `Nodes/Shared/docker/ports/<port>.docker.json` before Docker work.
13. `Nodes/Shared/docker/PORT_DOCKER_INVENTORY.md` for Project Docker query examples.
14. `Docs/artifact-retention.md` before deleting, moving, or preserving proof/log/datadir artifacts.
15. `Docs/blocker-ledger.md`.
16. `Docs/supervisor-contract.md`.
17. The target port's README and blocker ledger.

The official benchmark suite is `baseline_5k`, `shakedown_50k`,
`performance_100k`, `tip_once`, and `tip_maintenance`. The first comparable
readiness standard is the **5k baseline**. A port is not baseline-ready until
Project can show: RocksDB runtime truth, native crypto, Shared script corpus
`45/45`, Docker local Reference P2P to height `5000`, fresh proof state, WAL
enabled, fixed benchmark knobs, `core_spendable_v1` UTXO accounting with
`chainstate_utxo_count=4574`, and compact proof JSON that imports as
`artifact_quality=canonical`.
Long-run gates (`shakedown_50k`, `performance_100k`, and tip lanes) also require
`telemetry_quality=clean`; `shakedown_50k` is the telemetry acceptance gate
before any current `performance_100k` attempt.

```bash
python3 Project/scripts/report.py --db Project/project.db --list-sections
python3 Project/scripts/report.py --db Project/project.db --section benchmark-suite
python3 Project/scripts/report.py --db Project/project.db --section leaderboard --gate shakedown_50k
python3 Project/scripts/report.py --db Project/project.db --section baseline-5k
python3 Project/scripts/preflight_port_baseline.py --db Project/project.db --port <port> --strict
```

Consensus readiness uses a separate runway from corpus to tip. Start from the
Shared rule ledger and Project runway checks, not from scattered port history:

```bash
python3 Project/scripts/report.py --db Project/project.db --section consensus-runway
python3 Project/scripts/preflight_consensus_runway.py --db Project/project.db --port <port> --stage corpus --strict
```

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

Core Node compliance is not a single green test. Keep consensus progress,
native storage compliance, Docker runtime compliance, and Project imports
separate. `Project/project.db` is mission control. Ports must use their approved
native operational storage for runtime truth such as headers, block index, sync
state, validated tip, UTXO, undo, chainstate metadata, blocker state, and status
fields.
Docker compliance requires a manifest and the runtime contract in
`Nodes/Shared/docker/DOCKER_RUNTIME_CONTRACT.md`. Before changing Docker behavior,
read the port manifest and run the report-only validator:

```bash
python3 Nodes/Shared/docker/validate_docker_contract.py
```

Artifact cleanup follows `Docs/artifact-retention.md` and
`Nodes/Shared/conformance/ARTIFACT_INVENTORY.md`: canonical proof JSON belongs in
`Nodes/Shared/conformance/results/`, current Project claims are curated in
`Nodes/Shared/conformance/current_evidence.json`, and live datadirs, logs, DBs,
build outputs, and Docker volumes stay ignored and port-local.

For mission-control status, blocker matrices, Docker coverage, conformance
summaries, benchmark summaries, and test coverage posture, query
`Project/project.db` instead of hand-maintained Markdown tables:

```bash
python3 Project/scripts/report.py --db Project/project.db --section port-status
python3 Project/scripts/report.py --db Project/project.db --section blocker-matrix
python3 Project/scripts/report.py --db Project/project.db --section test-coverage
python3 Project/scripts/preflight_test_coverage.py --db Project/project.db --all --level inventory
```

This workspace has exactly one Git repository: `/Users/donavonguyot/RB/.git`.
All `Nodes/<Port>/` directories are root-owned source directories. Nested
`.git/` directories are legacy cruft and must not be recreated.

---

## Project layout and roles

| Path | Package | Role |
|------|---------|------|
| `~/RB/Nodes/Python` | **pybitnode** | RocksDB/native-crypto reference implementation and provenance source |
| `~/RB/Nodes/TypeScript` | **tsbitnode** | RocksDB/native-crypto follower |
| `~/RB/Nodes/Cpp` | **cpbitnode** | Systems follower |
| `~/RB/Nodes/CSharp` | **csbitnode** | Managed-runtime follower |
| `~/RB/Nodes/Go` | **gobitnode** | Fast native follower |
| `~/RB/Nodes/Java` | **jbitnode** | Clean Java follower and provenance source |
| `~/RB/Nodes/OCaml` | **ocbitnode** | Stock OCaml 5 native/RocksDB follower foundation |
| `~/RB/Nodes/Rust` | **rsbitnode** | Native follower |
| `~/RB/Nodes/Elixir` | **exbitnode** | BEAM follower |

All active nodes target **Bitcoin testnet4**. They can run in parallel only with
isolated state and deliberate peer allocation.

### Port independence and Python full-break rule

Historical Python blocker rows are handoff evidence, not forward validity proof.
Python parity now requires RocksDB-owned operational truth, native crypto, full
Docker proof/supervisor, and Project-importable evidence from the native path.

No port may treat another port as an oracle for validity. Shared blocker ledgers,
rule cards, tests, and fixture details are the reusable consensus runway; each
port must independently validate them with its own current implementation and
active storage backend. A new port must not rediscover known script blockers by
syncing until failure. It must implement the Shared script corpus first and prove
`45/45` with `port.script_corpus_result.v1`.

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

### Historical Python / Java trail

Shared coordination docs turn historical Python scout notes and Java live-chain
notes into provenance for ports:

- [`Nodes/Shared/consensus/CONSENSUS_RUNWAY.md`](Nodes/Shared/consensus/CONSENSUS_RUNWAY.md) — canonical corpus-to-tip consensus path.
- [`Nodes/Shared/consensus/rules/testnet4_script_rules_v1.json`](Nodes/Shared/consensus/rules/testnet4_script_rules_v1.json) — primary rule inventory.
- [`Docs/consensus-blockers-testnet4.md`](Docs/consensus-blockers-testnet4.md) — durable blocker facts and fixture anchors.
- [`Docs/follower-port-matrix.md`](Docs/follower-port-matrix.md) — Project query guide for the generated blocker matrix.
- [`Docs/script-semantics-gotchas.md`](Docs/script-semantics-gotchas.md) — language-neutral consensus traps; includes **Shared script corpus triage** (stack/sighash/template vs missing opcode).
- [`Docs/port-performance-lessons.md`](Docs/port-performance-lessons.md) — reusable block-connect performance patterns from Java/Python catch-up.
- [`Docs/agent-prompts.md`](Docs/agent-prompts.md) — reusable prompts for porting blockers, harvesting fixtures, and updating ledgers.

Ports use blocker facts and tests from this trail, not trust outcomes. Project
owns current imported consensus readiness.

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
Java/C++/C# followers should copy the same sync posture unless Shared contracts
or Project evidence replace it.

---

## Peer strategy

| Topic | Python (pybitnode) | TypeScript (tsbitnode) |
|-------|--------------------|-------------------------|
| Default ops peer | Often `89.167.10.150:48333` | **Excluded by default** (parallel runs) |
| Fallback | — | DNS seed; falls back to `89.167.10.150` when seeds fail |
| Datadir | `./data` | `./data-ts` |
| Operational state | `chainstate-rocksdb` | `chainstate-rocksdb` |

**Never share datadirs or operational state between nodes or parallel agent runs.** One writer per datadir at a time.

### Single writer rule (TypeScript)

TypeScript enforces one native chainstate writer per datadir via
**`<datadir>/.tsbitnode_sync.lock`** (pid + holder metadata). These entry points
acquire or respect the lock:

| Process | Lock behavior |
|---------|---------------|
| `syncBatchLoop` | Holds lock for the full batch loop |
| `tsbitnode-sync` (`syncRunner`) | Acquires lock; batch-loop children inherit parent lock via `TSBITNODE_SYNC_LOCK_PARENT_PID` |
| `tsbitnode` (`node.ts`) | Acquires lock for the full run |

**Never run `syncBatchLoop` and a standalone `tsbitnode-sync` / `tsbitnode` on the same datadir.**
If a second process starts while the lock is held, it exits with:

```text
error: another sync process holds lock (pid …): …/.tsbitnode_sync.lock
```

Stale locks (dead pid) are reclaimed automatically. Legacy **`.sync_batch_loop.lock`**
files are also checked so an old batch loop cannot overlap a new sync.

Before starting sync, confirm no conflicting process:

```bash
ps aux | rg 'syncBatchLoop|syncRunner|tsbitnode-sync|dist/cli/node'
ls -la Nodes/TypeScript/data-ts/.tsbitnode_sync.lock 2>/dev/null
```

### UTXO stall at 5579 (TypeScript repair playbook)

**Symptom:** Block connect fails at height **5579** with `missing UTXO …` (often after
parallel sync writers or interrupted rebuild).

**Cause:** Dual-writer corruption — two processes wrote UTXO/state concurrently on the same
datadir (e.g. `syncBatchLoop` + manual `tsbitnode-sync`, or overlapping rebuild + batch).

**Recovery:**

```bash
cd Nodes/TypeScript && npm run build
# Ensure no other sync holds the lock; wait for any in-flight rebuild to finish first.
npx tsbitnode-sync --datadir ./data-ts --connect-only --rebuild
```

Rebuild must hold the exclusive lock and exit **0** before resuming batches.

**Verify before batches:** `validated_height >= 5579` and UTXO count sane.
For native state, use:

```bash
npx tsbitnode-status --datadir ./data-ts
```

Only then resume:

```bash
./scripts/sync_batch_loop.sh --datadir ./data-ts --target 10000 --blocks-max 200
```

### Wait for rebuild

Do **not** start `syncBatchLoop`, manual `tsbitnode-sync`, or `tsbitnode` on a datadir while
`--connect-only --rebuild` is running. Rebuild rewrites the full validated chain and UTXO set;
overlapping writers recreate the 5579-class stall.

Wait until rebuild **exits 0** and the lock file is gone, then verify heights before batch sync.

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
- TypeScript **Core/native mode may use runtime npm dependencies** when they are
  tightly scoped native infrastructure bindings for RocksDB and
  `libsecp256k1`. These dependencies must not provide Bitcoin consensus, wallet,
  P2P, transaction, script, or chain logic.
- Pure TypeScript crypto/storage paths may remain as comparators or legacy
  tools, but Core proofs must report the selected RocksDB and native crypto
  backends. Official TypeScript runtime truth is RocksDB.
- **Docker:** generic `docker-compose`; works on OrbStack. Native/Core Docker
  proof paths must install the same RocksDB and `libsecp256k1` runtime
  dependencies used by host proof paths.

---

## Common agent mistakes

| Mistake | Why it fails |
|---------|----------------|
| Running sync batch in a **sandbox without network** | False “broken sync” diagnosis; peers never connect |
| Calling `completeDeferredHandshake()` **before block sync** | Peers disconnect; “too advanced” |
| Advertising **inflated `start_height`** | Remote peer drops connection |
| **Two writers** on same datadir | Native chainstate corruption / lock errors; UTXO stall at 5579 |
| **syncBatchLoop + manual tsbitnode-sync** on same datadir | Dual writer; use `.tsbitnode_sync.lock` — see [Single writer rule](#single-writer-rule-typescript) |
| **Parallel agents** editing `peer.ts` | Merge conflicts and conflicting handshake logic |
| Editing consensus/P2P while a sync process is live | Run may mix old state with new code; blocker diagnosis becomes muddy |
| Treating snapshots as live truth | Snapshots can lag state/logs; check live status before conclusions |
| Skipping an unsupported script template | Produces false validation; stop and record the missing rule instead |
| Porting implementation details without the blocker facts | Followers drift or overfit; use the blocker ledger |

---

## How to run TypeScript sync

```bash
cd Nodes/TypeScript && npm run build
DATA_DIR=./data-ts node dist/cli/syncRunner.js
```

With Python’s default peer (explicit override):

```bash
cd Nodes/TypeScript
PEERS=89.167.10.150:48333 MAX_OUTBOUND_PEERS=1 SKIP_GETADDR=1 node dist/cli/syncRunner.js
```

Block-only pass after headers are current:

```bash
node dist/cli/syncRunner.js --no-header-refresh --blocks-max 64
```

---

## How to run JavaNode sync

**Manual chunks** (default 5000 blocks) or **durable supervisor** for unattended catch-up:

```bash
cd Nodes/Java
make java-node-preflight

# manual chunk (repeat until blocker or tip):
make java-node-sync-chunk DATA_DIR=./data-java PEERS=127.0.0.1:48333
make java-node-status

# unattended (recommended overnight): sub-chunks + auto-restart on crash/stall
make java-node-sync-supervisor DATA_DIR=./data-java PEERS=127.0.0.1:48333
# stop: touch data-java/.stop_sync
```

Single-shot large chunk (no auto-restart): `make java-node-sync-chunk-overnight` (15000) or
`BLOCKS_MAX=25000`. JSON-only status for scripts: `make java-node-db-status`.

**Single writer:** `.jbitnode.lock` on `./data-java` (pid metadata); preflight reclaims stale locks.
On `ValidationBlocker`: harvest → fix → `mvn verify` → update `Nodes/Java/docs/BLOCKER_LEDGER.md` → resume.
Supervisor exits **2** on blocker; inner `SyncLocalCore` exit **4**. Abnormal JVM exit sets
`blocks_stalled` + supervisor restart (up to `MAX_RESTARTS=5`). The old Java
Retired snapshot/survey targets are historical; use `make java-node-status` and
Project reports for current mission-control state.

---

## How to verify progress

```bash
cd Nodes/TypeScript
npm run build

# Native chainstate status
npx tsbitnode-status --datadir ./data-ts

# Sync report
npm run sync:progress

```

Key fields: **`header_height`**, **`validated_height`**, **`sync_status`**.

For Python, prefer live native-state status when the node is running and
snapshots after a settled checkpoint:

```bash
cd Nodes/Python
.venv/bin/pybitnode-status --state-path ./data/chainstate-rocksdb
.venv/bin/python scripts/export_snapshots.py --state-path ./data/chainstate-rocksdb
```

Snapshots are committed checkpoint artifacts. They are not guaranteed to reflect
the latest live native state while sync is running.

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

### Shared script corpus gate (offline)

Before any live-sync script diagnosis, ports must pass the shared **45-fixture**
corpus in [`Nodes/Shared/conformance/fixtures/scripts/manifest.json`](Nodes/Shared/conformance/fixtures/scripts/manifest.json)
and record JSON under [`Nodes/Shared/conformance/results/`](Nodes/Shared/conformance/results/).
The accepted port proof shape is `port.script_corpus_result.v1`; Shared manifest
validation is not port proof.
When a fixture fails, read **[`Docs/script-semantics-gotchas.md`](Docs/script-semantics-gotchas.md)
§ Shared script corpus and MATRIX triage** first: failures are often loader,
sighash, template limits, or stack semantics — not a missing opcode. Do not treat
manifest `missing_rule` or MATRIX labels as ground truth without `ScriptError` text.

Use Project for current corpus and runway state:

```bash
python3 Project/scripts/report.py --db Project/project.db --section consensus-runway
python3 Project/scripts/preflight_consensus_runway.py --db Project/project.db --port <port> --stage corpus --strict
```

| Milestone | Height / target | Notes |
|-----------|-----------------|-------|
| First P2TR stall (documented) | **6975** | Taproot key-path spend; see [`Nodes/Python/docs/OPERATIONS.md`](Nodes/Python/docs/OPERATIONS.md) § block 6975 |
| Python batch reference | **10000** | Common `--blocks-target` for staged catch-up |
| Mainnet Taproot activation | **709632** | **Do not use** as a testnet4 sync target or milestone |

### TypeScript gaps (consensus / tests)

| Gap | Status |
|-----|--------|
| **CLTV / CSV** (BIP65 / BIP112) | **Implemented** in TS (`interpreter.ts`): `OP_CHECKLOCKTIMEVERIFY` / `OP_CHECKSEQUENCEVERIFY` with `SCRIPT_VERIFY_*` flags (ported from Python). Re-run `npm test` after interpreter changes. |
| **Multisig test coverage** | `CHECKMULTISIG` exists in the interpreter; no dedicated multisig fixtures in `tests/script.test.ts` (Python has richer coverage in `tests/test_script.py`). |
| **Script template survey** | `npm run survey:scripts` — read-only port of Python `script_template_survey.py` |

### Consensus validation rule

If a spent output requires a script rule that is not implemented, stop with a
bounded validation blocker. Do not connect the block by assuming success.

For new ports and 5k baseline work, this should happen offline against the
Shared corpus first. Heights like `739`, `6975`, and the later Python/Java
blocker trail are already captured as Shared fixtures and rule cards; they are
not prompts to rediscover consensus from live sync. Live blocker discovery is
only appropriate after the port already has clean corpus proof and reaches
beyond the known imported runway.

When a genuinely new live-chain blocker appears beyond the Shared corpus:

```text
record exact blocker -> add/link Shared fixture and rule card
  -> implement exact missing rule -> prove with corpus or live artifact -> resume
```

### Parallel prep checklist (consensus / sync agents)

1. **Isolated datadirs** — Python `./data` + `chainstate-rocksdb` vs TypeScript `./data-ts` + `chainstate-rocksdb`; never share or copy mid-write.
2. **One writer** per datadir; survey/export tools must not overlap active writers.
3. **Peer exclusion** — TS excludes Python’s default ops peer (`89.167.10.150`) unless `PEERS=` overrides; avoids cross-node interference.
4. **Honest handshake** — deferred `feefilter` / `mempool` / `sendcmpct`; conservative `start_height` (see [Critical: handshake](#critical-handshake--sync-state-too-advanced-disconnects)).
5. **Target heights** — use testnet4 milestones above; not mainnet activation heights.
6. **Blocker ledger** — capture exact height/tx/input/template before implementing.
7. **Repo hygiene** — commit source/tests/docs/snapshots; do not commit live DBs or generated output.

---

## Current state (conversation snapshot)

Static status here will go stale quickly. Use the commands below before making
claims about current progress:

```bash
cd Nodes/Python && .venv/bin/pybitnode-status --state-path ./data/chainstate-rocksdb
cd Nodes/TypeScript && npx tsbitnode-status --datadir ./data-ts
tail -n 80 Nodes/Python/sync_batch_run.log
tail -n 80 Nodes/TypeScript/sync_batch_operational.log
```

Known durable lessons:

| Area | Durable lesson |
|------|----------------|
| Header sync | Verified around the testnet4 horizon in Python and TypeScript |
| Block validation | Real progress is `validated_height`, not downloaded headers |
| Consensus | Stop on missing script rules; do not skip them |
| P2P | Deferred handshake + honest `start_height` during sync |
| Snapshots | Export after settled checkpoints; live status/logs are fresher during active sync |

Re-run tests after P2P changes: `npm test` in `Nodes/TypeScript`.

---

## Repo hygiene

This workspace uses a single root Git repo. For ownership boundaries, read
`Docs/git-topology.md`.

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

### TypeScript (`Nodes/TypeScript/src/`)

| File | Purpose |
|------|---------|
| `p2p/peer.ts` | Handshake, deferred messages, disconnect logic |
| `node.ts` | Live node; when to call `completeDeferredHandshake` |
| `cli/syncRunner.ts` | Batch sync entry; mirrors Python flow |
| `sync/headerRefresh.ts` | Header download / `headers_current` transition |
| `config/peers.ts` | Peer defaults, Python peer exclusion |
| `consensus/script/interpreter.ts` | Script templates, opcode evaluation |
| `consensus/script/verify.ts` | Spend-path verification entry |
| `scripts/scriptTemplateSurvey.ts` | Retired compatibility script template survey (read-only) |

### Python (`Nodes/Python/`)

| File | Purpose |
|------|---------|
| `scripts/script_template_survey.py` | Offline script template survey (read-only native state) |
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
  └─> ./data + chainstate-rocksdb  vs  ./data-ts + chainstate-rocksdb. Never mix.

Need live cp6 / serving proof?
  └─> LISTEN mode + completeDeferredHandshake after headers_current, not in syncRunner batch.
```
