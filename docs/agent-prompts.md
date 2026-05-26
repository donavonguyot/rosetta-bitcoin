# Reusable follower-agent prompts

These prompts are for agents working in isolated port repos or worktrees. Replace
bracketed placeholders before use.

## Port one blocker to a follower

```text
You are working on [PORT_NAME] in [PORT_PATH].

Read /Users/donavonguyot/Nodes/AGENTS.md first.
Read /Users/donavonguyot/Nodes/docs/consensus-blockers-testnet4.md for the
blocker facts.

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
1. Inspect the follower's current blocker/status DB and confirm it has reached
   or is expected to reach this height.
2. Compare Python and Java implementations for the rule. Use them as references,
   not as validity oracles.
3. Implement the smallest consensus-correct change in the follower.
4. Add a real fixture/regression test for the blocker.
5. Add a negative test if the rule has a clear failure mode.
6. Run the follower's relevant tests.
7. Resume sync only if the live datadir is not already owned by another writer.
8. Update the follower blocker ledger with exact facts and fixture paths.

Rules:
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

Read /Users/donavonguyot/Nodes/AGENTS.md first.

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
You are comparing PythonNode and JavaNode for consensus rule [RULE].

Read:
- /Users/donavonguyot/Nodes/docs/consensus-blockers-testnet4.md
- /Users/donavonguyot/Nodes/docs/script-semantics-gotchas.md
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

Read /Users/donavonguyot/Nodes/AGENTS.md and the port's existing blocker ledger.

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

Also update /Users/donavonguyot/Nodes/docs/follower-port-matrix.md if this is a
root coordination pass; otherwise report that the root matrix needs updating.

Rules:
- Do not overstate completion; report validated height and binary gate status.
- Distinguish consensus fixes from DB repair or operational reconnect fixes.
```

## Read-only status and survey pass

```text
You are doing a read-only status/survey pass for [PORT_NAME].

Read /Users/donavonguyot/Nodes/AGENTS.md first.

Goal:
Report current progress and likely next blocker without changing live state.

Tasks:
1. Query status using read-only DB access if possible.
2. Report validated_height, header_height, sync_status, current blocker, peer,
   and binary_gate_status.
3. If a script survey tool exists, run it in read-only mode only.
4. Compare the next few blocker heights against
   /Users/donavonguyot/Nodes/docs/consensus-blockers-testnet4.md.

Rules:
- Do not start sync.
- Do not write to the DB.
- Do not remove lock files.
- Do not treat snapshots as live truth when DB is available.
```
