# Reusable follower-agent prompts

These prompts are for agents working in root-owned port directories or isolated
root worktrees. Replace bracketed placeholders before use.

## Bring a port to the 5k baseline

```text
You are working on [PORT_NAME] in /Users/donavonguyot/RB/Nodes/[PORT_DIR].

Read first:
- /Users/donavonguyot/RB/AGENTS.md
- /Users/donavonguyot/RB/Docs/port-baseline-5k.md
- /Users/donavonguyot/RB/Nodes/Shared/consensus/CONSENSUS_RUNWAY.md
- /Users/donavonguyot/RB/Nodes/Shared/conformance/BENCHMARK_CONTRACT.md
- /Users/donavonguyot/RB/Nodes/Shared/templates/port-baseline-5k/README.md
- /Users/donavonguyot/RB/Nodes/Shared/docker/ports/[port].docker.json if it exists

Goal:
Make this port clear the strict 5k baseline.

Required baseline evidence:
- RocksDB owns runtime truth.
- Native crypto is selected, available, and reported.
- Shared script corpus passes 45/45.
- Docker `docker_proof_local` syncs from fresh proof volume to height 5000
  using local Reference P2P.
- WAL is enabled.
- `prefetch_depth=4` and `script_runner_mode=parallel`.
- `utxo_accounting_policy=core_spendable_v1` and
  `chainstate_utxo_count=4574`.
- Compact proof JSON is written under
  `Nodes/Shared/conformance/results/` and imported by Project.

Acceptance commands:
- python3 Project/scripts/import_all.py --db Project/project.db --rebuild
- python3 Project/scripts/preflight_port_baseline.py --db Project/project.db --port [port] --strict
- python3 Project/scripts/preflight_consensus_runway.py --db Project/project.db --port [port] --stage 5k --strict
- python3 Project/scripts/report.py --db Project/project.db --section port-lifecycle
- python3 Project/scripts/report.py --db Project/project.db --section benchmark-suite
- python3 Project/scripts/report.py --db Project/project.db --section leaderboard --gate shakedown_50k
- python3 Project/scripts/report.py --db Project/project.db --section baseline-5k

Rules:
- Do not discover known consensus blockers by syncing until failure. Implement
  the Shared corpus/rule ledger first.
- Do not use alternate stores or fallback crypto for baseline evidence.
- Do not use RPC replay as `docker_proof_local`.
- Do not reuse proof state for the baseline run.
- Do not claim binary-gate success from the 5k baseline.
```

## Port one blocker to a follower

Use this prompt only after the port has clean Shared script-corpus proof or when
Project identifies a specific later-stage consensus gap. It is not the right
prompt for birthing a new port to 5k; new ports should start with the corpus
runway, not live blocker rediscovery.

```text
You are working on [PORT_NAME] in [PORT_PATH].

Read /Users/donavonguyot/RB/AGENTS.md first.
Read /Users/donavonguyot/RB/Nodes/Shared/consensus/CONSENSUS_RUNWAY.md and
/Users/donavonguyot/RB/Nodes/Shared/consensus/rules/testnet4_script_rules_v1.json
for the rule inventory. Read
/Users/donavonguyot/RB/Docs/consensus-blockers-testnet4.md for historical
blocker provenance.

Goal:
Port the consensus rule needed to clear testnet4 height [HEIGHT] without
weakening validation.

Blocker facts:
- height: [HEIGHT]
- block_hash: [BLOCK_HASH]
- txid: [TXID]
- input_index: [INPUT_INDEX]
- spent_script_pubkey: [SPENT_SCRIPT_PUBKEY]
- failure: [FAILURE]
- rule/template: [RULE]

Tasks:
1. Query Project's consensus runway and blocker catalog for the port and stage.
2. Confirm the target rule card and fixture IDs in the Shared rule ledger.
3. Compare Python and Java implementations for the rule. Use them as references,
   not as validity oracles.
4. Implement the smallest consensus-correct change in the follower.
5. Add or run the Shared fixture/regression test for the blocker.
6. Add a negative test if the rule has a clear failure mode.
7. Run the follower's relevant tests and script corpus.
8. Resume sync only if the live datadir is not already owned by another writer.
9. Update the follower blocker ledger with exact facts and fixture paths.
10. Rebuild Project and run `preflight_consensus_runway.py` for the relevant stage.

Rules:
- Do not use live sync to rediscover a known Shared corpus/rule-ledger blocker.
- Do not skip validation.
- Do not run two writers on one datadir.
- Do not mutate another port's datadir.
- Do not commit unless explicitly asked.

Return:
- root cause
- files changed
- tests added/run
- validated height after resume, if sync was run
- next blocker, if any
```

## Harvest a fixture for a blocker

```text
You are working on [PORT_NAME] in [PORT_PATH].

Read /Users/donavonguyot/RB/AGENTS.md first.

Goal:
Harvest a deterministic test fixture for blocker height [HEIGHT].

Tasks:
1. Locate the raw block or transaction bytes from the port's block store, local
   Reference Core RPC, or an existing Python/Java fixture.
2. Extract:
   - block hash
   - txid
   - input index
   - prevout txid/vout
   - spent scriptPubKey
   - spent amount
   - scriptSig/witness
   - redeem script or witness script, if present
3. Store fixture files under the port's normal test fixture directory.
4. Add a README or metadata file beside the fixture.
5. Add a pending or active regression test that documents expected behavior.

Rules:
- Reference Core is a byte source, not a validation oracle.
- Fixture extraction may use RPC, but the test must verify independently.
- Do not write to live sync DBs except through existing read-only fixture tools.

Return:
- fixture paths
- extracted facts
- test path
- any missing data
```

## Compare Python and Java for one rule

```text
You are comparing Python and Java for consensus rule [RULE].

Read:
- /Users/donavonguyot/RB/Nodes/Shared/consensus/CONSENSUS_RUNWAY.md
- /Users/donavonguyot/RB/Nodes/Shared/consensus/rules/testnet4_script_rules_v1.json
- /Users/donavonguyot/RB/Docs/consensus-blockers-testnet4.md
- /Users/donavonguyot/RB/Docs/script-semantics-gotchas.md
- relevant Python and Java script/sighash/connect code

Goal:
Produce a language-neutral description of [RULE] suitable for follower ports.

Tasks:
1. Find the Python implementation and tests.
2. Find the Java implementation and tests.
3. Identify semantic agreement and any implementation-specific differences.
4. Identify the blocker heights that require this rule.
5. Draft follower-port checklist items.

Rules:
- Do not edit code.
- Do not declare one implementation authoritative when they differ; flag the
  difference for review.

Return:
- rule summary
- Python files/tests
- Java files/tests
- blocker heights
- follower checklist
- unresolved questions
```

## Update a follower ledger after clearing a blocker

```text
You cleared a consensus blocker in [PORT_NAME].

Read /Users/donavonguyot/RB/AGENTS.md and the port's existing blocker ledger.

Goal:
Record enough information for the next follower port to reproduce the fix
without archaeology.

Add an entry with:
height:
block_hash:
txid:
input_index:
spent_script_pubkey:
failure:
missing_rule:
python_fix:
java_fix:
test_fixture:
follower_notes:

If this is a root coordination pass, import Project and verify the generated
blocker matrix instead of editing matrix Markdown:

```bash
python3 Project/scripts/import_all.py --db Project/project.db --rebuild
python3 Project/scripts/report.py --db Project/project.db --section blocker-matrix
python3 Project/scripts/report.py --db Project/project.db --section consensus-runway
```

Rules:
- Do not overstate completion; report validated height and binary gate status.
- Distinguish consensus fixes from DB repair or operational reconnect fixes.
```

## Read-only status and survey pass

```text
You are doing a read-only status/survey pass for [PORT_NAME].

Read /Users/donavonguyot/RB/AGENTS.md first.

Goal:
Report current progress and likely next blocker without changing live state.

Tasks:
1. Query status using read-only DB access if possible.
2. Report validated_height, header_height, sync_status, current blocker, peer,
   and binary_gate_status.
3. If a script survey tool exists, run it in read-only mode only.
4. Compare the next few blocker heights against the Shared rule ledger and
   /Users/donavonguyot/RB/Docs/consensus-blockers-testnet4.md provenance notes.
5. For project-level status context, query Project reports instead of
   hand-maintained Markdown:

```bash
python3 Project/scripts/report.py --db Project/project.db --section port-status
python3 Project/scripts/report.py --db Project/project.db --section blocker-matrix
python3 Project/scripts/report.py --db Project/project.db --section consensus-runway
```

Rules:
- Do not start sync.
- Do not write to port-local operational DBs or datadirs.
- Do not remove lock files.
- Do not treat snapshots as live truth when DB is available.
```

## Port the performance pattern

```text
You are working on [PORT_NAME] in [PORT_PATH].

Read /Users/donavonguyot/RB/AGENTS.md first.
Read /Users/donavonguyot/RB/Docs/port-performance-lessons.md.

Goal:
Port the proven Java/Python block-connect performance pattern without changing
consensus outcomes.

Tasks:
1. Confirm no active sync/connect writer owns the target datadir.
2. Identify the port's block connect, UTXO tracker/store, config, and script
   verification entry points.
3. Add or verify per-block timing for:
   - utxo_load
   - script_verify
   - utxo_apply
   - commit
   - block_connect_store_commit
4. Add a block-local UTXO view with created/spent/loaded state if missing.
5. Reuse loaded prevouts for undo creation.
6. Batch UTXO spends and creates inside one atomic block-connect transaction.
7. Add configurable per-transaction input parallel script verification only
   after prevouts are loaded.
8. Preserve deterministic blocker reporting by height, txid, input index, and
   spent scriptPubKey.
9. Run the port's relevant tests and one measured connect-only replay on an
   isolated or single-writer datadir.

Rules:
- Do not skip script rules.
- Do not parallelize UTXO writes.
- Do not reorder block transactions.
- Do not share one mutable runtime store handle unsafely across worker threads.
- Do not treat another port's sync outcome as proof.

Return:
- before/after timing table
- files changed
- tests run
- validated height after replay or resume
- next blocker, if any
- whether this improves throughput or moves the binary gate
```
