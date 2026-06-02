# pybitnode operations runbook

Operations reference for syncing, rebuilding tracker state from disk, exporting snapshots, and running the node with inbound peers. Paths assume repo root (`PythonNode/`).

Deep dives on how header/block sync and persistence fit together live in [`ARCHITECTURE.md`](ARCHITECTURE.md); this file focuses on procedures and knobs—including the [**lightweight block-sync handshake**](#lightweight-block-sync-handshake-no-header-refresh) when skipping header refresh, and the [**consensus stall playbook**](#consensus-stall-playbook-invalid-blocks) when validation rejects blocks during sync.

---

## Safe parallel work vs the live database

**Single writer rule:** SQLite under `datadir` (`pybitnode.db`) must have **at most one** active writer among `pybitnode-sync`, long-running `pybitnode`, or any script that opens the tracker for mutation. Duplicate writers corrupt data or deadlock.

**`pybitnode-sync` datadir lock:** Each sync run tries to take an exclusive non-blocking flock on **`<datadir>/.pybitnode-sync.lock`** (`ExclusiveDataDirSyncLock` in [`pybitnode/sync/sync_datadir_lock.py`](../pybitnode/sync/sync_datadir_lock.py)). A second concurrent **`pybitnode-sync`** against the same `--datadir` exits with *Another pybitnode-sync holds this datadir*. This does **not** stop a simultaneous long-running **`pybitnode`** process on the same disk—you must still enforce the single-writer rule operationally ([Batch block sync](#batch-block-sync-pybitnode-sync) and [**Batch loop helper**](#batch-loop-helper)).

**Do instead:**

| Goal | Approach |
| ---- | -------- |
| Inspect metrics / JSON dashboards | Run `scripts/export_snapshots.py` against a **quiescent** DB, or query with `pybitnode-db`, or copy the DB file when nothing is writing and open the copy read-only elsewhere. |
| Experiment with sync flags | Point at a **separate `--datadir`** (full clone or fresh sync), not the production disk. |
| Long batch jobs in parallel | Run **different datadirs** (one process each), merge results only by intentional policy—not by sharing one DB. |

### Operational recap (single writer, lock, checkpoints)

- **SQLite / datadir:** At most **one** process performing **writes** (`pybitnode-sync`, long-running **`pybitnode`**, rebuild tools) per `--datadir`/DB pair.
- **`.pybitnode-sync.lock`:** Blocks another **`pybitnode-sync`** instance on that datadir immediately; **does not** coordinate with **`pybitnode`** or ad hoc writers—enforce the rule above separately.
- **Between batch invocations:** Let each **`pybitnode-sync`** exit cleanly; only then start the next run—see [recommended batch workflow](#recommended-iterative-batches-toward-10k-no-header-refresh) and, after the first major milestone, [continuing toward the header tip in batches](#after-10k-validated-continue-toward-the-header-tip-batches).
- **Snapshots / dashboards:** Export JSON **between** batches when the DB is **quiescent**—see [when to export](#when-to-export-snapshots-timing)—never rely on **`export_snapshots.py`** timing as your default **during** heavy validation flushes.

**Between batch runs** (same datadir, sequential batches): stop the sync process cleanly before starting the next `pybitnode-sync` invocation. Export snapshots after stopping if you want a checkpoint on disk—see [Snapshot export workflow](#snapshot-export-workflow-snapshots).

---

## Batch block sync (`pybitnode-sync`)

Typical iterative catch-up toward a validation height limit:

```bash
.venv/bin/pybitnode-sync \
  --datadir ./data \
  --blocks-target 10000 \
  --blocks-max 200 \
  --peers HOST:PORT,HOST2:PORT
```

| Flag | Role |
|------|------|
| `--blocks-max` | Upper bound on how many blocks this **run** attempts to validate (applied per internal batching; default env `BLOCKS_MAX_PER_RUN` applies if unset). Practical batch size for long runs is often **200** for predictable wall-clock chunks. |
| `--blocks-target` | Stop once `validated_height` reaches this height (or sooner if stalled). Maps to env `BLOCKS_TARGET_HEIGHT`. |
| `--peers` | Optional comma-separated `host:port` list for bootstrap; otherwise discovery / defaults apply. Overrides env `PEERS`. |
| `--datadir` / `--db` | Data directory (`./data`) or explicit SQLite path. |

**Single-node rule (recap):** Run at most **one** `pybitnode-sync` (or live `pybitnode`) against the **same** `--datadir` / DB.

**Avoid `pgrep -f …pybitnode-sync…` checks for automation.** `pgrep -f` scans the entire command line, so operators often observed **false positives** from parent shells wrapping a sync (for example **`bash -c '…'`** whose `-c` string contains `pybitnode-sync`). That can look like a “duplicate writer” stall even when **`pybitnode-sync` is idle**. Prefer [**`scripts/sync_batch_loop.sh`**](#batch-loop-helper) (POSIX `fcntl` lock on `<datadir>/.sync_batch_loop.lock`; portable macOS/Linux) instead of probing processes. For occasional manual reassurance, skim **`ps -ax -o pid,args`** yourself and distinguish real **`python …/bin/pybitnode-sync`** (or **`.venv/bin/pybitnode-sync`** as an executable argument) from pure shell wrappers.

### Cursor chunk workflow with local Reference Core

For long Cursor-managed catch-up, mirror the JavaNode operating model: bounded
chunks against local Reference Core, one writer, parseable summaries, and a
separate read-only monitor.

Default local peer:

```text
127.0.0.1:48333
```

Normal chunk:

```bash
make python-node-preflight
make python-node-sync-chunk DATA_DIR=./data PEERS=127.0.0.1:48333 \
  2>&1 | tee sync_chunk_<startheight>.log
make python-node-status
make python-node-export-snapshots
```

Long unattended chunk:

```bash
make python-node-sync-chunk-overnight DATA_DIR=./data PEERS=127.0.0.1:48333 \
  2>&1 | tee sync_chunk_overnight.log
```

Read-only Cursor monitor in a separate terminal:

```bash
PYTHONPATH=. .venv/bin/python scripts/cursor_sync_monitor.py \
  --datadir ./data --target 52050 --interval 120
```

The monitor emits low-noise sentinel lines:

```text
AGENT_LOOP_TICK_pybitnode_sync {"validated_height": ..., "sync_status": "...", ...}
```

`make python-node-sync-chunk` defaults to local Reference Core, `BLOCKS_MAX=5000`,
`--no-header-refresh`, `MAX_OUTBOUND_PEERS=1`, `PARALLEL_BLOCK_DOWNLOADS=0`, and
`SKIP_GETADDR=1`. It uses Reference Core as a byte source only; Python still
validates independently.

On blocker: record `validated_height`, `header_height`, `current_blocker`,
`txid`, `input_index`, `spent_script_pubkey`, and fixture paths; add the failing
regression; implement the smallest consensus fix; run `make test`; update
`docs/BLOCKER_LEDGER.md`; then resume with `make python-node-sync-chunk`.

### Batch loop helper

Wrapper path: **`scripts/sync_batch_loop.sh`** → **`scripts/sync_batch_loop.py`**. Behavior:

| Mechanism | What it solves |
|-----------|----------------|
| **`fcntl LOCK_EX`** on `<datadir>/.sync_batch_loop.lock` | Exclusive lock for exactly one scripted batch orchestrator (**no pgrep duplication checks** for the runner). Separate from **`pybitnode-sync`’s** **`<datadir>/.pybitnode-sync.lock`**, which still serializes **`pybitnode-sync`** SQLite writers per datadir. |
| **`read_validated_height_db` via `sqlite_readonly_uri` (`mode=ro`)** inside `scripts/sync_progress_report.py` | Polling **`validated_height` between batches** does **not** open the SQLite file for mutation (avoids unintended writer locks). |

Illustrative usage (**replace datadir/peers/host**):

```bash
MAX_OUTBOUND_PEERS=1 PARALLEL_BLOCK_DOWNLOADS=0 SKIP_GETADDR=1 \
  ./scripts/sync_batch_loop.sh \
  --datadir /path/to/datadir \
  --target 10000 \
  --blocks-max 200 \
  --no-header-refresh \
  --peers HOST:PORT \
  --log ./sync_batch_run.log
```

Pass additional **`pybitnode-sync`** flags after `--` (`./scripts/sync_batch_loop.sh … -- --some-flag`). See `scripts/sync_batch_loop.py --help`. On **consensus stall** (`validated_delta=0` with sync exit **0**), the loop logs **`=== STALL … ===`** and exits **5** instead of burning remaining **`--max-batches`**. Progress summaries from the tracker without mutating SQLite: `scripts/sync_progress_report.py … --db /path/pybitnode.db` (bare `--db` defaults to `./data/pybitnode.db`).

### Recommended iterative batches toward 10k (no header refresh)

Use **`--no-header-refresh`** for this pattern when headers are trustworthy for the horizon you are syncing (otherwise allow normal networked header refresh). For a staged catch-up toward **`--blocks-target 10000`**:

1. **Batch size:** Use **`--blocks-max 200`** per run so wall-clock chunks stay predictable ([Expected timings](#expected-timings--performance)).
2. **Blocks vs headers:** With **`--no-header-refresh`**, **`pybitnode-sync`** trusts headers already in SQLite and follows the [**lightweight block-sync handshake**](#lightweight-block-sync-handshake-no-header-refresh)—less **`getheaders`** churn and better interoperability for historical **`getdata`**. If you need to extend headers from peers first, omit **`--no-header-refresh`** for that stretch, then resume block batches with it once stored headers cover the next target.
3. **Iterate:** Repeat `pybitnode-sync` until **`validated_height`** reaches the target or progress stalls ([Stuck sync recovery](#stuck-sync-recovery)). Sequence runs on the **same** datadir: **never** overlap two writers.
4. **Logging:** Tee each invocation into a local **`sync_batch_run.log`** with clear **batch markers** so truncated runs are easy to correlate—see [sync batch run log markers](#sync-batch-run-log-markers).

Illustrative one-liner (**adjust `--datadir` / `./data`; do not automate against repo `./data` unless that is intentional**):

```bash
MAX_OUTBOUND_PEERS=1 PARALLEL_BLOCK_DOWNLOADS=0 SKIP_GETADDR=1 \
  .venv/bin/pybitnode-sync \
  --datadir /path/to/your/datadir \
  --peers HOST:PORT \
  --no-header-refresh \
  --blocks-target 10000 \
  --blocks-max 200
```

Once the milestone is validated, **[continue toward the header tip in batches](#after-10k-validated-continue-toward-the-header-tip-batches)**—raise **`--blocks-target`** toward **`sync_state.best_height`** / **`max_header_height`** instead of inflating **`--blocks-max`** alone.

### Sync batch run log markers

The filename **`sync_batch_run.log`** is listed in **[`.gitignore`](../.gitignore)** so ad-hoc run logs stay out of commits. Batch markers emitted by **`sync_batch_loop.py`** (`scripts/sync_batch_loop.sh`) follow the **`scripts/sync_progress_report.py`** parser—for example **`=== batch 3 start_validated=8400 2026-05-26T02:41:52Z ===`** … **`=== batch 3 end_validated=8600 downloaded_delta=200 exit=0 (2026-05-26T02:53:41Z) validated_delta=200 ===`**. Operators may **`tee -a`** manual runs with the same shape so progress tooling can parse partial logs.

```bash
ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "=== batch 1 start_validated=8400 ${ts} ==="
MAX_OUTBOUND_PEERS=1 PARALLEL_BLOCK_DOWNLOADS=0 SKIP_GETADDR=1 \
  .venv/bin/pybitnode-sync \
  --datadir /path/to/datadir --peers HOST:PORT \
  --no-header-refresh --blocks-target 10000 --blocks-max 200 2>&1 | tee -a sync_batch_run.log
rc=${PIPESTATUS[0]}
ts_end="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "=== batch 1 end_validated=8600 downloaded_delta=200 exit=${rc} (${ts_end}) validated_delta=200 ===" | tee -a sync_batch_run.log
```

Use one batch index per attempt; keep UTC **`YYYY-MM-DDTHH:MM:SSZ`** timestamps so grepping **`sync_batch_run.log`** stays deterministic—**`sync_progress_report`** only understands the **`batch N`** `start_validated=` / **`downloaded_delta`** / **`validated_delta`** form above.

### After ~10k validated: continue toward the header tip (batches)

Once **`validated_height`** has passed an initial milestone (for example **10k**), **do not** assume a single long run to the tip. Keep the same operational shape: sequential **`pybitnode-sync`** invocations on one **`--datadir`**, **no** overlapping writers.

1. **Set the next `--blocks-target` from the header horizon:** Advance **`--blocks-target`** toward the height your SQLite headers already represent—typically **`sync_state.best_height`** (see `pybitnode-db` / tracker meta) **or** the highest stored header (**`max(header height)`**, i.e. **`ProjectTracker.max_header_height()`**, surfaced as **`header_height`** in health JSON). Use an intermediate value for staged milestones, or the full tip height for “catch up to headers.” If **`best_height` and the stored header tip disagree**, a fresh sync start runs **`repair_sync_state`**; if confusion persists, use [Stuck sync recovery](#stuck-sync-recovery).
2. **Same `--no-header-refresh` + lightweight handshake:** As long as stored headers cover the next target, keep **`--no-header-refresh`** (and env equivalents like **`MAX_OUTBOUND_PEERS=1`**, **`PARALLEL_BLOCK_DOWNLOADS=0`**, **`SKIP_GETADDR=1`** with manual **`--peers`**) so each batch uses the [**lightweight block-sync handshake**](#lightweight-block-sync-handshake-no-header-refresh)—minimal header chatter, block-focused **`getdata`** toward witness blocks.
3. **Batch sizing:** Retain **`--blocks-max 200`** per run unless you are deliberately tuning chunk size; repeat until **`validated_height`** reaches **`--blocks-target`** or progress stalls ([Stuck sync recovery](#stuck-sync-recovery)).
4. **Snapshot cadence:** Export JSON **between** batches when the DB is **quiescent**—same [**when to export**](#when-to-export-snapshots-timing) / [**between batch runs**](#between-batch-runs) rules as the first phase; optional milestone cadence (e.g. every N thousand validated) for reviewable **`snapshots/`** checkpoints.

**Architecture:** How **`sync_state.best_height`** tracks the header chain and how block download follows stored headers is outlined in [ARCHITECTURE.md — Header sync](ARCHITECTURE.md#header-sync) and [ARCHITECTURE.md — Block sync](ARCHITECTURE.md#block-sync).

---

## Stuck sync recovery

### Header sync failures

Header download runs on the first available peer in an **ordered** list: **`--peers` / `PEERS` endpoints first**, then others sorted by advertised height (`PeerManager._ordered_header_peers`). If `getheaders` fails (timeout, disconnect, I/O), the manager logs a warning and **tries the next connected peer** before giving up.

**Recovery steps:**

1. Confirm the [single-writer rule](#safe-parallel-work-vs-the-live-database); fix overlapping processes if any.
2. Check logs for `Header sync failed via HOST:PORT`; try **stable manual peers** via `--peers` or `PEERS` (same syntax as the batch sync table above).
3. Each sync start calls `repair_sync_state` so `sync_state` realigns with the highest row in the `headers` table—useful after a crash mid-headers.
4. Inspect state: `DATA_DIR=./data .venv/bin/pybitnode-db` or `pybitnode-db --db ./data/pybitnode.db` for `sync_status`, `best_height`, and errors.

**Manual peers and discovery:** When you pass manual peers, bootstrap uses **at most one outbound peer** for that run (`_effective_max_outbound = 1` when `manual_peers` is non-empty) and **does not run post-handshake `getaddr` discovery** (same path as `SKIP_GETADDR`). Manual endpoints are **still attempted even if their ban score is high** (they bypass the ban threshold filter used for stored/discovered candidates).

### “Skip at tip” is normal

If the local header tip is within **`HEADER_SYNC_NEAR_PEER_TIP` (2)** blocks of the peer’s advertised tip, `should_skip_header_download` treats header catch-up as done and sets `sync_status` to **`headers_current`** without further `getheaders` churn. That is **not** a failure—it means block download can proceed (or you are caught up on headers).

### `SYNC_SKIP_HEADERS`

When **`SYNC_SKIP_HEADERS=1`** (parsed in **`Settings`**), **`pybitnode-sync`** never performs networked header sync (`getheaders`): it calls **`mark_headers_current`** immediately and validates/downloads blocks against headers already stored in SQLite.

Otherwise, **`pybitnode/sync_runner.py`** skips `getheaders` when either **`should_skip_header_download`** succeeds for the first ordered bootstrap peer **or** the DB is **`repair_sync_state`**-aligned (local header tip matches `sync_state.best_height`) while the peer advertises a **longer** chain — continuing block validation with the stored tall header prefix instead of catch-up chatter that peers may drop mid-request.

Unset `SYNC_SKIP_HEADERS` (or clear the heuristic by letting headers diverge from `sync_state`) when you deliberately need networked header extensions again.

### Consensus stall playbook (invalid blocks)

Use this when sync is **not** failing on headers or P2P bootstrapping, but **block validation** refuses the next height and progress stops.

**Architecture:** Validation and UTXO advance live in **`connect_block`** ([`ARCHITECTURE.md` — `connect_block` (validation + UTXO advance)](ARCHITECTURE.md#connect_block-validation--utxo-advance); consensus package in [Layer roles](ARCHITECTURE.md#layer-roles)).

#### Reading `events` for `Rejected invalid block` / `unsupported scriptPubKey template`

On `ConnectBlockError`, block sync logs a tracker event before stopping the batch ([`pybitnode/sync/blocks.py`](../pybitnode/sync/blocks.py)): category **`sync`**, message **`Rejected invalid block`**, level **`warning`**. The payload is JSON in **`details_json`** with at least **`height`** and **`error`** (string form of the exception).

**CLI (last *N* rows, newest first):**

```bash
.venv/bin/pybitnode-db --db /path/to/pybitnode.db --events 50
```

**SQLite:**

```sql
SELECT id, category, level, message, details_json, created_at
FROM events
WHERE message = 'Rejected invalid block'
ORDER BY id DESC
LIMIT 20;
```

Decode **`details_json`** in your tooling; a common consensus stub message is **`unsupported scriptPubKey template`**, emitted when the script engine does not implement that output template ([`pybitnode/consensus/script/verify.py`](../pybitnode/consensus/script/verify.py)). Other **`error`** strings come from **`ConnectBlockError`** (script failures, missing UTXOs, consensus rules, etc.).

**Offline recap:** [`scripts/script_template_survey.py`](../scripts/script_template_survey.py) prints **`chain_state.validated_height`**, header tip vs stored blocks, event counts for **`unsupported scriptPubKey template`**, and (optionally) classifies output locking scripts in the next *N* **stored** blocks past the validated tip — read-only SQLite, no P2P.

#### Example: testnet4 block **6975** (Taproot key-path) and fix **`dd65c78`**

Testnet4 **block 6975** includes a consensus-relevant **P2TR key-path** spend (witness v1, single-key path only). The repository encodes that transaction as a fixture in **`tests/test_script.py`** (`test_real_testnet4_block6975_taproot_keypath_accepted`).

Checkouts **before** Taproot key-path verification stall at this height: the events table shows **`Rejected invalid block`** with an error consistent with **`unsupported scriptPubKey template`** or failing P2TR checks once templates are partially recognized—matching snapshots that recorded this height during development.

Commit **`dd65c78`** (*Verify Taproot (P2TR) key-path spends for testnet4 block sync.*) adds Schnorr verification, Taproot sighash handling, and the connect-path wiring so **key-path** P2TR spends like block **6975** validate. Upgrade to an equivalent or later revision before expecting sync to pass that height.

#### Example: testnet4 block **30695** (P2WSH `OP_SIZE` hashlock) and fix **`f3324dc`**

Testnet4 **block 30695** tx **`1ec1f5f5…`**, input **0**, spends **P2WSH** with a witness script using **`OP_IF` / `OP_ELSE` / `OP_ENDIF`**: the IF branch (selector **`OP_1`**) runs **`OP_SIZE`** → **`OP_SHA256`** → embedded P2PKH **`OP_EQUALVERIFY`** before **`OP_CHECKSIG`**. The legacy interpreter treated **`OP_SIZE` (0x82)** as unsupported, yielding **`script verification failed for input 0`**.

Commit **`f3324dc`** adds **`OP_SIZE`** stack semantics. Fixture: **`tests/test_script.py`** → **`test_real_testnet4_block30695_p2wsh_if_hashlock_op_size_accepted`**. Full handoff row: [`docs/BLOCKER_LEDGER.md`](BLOCKER_LEDGER.md).

#### Example: testnet4 block **31842** (P2WSH len-1 witness stack)

Testnet4 **block 31842** tx **`b6dc5519…`**, input **0**, spends **P2WSH** with witness script **`OP_1` only** (32-byte SHA256 commitment to a one-byte script). The witness stack is **`[witnessScript]`** — length **1**, no prior stack items. An incorrect **`len(witness) >= 2`** guard rejects this before script evaluation.

Fixture: **`tests/test_script.py`** → **`test_real_testnet4_block31842_p2wsh_op1_only_witness_accepted`**. Handoff: [`docs/BLOCKER_LEDGER.md`](BLOCKER_LEDGER.md).

#### Example: testnet4 block **32712** (P2TR tapscript `OP_NUMEQUAL`)

Testnet4 **block 32712** tx **`6b586a4f…`**, input **0**, **P2TR script-path** 2-of-3 tapscript ending **`OP_2 OP_NUMEQUAL`** after **`OP_CHECKSIGADD`**. Missing tapscript **`OP_NUMEQUAL (0x9c)`** support caused **`script verification failed for input 0`**.

Fixture: **`test_real_testnet4_block32712_p2tr_tapscript_checksigadd_2of3_numequal_accepted`**. Handoff: [`docs/BLOCKER_LEDGER.md`](BLOCKER_LEDGER.md).

#### Example: testnet4 block **38191** (P2SH CLTV on transaction version 1)

Testnet4 **block 38191** tx **`4e477ff4e1a12fd78e76fb7dec0d0fcd6fb0372f757fabceb83fdb041c6ee9b6`**, input **0**, spends **P2SH** (`a914bbe352f1c5366dd92bcae64f4de33e6b56df7e3d87`) with redeem script **`30000 OP_CHECKLOCKTIMEVERIFY OP_DROP <pubkey> OP_CHECKSIG`**. The spending transaction is **version 1** with `nLockTime=30000`; BIP65 `OP_CHECKLOCKTIMEVERIFY` is a no-op when `nVersion < 2`, so the interpreter must continue to `OP_DROP` and `OP_CHECKSIG` instead of failing at CLTV.

Fixture: **`tests/fixtures/tx_p2sh_cltv_38191*.{hex,json}`** and **`test_real_testnet4_block38191_p2sh_cltv_version1_noop_accepted`**. Handoff: [`docs/BLOCKER_LEDGER.md`](BLOCKER_LEDGER.md).

#### Example: testnet4 block **41700** (reserved native SegWit v1 program)

Testnet4 **block 41700** tx **`4a89d5d1568b5cbcb4118559cb65d2357657d361a41cd96b14e74ed3d065975c`**, input **0**, spends prevout **`cedcdf44fba328c4da7077cac914b490a1af40acecf74ca666af6b0313c8e613:1`** with scriptPubKey **`51024e73`** (`OP_1` plus a 2-byte witness program). This is a native SegWit v1 program but **not** BIP341 P2TR, which is specifically `OP_1` plus a 32-byte program. Treat it as a reserved witness program: require an empty native `scriptSig`, do not execute legacy script or tapscript, and do not classify it as unsupported.

Fixture: **`test_real_testnet4_block41700_unknown_witness_v1_program_accepted`** plus **`test_unknown_witness_v1_program_rejects_non_empty_script_sig`**. Handoff: [`docs/BLOCKER_LEDGER.md`](BLOCKER_LEDGER.md).

#### Example: testnet4 block **44295** (P2TR tapscript `OP_NIP`)

Testnet4 **block 44295** tx **`cb835ce1d726993515c27df94a358bf327b03323fb0e82c823c1faab31b28786`**, input **0**, spends an in-block P2TR output **`5120346d44aef23b267970d8c090d8fed28e2dcf772b609f566cdc56e108ff84118a`** via script path. The tapscript leaf ends with **`OP_NIP` (`0x77`)**, which removes the second item from the top of the stack while leaving the top item in place. The opcode must fail on stack size less than two; do not treat it as an unconditional success or skip.

Fixture: **`test_real_testnet4_block44295_p2tr_tapscript_op_nip_accepted`**, plus synthetic `op_nip` success and underflow tests. Handoff: [`docs/BLOCKER_LEDGER.md`](BLOCKER_LEDGER.md).

#### Example: testnet4 block **46599** (script truthiness with `0x80` prefix)

Testnet4 **block 46599** tx **`d16704313ed3cd64f082c92b40d72ccf5ede213f739c3f217caf59f1ca6c962f`**, input **0**, spends an in-block P2TR output **`5120a23f913d1fc28f07abbcc72218ed00e0d149287b9e86187e54b0c6340ce584b3`** via script path. The leaf executes successfully and leaves final stack item **`809e000000000000`**. This is truthy: Bitcoin script treats **only** a final byte `0x80` in an otherwise-zero vector as false negative zero. A `0x80` byte at the front of a longer nonzero vector must not make the item false.

Fixture: **`test_real_testnet4_block46599_p2tr_tapscript_truthy_0x80_prefix_accepted`**, plus **`test_script_bool_cast_only_treats_final_0x80_as_negative_zero`**. Handoff: [`docs/BLOCKER_LEDGER.md`](BLOCKER_LEDGER.md).

#### Example: testnet4 block **46779** (P2WSH `OP_CODESEPARATOR`)

Testnet4 **block 46779** tx **`fb9b18c782c2b45ccb77b4e22cbdf8b8cb1b8bf603289937968da52475e28aa5`**, input **0**, spends P2WSH output **`0020359eaf2fdfc8952db69827596cf6fe9093f203bdbbd83749a9953f58a3a93829`**. The witness script is **`OP_SIZE 80 OP_LESSTHAN OP_CODESEPARATOR <pubkey> OP_CHECKSIG`**. The interpreter must execute the size check, then treat **`OP_CODESEPARATOR`** as updating the ECDSA signature subscript for the later **`OP_CHECKSIG`**; rejecting opcode **`0xab`** or hashing the full witness script stalls validation here.

Fixture: **`test_real_testnet4_block46779_p2wsh_codeseparator_accepted`**. Handoff: [`docs/BLOCKER_LEDGER.md`](BLOCKER_LEDGER.md).

#### Example: testnet4 block **51340** (P2SH `OP_ADD`)

Testnet4 **block 51340** tx **`03911305033a5aa73d7d730f16ba63b53582c6a6570d8d9f86e2f2b76fa2cbc3`**, input **0**, spends P2SH output **`a914c464d0169c41085bcf10e3ab2cf83e74859d640b87`**. The scriptSig is **`515203935387`**, pushing **`1`**, **`2`**, and redeem script **`935387`** (`OP_ADD OP_3 OP_EQUAL`). The interpreter must run legacy **`OP_ADD`** as ScriptNum arithmetic: pop `2` then `1`, push encoded `3`, and leave `OP_EQUAL` true.

Fixture: **`tests/fixtures/tx_p2sh_add_51340*.{hex,json}`**, **`test_real_testnet4_block51340_p2sh_op_add_accepted`**, and synthetic **`test_legacy_script_op_add_semantics_and_underflow`**. Handoff: [`docs/BLOCKER_LEDGER.md`](BLOCKER_LEDGER.md).

#### When sync “stalls”: `validated_height` unchanged and **`downloaded=0`**

At the end of a **`pybitnode-sync`** run, **`Block sync complete: downloaded=%s … validated=%s`** ([`sync_runner.py`](../pybitnode/sync_runner.py)) with **`downloaded=0`** means **no blocks were written** in that process invocation.

Typical causes:

1. **Validation rejected the next block** — first missing height failed **`connect_block`**; inspect **`Rejected invalid block`** events and logs. **`--connect-only` / `--rebuild`** do not add new script semantics; fix the consensus implementation or update the codebase, then rerun.
2. **No payload from peers** — look for **`Block unavailable from peers`** in `events` and follow [Peer bootstrap failures troubleshooting](#peer-bootstrap-failures-troubleshooting).

If **`validated_height`** is unchanged across repeated batches **and** `downloaded` stays **0**, treat it as either a **hard consensus gap** (error in `details_json`) or a **download / peer** issue—not a benign “near tip” header skip.

#### Taproot **script-path** gap (ops note)

P2TR **key-path** and **script-path** verification (BIP341/342 subset) landed in **`dd65c78`**, **`86bb78e`**, and **`7c28c69`**, including tapscript **CLTV/CSV** (BIP65/BIP112 semantics with Schnorr sighash). If sync fails **after** heights that only exercise those paths, inspect the failing **`height`** and **`error`** for other gaps (bare scripts, witness v>1).

#### Next consensus gaps (offline survey)

When sync stalls with **`downloaded=0`** past a milestone, run the read-only template survey (no P2P, SQLite **`mode=ro`**):

```bash
PYTHONPATH=. .venv/bin/python scripts/script_template_survey.py \
  --db /path/to/pybitnode.db --scan-blocks 500
```

Use **`--scan-blocks`** only when stored block rows exist **past** `validated_height` (download ahead). Typical remaining gaps after P2TR (incl. tapscript timelocks) + multisig + legacy CLTV/CSV: **bare/non-template** spends. **Witness v2+** programs are detected and rejected with `unsupported witness program version N` (not yet implemented). Fix the interpreter, add a synthetic fixture in **`tests/test_script.py`**, then rerun sync batches.

---

## Lightweight block-sync handshake (no header refresh)

Use this playbook when headers are **already loaded in SQLite** (imported, prior header sync, or catch-up where `max(header height)` covers your `--blocks-target`) and you only need **witness blocks** from peers. It minimizes P2P chatter and matches the posture some implementations expect for **historical `getdata`**, not full tx relay.

### Controls: `--no-header-refresh`, `NO_HEADER_REFRESH`, `SYNC_SKIP_HEADERS`

| Mechanism | Effect on `pybitnode-sync` |
| --------- | -------------------------- |
| **`--no-header-refresh`** CLI | Sets **`no_header_refresh`**; skips networked header refresh **for this process** (`Settings` in [`sync_runner.py`](../pybitnode/sync_runner.py)). Headers in the DB are trusted; **`mark_headers_current`** runs without `getheaders`. |
| **`NO_HEADER_REFRESH=1`** | Same semantic as **`--no-header-refresh`** via env ([`pybitnode/config.py`](../pybitnode/config.py)). |
| **`SYNC_SKIP_HEADERS=1`** | Harder bypass: networked header sync is **never** attempted while this env applies. Also triggers the **lightweight outbound handshake** (below), same as `no_header_refresh`. |

**Choosing flags:** Prefer **`--no-header-refresh` / `NO_HEADER_REFRESH`** for “I know my DB headers are good for this batch.” Reserve **`SYNC_SKIP_HEADERS`** for automation/tests that must **never** hit `getheaders` regardless of tip alignment.

### Log lines from header-refresh decisions

[`decide_header_refresh_action`](../pybitnode/sync/header_refresh.py) drives an **`logger.info`** line right before block download:

| When you see… | Meaning |
| ------------- | ------- |
| **`header_refresh_skipped_no_header_refresh_flag`** | `NO_HEADER_REFRESH` or **`--no-header-refresh`** is set. |
| **`header_refresh_skipped_local_headers_cover_target`** | **`--blocks-target` / `BLOCKS_TARGET_HEIGHT`** is set and **`max(header height)` in the DB ≥ that target**—no need to extend headers for this run. |
| **`SYNC_SKIP_HEADERS=1: skipping networked header sync`** | **`SYNC_SKIP_HEADERS`** env is set. |
| Other `skip_*` / `network_sync` values | Heuristic path (near peer tip, aligned DB, etc.); see enum in source. |

### Lightweight outbound handshake (block-sync connections)

When **`no_header_refresh` OR `sync_skip_headers`** (`_lightweight_outbound_handshake` in [`pybitnode/p2p/peer.py`](../pybitnode/p2p/peer.py)), an **outbound** peer skips after **`verack`**:

- **`sendheaders`** (BIP130)
- Outbound **`feefilter`** (BIP133) and **`mempool`** (BIP35) from **`_post_verack_negotiation`**

So the connection presents as **block sync–oriented**, not full mempool/relay negotiation.

**Why this mattered (fix commit `5f2db1c`):** Before that change, the full post-handshake relay path plus handling of inbound traffic during block fetch caused **peers to drop or stop serving** around **`getdata`** for older blocks. The fix introduced this lightweight path, advertised **`version.start_height`** from the **validated** tip when header refresh is skipped (so the client does not claim a chain tip far ahead of what it can serve), ignored inbound **`getheaders`** while waiting on **`block`/`notfound`**, and related bootstrap tightening. If you bisect odd disconnects on historical sync, ensure you are **on or after `5f2db1c`** with **`--no-header-refresh`** (or **`SYNC_SKIP_HEADERS`**) for the intended behavior.

### Recommended sync command (stable manual peer, block-only)

One outbound, sequential block download, no `getaddr` after connect, header refresh off—good default when you supply a **known-good `HOST:PORT`** and DB headers already cover your target range:

```bash
MAX_OUTBOUND_PEERS=1 PARALLEL_BLOCK_DOWNLOADS=0 SKIP_GETADDR=1 \
  .venv/bin/pybitnode-sync \
  --datadir /path/to/your/datadir \
  --peers HOST:PORT \
  --no-header-refresh \
  --blocks-target 100000 \
  --blocks-max 200
```

Adjust **`--blocks-target`**, **`--blocks-max`**, and **`--datadir`**; do **not** point automation at the repository **`./data`** tree unless that is your intentional working copy (see [Safe parallel work vs the live database](#safe-parallel-work-vs-the-live-database)).

**Cross-links:** [`PeerManager.bootstrap`](../pybitnode/p2p/manager.py) uses **only** manual targets when **`--peers` / `PEERS`** is set (no extra DNS/DB seed fan-out). Manual peer runs already cap effective outbounds and skip discovery in many cases; **`SKIP_GETADDR=1`** still applies when you rely on discovered peers and want to skip post-handshake **`getaddr`**.

### Single writer and the sync lock (recap)

Keep **[one mutating process per datadir](#safe-parallel-work-vs-the-live-database)**. The **`.pybitnode-sync.lock`** file only prevents overlapping **`pybitnode-sync`** invocations; coordinate separately with **`pybitnode`** and tooling.

---

## Environment variable matrix

Values are read in `Settings.from_env()` ([`pybitnode/config.py`](../pybitnode/config.py)). Boolean envs accept `1`, `true`, `yes`, `on` (case-insensitive).

| Variable | Default | Purpose |
| -------- | ------- | ------- |
| `PARALLEL_BLOCK_DOWNLOADS` | `0` | `>0`: request each missing block height from **all** connected peers in parallel; first successful `getdata` wins. Increases outbound traffic; can help on high-latency links. **`0`** keeps sequential peer rotation. Applies to **`pybitnode-sync` and live `pybitnode`** (no CLI flag). |
| `SKIP_GETADDR` | `false` | Skip outbound `getaddr`/addr exchange after connect. Useful when peers hang during address gossip; **not used** when manual `--peers`/`PEERS` are set (that path already skips discovery). |
| `SYNC_SKIP_HEADERS` | `false` | When **`true`**, **`pybitnode-sync`** skips networked header sync entirely; see [Lightweight block-sync handshake](#lightweight-block-sync-handshake-no-header-refresh) and the **`SYNC_SKIP_HEADERS`** subsection above. |
| `NO_HEADER_REFRESH` | `false` | Same as **`--no-header-refresh`**: skip networked header refresh; use DB headers for block download. Enables **lightweight outbound handshake** with **`SYNC_SKIP_HEADERS`**. |
| `SYNC_TIMING` | `false` | When **`true`**, `connect_block` persists per-block stage timing events (`category="timing"`, `message="connect_block"`) with `utxo_load`, `script_verify`, `utxo_apply`, `commit`, and `block_connect_store_commit` milliseconds. Disabled by default to keep normal sync overhead low. |
| `PAR_SCRIPT_VERIFY` | `true` | Phase A parallel script verification. Only inputs within one transaction are verified in parallel; transaction order, UTXO reads/writes, undo creation, and block connect remain sequential. Set to **`0`** for sequential compatibility checks. |
| `PAR_SCRIPT_EXECUTOR` | `thread` | Executor backend for Phase A script verification. **`thread`** preserves the default behavior; **`process`** is an opt-in benchmark experiment for pure-Python crypto-heavy blocks. Workers never touch SQLite or the UTXO view. |
| `PAR_SCRIPT_THREADS` | CPU count | Maximum worker threads for parallel input verification. Values below **`1`** are clamped to **`1`**. |
| `PAR_SCRIPT_MIN_INPUTS` | `2` | Minimum input count before the runner uses the parallel path. Values below **`1`** are clamped to **`1`**. |
| `ENABLE_ORPHAN_POOL` | `false` | When `true`, defer transactions with unknown prevouts into an `OrphanPool` for later retry; when `false`, those txs are rejected immediately. |
| `MIN_RELAY_FEERATE_SAT_VB` | `0` | Minimum relay feerate in **satoshis per virtual byte** for mempool admission and feefilter alignment. **`0`** disables the gate (scaffold default). |
| `PEER_BAN_SCORE_THRESHOLD` | `100` | Bootstrap candidate filter: endpoints in `peer_addresses` with aggregate ban score **above** this are skipped (manual peers exempt). |
| `PEER_BAN_DECAY_UPTIME_SECONDS` | `300` | After a peer has been connected this long, a one-time decay runs on disconnect (see below). |
| `PEER_BAN_DECAY_AMOUNT` | `15` | Subtracted from the endpoint ban score when decay applies. |
| `LISTEN` | `false` | Accept inbound P2P (same as `pybitnode --listen`). Pair with `P2P_PORT` / firewall; see [Inbound P2P](#inbound-p2p-listen1). |
| `METRICS_HTTP_PORT` | `0` | If **`> 0`**, **`pybitnode`** exposes Prometheus text at **`GET /metrics`**. **`0`** or unset disables it. Requires the live node process—not **`pybitnode.healthcheck`**. Field-level reference: [Wire checkpoints, capabilities, and GET /metrics](#wire-checkpoints-capabilities-and-get-metrics); compose notes: [Docker](#docker-docker-composeyml). |
| `METRICS_HTTP_BIND` | `127.0.0.1` | TCP bind address for **`/metrics`**. Use **`0.0.0.0`** in containers when scraped from elsewhere on the network. |

Ban **increments** for misbehavior are constants in [`pybitnode/p2p/ban_policy.py`](../pybitnode/p2p/ban_policy.py) (handshake failures, protocol violations, etc.); ops rarely need to change code—tune **threshold/decay** if legitimate peers are filtered too aggressively.

### Parallel block download benchmark (isolated datadir)

To compare wall-clock sync with `PARALLEL_BLOCK_DOWNLOADS=0` vs `8` **without writing `./data`**, use the helper (temp datadirs under the system temp directory, or `--work-root`):

```bash
.venv/bin/python scripts/benchmark_parallel_sync.py compare \
  --chain testnet4 --blocks-max 16 --blocks-target 500000 --log-level warning
```

- **Fair starting state:** Copy a template datadir you own to a path outside the repo, then pass `--seed-dir /path/to/template`. The script clones it into two separate run directories so header/tip state matches before timing each mode. **`chmod -R a-w` seeds are OK** — the benchmark re-applies owner-writable bits on each isolated clone so `pybitnode-sync` can open its datadir lock and write SQLite safely.
- **`--no-header-refresh`:** Pass this flag to benchmark **timed** runs without networked header refresh ([`sync_runner --no-header-refresh`](../pybitnode/sync_runner.py)). If you omit `--seed-dir`, the script first performs a tiny **seed materialization** pass in the temp worktree (same `--peers`/chain/target; `blocks_max=1` plus normal header sync). That subprocess still needs a peer that stays up through `getheaders`; if it fails, copy a prepared datadir elsewhere and pass `--seed-dir`.
- **Example (testnet4, small block batch, stable peer):**
  ```bash
  .venv/bin/python scripts/benchmark_parallel_sync.py compare \
    --chain testnet4 --blocks-max 16 --blocks-target 17 \
    --peers 89.167.10.150:48333 --no-header-refresh --log-level warning
  ```
  Use a `blocks_target` just above your intended validated tip so `blocks_max` caps how many blocks each timed run pulls.
- **Peers:** Omit `--peers` to use normal DNS/bootstrap discovery, or pass stable `host:port,host2:port` via `--peers`. Parallel mode races across **connected** peers only; with **only manual peers**, bootstrap uses a single outbound ([`PeerManager.bootstrap`](../pybitnode/p2p/manager.py)), so `PARALLEL_BLOCK_DOWNLOADS>0` mainly helps when several connections are up or you add more peer endpoints.
- **Offline / CI:** When no peers are reachable the compare subprocess exits non-zero; validate the parallel path with `pytest tests/test_block_sync.py` (`request_block_from_peers_parallel`, `sync_blocks_batch` with `parallel_downloads>0`).
- **Artifacts:** Use `--keep` to inspect SQLite + `blocks/` under the printed work directory.

The script refuses the repository `./data` directory as `--work-root` or `--seed-dir` so benchmarks stay isolated.

---

## Offline rebuild / validation repair

### Manual full UTXO + tip rebuild from `blocks/` (`--connect-only --rebuild`)

Clears validated state and reconnects stored blocks end-to-end (heavy; use when you intentionally want to replay the chain from disk):

```bash
.venv/bin/pybitnode-sync --datadir ./data --connect-only --rebuild
```

**Requires:** No concurrent node/sync on that datadir.

### Automatic `repair_validated_if_ahead`

On **every** sync start (`sync_blocks`, `connect_stored`), pybitnode calls `repair_validated_if_ahead`. If **`validated_height` is ahead of the highest stored block row** (`MAX(height) FROM blocks`), the tracker logs a warning and runs an internal **`rebuild_validated_chain`** to realign validation with what is actually on disk. This is automatic “repair”; you do not pass a CLI flag—only `--rebuild` forces a deliberate full replay.

Use `--connect-only` (without `--rebuild`) to **connect subsequent stored blocks without network**, after copying in new `blk*` files:

```bash
.venv/bin/pybitnode-sync --datadir ./data --connect-only
```

---

## Snapshot export workflow (`snapshots/`)

Use the export script after a milestone sync (or anytime you want JSON copies of tracker state):

```bash
.venv/bin/python scripts/export_snapshots.py --db ./data/pybitnode.db
```

Optional: `--chain testnet4` and `--out snapshots` (default output dir).

**Outputs:** `status.json`, `phases.json`, `wire.json`, `capabilities.json`, `manifest.json`.

### When to export snapshots (timing)

Treat snapshot export like a **read checkpoint on a quiet database**:

| Do | Do not |
| --- | --- |
| Export **`after`** the sync process (**`pybitnode-sync`**) **exits cleanly** between scheduled batches—or after stopping **`pybitnode`** if you coordinate maintenance. | Start `export_snapshots.py` **while validation is actively writing** the same SQLite file (heavy batch mid-flight). WAL readers can overlap in many cases; **checkpoint JSON for CI / manifests** assumes a **quiet** tracker. |
| Use **between-batch** checkpoints when iterating **`--blocks-max`** runs ([batch workflow](#recommended-iterative-batches-toward-10k-no-header-refresh)) on one datadir. | Treat “might be fine” mid-write reads as your default **publisher** timing for `snapshots/`. |

**Rule of thumb:** if you could safely start **another** `pybitnode-sync` without overlapping the previous PID, it is OK to export. If unsure, inspect **`ps`** / Activity Monitor deliberately (remember **`pgrep -f`** can false-positive shell wrappers)—or defer export until the next scripted batch completes; never export deliberately **during** overlapping writers.

See also **[Operational recap](#operational-recap-single-writer-lock-checkpoints)** ([single-writer rule](#safe-parallel-work-vs-the-live-database)).

### Between batch runs

When you are advancing the chain in repeated `pybitnode-sync` batches on the **same datadir**:

1. **Stop** the current sync (or node) so the DB is **not mid-write**; this avoids racing the exporter and matches the [single-writer rule](#safe-parallel-work-vs-the-live-database) and [When to export](#when-to-export-snapshots-timing) guidance.
2. Run `export_snapshots.py` **only after** writes have quiesced to refresh `snapshots/` (or a dedicated `--out` directory per milestone).
3. Review `git diff snapshots/` (or archive the output) so you have a **checkpoint** before the next batch.
4. Start the next batch only after you are comfortable with the captured state.

For ad-hoc exports while the node is running: SQLite read transactions often succeed, but **`export_snapshots.py` for repeatable `snapshots/` artifacts** assumes **minimal concurrent writes** ([When to export](#when-to-export-snapshots-timing)). Pause or defer export during the heaviest validation bursts if you need bite-for-bite reproducibility.

See also [`snapshots/README.md`](../snapshots/README.md).

---

## Wire checkpoints, capabilities, and GET /metrics

The canonical **wire capability registry** lives in [`pybitnode/wire/capabilities.py`](../pybitnode/wire/capabilities.py): each **`WireCapability`** is assigned to a **`WireCheckpoint`** (`cp0_framing` … `cp8_extensions`). Snapshot export ([`scripts/export_snapshots.py`](../scripts/export_snapshots.py)) mirrors that data into **`snapshots/capabilities.json`** and **`snapshots/wire.json`** for dashboards and CI—treat the Python module as source of truth when they disagree.

### Checkpoints operators often ask about

- **`cp5_tx_relay` (transaction relay):** Implemented items include witness **`inv` → `getdata` → `tx`**, post-handshake **`mempool`** (BIP35), announcing accepted txs via **`inv`**, and optional **`feefilter`** (BIP133). This is outbound participation in tx gossip, not inbound serving.
- **`cp6_serving` (inbound serving):** Responding to peer **`getheaders`**, **`getdata`** (blocks and txs), and pushing **block `inv`** when the tip moves is still **`implemented=False`** for the required capabilities in the registry—the node does not yet behave as a full serving peer for those requests.
- **BIP152 (compact blocks):** **`handshake.sendcmpct`** (negotiation on the wire) is **`implemented=False`**. Under **`cp8_extensions`**, **`ext.cmpctblock`** (receive/parse compact blocks) is **`implemented=True`**, while **`ext.getblocktxn`** (request missing txs for a compact block) is **`implemented=False`**—compact-block support is receive-side only in the registry’s sense.
- **Taproot (P2TR):** Not a wire checkpoint. **Key-path** witness v1 verification is consensus-side (see [Example: testnet4 block 6975 (Taproot key-path)](#example-testnet4-block-6975-taproot-key-path-and-fix-dd65c78) and [Taproot script-path gap (ops note)](#taproot-script-path-gap-ops-note)); **`NODE_WITNESS`** in the P2P handshake reflects witness-block relay, not interpreter completeness.

### GET /metrics (Prometheus text)

When **`METRICS_HTTP_PORT` > 0** on the **long-running** **`pybitnode`** process, the embedded HTTP server answers **only** **`GET /metrics`**; other paths return **404**, non-GET returns **405**. The body is Prometheus text exposition with **`Content-Type: text/plain; charset=utf-8; version=0.0.4`**.

| Series | Type | Labels | Meaning |
| ------ | ---- | ------ | ------- |
| **`blocks_validated_total`** | counter | **`chain`** | Blocks validated and connected (same value as SQLite meta **`metric_blocks_validated_total`**, exposed under **`metrics.blocks_validated_total`** in health JSON). |
| **`txs_relayed_total`** | counter | **`chain`** | Transactions relayed toward peers (**`metric_txs_relayed_total`** / **`metrics.txs_relayed_total`**). |

Implementation: [`pybitnode/metrics.py`](../pybitnode/metrics.py) (`prometheus_exposition_format`) and [`pybitnode/metrics_http.py`](../pybitnode/metrics_http.py). **Healthcheck JSON** (`python -m pybitnode.healthcheck`) is separate from this listener—see [Docker](#docker-docker-composeyml) for the full **`docker_health_document`** field list.

---

## Inbound P2P: `LISTEN=1`

Enable accepting inbound peers (equivalent CLI `--listen` on `pybitnode`):

```bash
LISTEN=1 .venv/bin/pybitnode --datadir ./data
```

`Settings.from_env()` sets `listen` from **`LISTEN`** (`1`, `true`, `yes`, `on`). Ensure firewall / `P2P_PORT` alignment with [`pybitnode/p2p/server.py`](../pybitnode/p2p/server.py) listener logs.

---

## Docker (`docker/docker-compose.yml`)

Compose sets **`LISTEN=1`**, maps host **`48333`** → container testnet4 P2P, and runs a **healthcheck** via `python -m pybitnode.healthcheck`: one line of JSON on stdout plus process **exit code** (`1` when tracker `sync_status` is **`error`**, matching the JSON `ok`/`healthy` flags). See inline comments in the compose file.

Health payload fields include **`header_height`**, **`mempool_size`** (tx count; same as **`mempool_tx_count`**), **`sync_progress_pct`** (validated height vs **`sync_state.best_height`**, capped at 100%), **`last_error`** (SQLite meta **`last_error`; JSON **`null`** if empty), and **`metrics`**: **`blocks_validated_total`**, **`txs_relayed_total`** persisted as **`metric_blocks_validated_total`** / **`metric_txs_relayed_total`** in `meta`. **`validated_height`** and **`summary`** behave as before.

**Prometheus scrape (live `pybitnode` only):** set **`METRICS_HTTP_PORT`** > `0` and scrape **`GET /metrics`** as in [Wire checkpoints, capabilities, and GET /metrics](#wire-checkpoints-capabilities-and-get-metrics); **`METRICS_HTTP_BIND`** defaults **`127.0.0.1`** (use **`0.0.0.0`** in Docker when the scraper is another container). Health probes still rely on **`DB_PATH`** / **`CHAIN`** for **`python -m pybitnode.healthcheck`** alone—metrics HTTP is separate.

---

## Expected timings & performance

Throughput is dominated by peer bandwidth, SQLite fsync patterns, PoW/script validation, and batch sizes. Rough expectations:

| Scope | Typical observation |
|------|----------------------|
| `--blocks-max 200` batch | Seconds to minutes on fast SSD + good peers; can stretch on slow CPUs or flaky P2P. |
| Headers | Usually faster than full block validation across the same height range. |
| `--connect-only --rebuild` full replay | Proportional to chain length stored on disk; plan for **long** runs on tens of thousands of blocks. |

**Health signal:** Successful batches raise `validated_height` in `chain_state`; tail logs include `validated=` / “Block sync complete”.

### Connect-stage timing

For a bounded performance run on a quiescent datadir, enable timing explicitly:

```bash
SYNC_TIMING=1 .venv/bin/pybitnode-sync --datadir ./data --connect-only
```

Timing rows are stored in SQLite `events` as `category="timing"`, `message="connect_block"`. The `details_json.stages_ms` object reports UTXO load time, script verification time, UTXO apply time, SQLite commit time, and total `connect_block` wall time. With `PAR_SCRIPT_VERIFY=1`, `script_verify` is the sum of per-input worker elapsed time and can exceed wall clock; compare `block_connect_store_commit` for throughput. If validation stops on a consensus blocker, treat the timing row as a measurement of that attempted block only; do not bypass the missing rule to collect performance data.

Parallel script verification is intentionally narrow: prevouts are loaded sequentially, script checks run, then spends are applied sequentially only after all inputs pass. This preserves block and transaction ordering while reducing wall-clock time for heavy multi-input transactions.

---

## Peer bootstrap failures troubleshooting

Symptoms:

- Logs like **Could not connect to any peers**.
- Headers/blocks stalled; `validated_height` unchanged batch-to-batch.

**Checks:**

1. **Single writer:** Confirm no overlapping `pybitnode-sync`/node on same DB.
2. **Reachability:** `HOST:PORT` open; correct network (e.g., testnet4 default port differs from mainnet).
3. **Explicit peers:** Pass `--peers a.b.c.d:48333,...` mirroring seeds you trust.
4. **DNS / firewall:** UDP/TCP egress allowed; captive portals break P2P.
5. **`LOG_LEVEL=debug`** for connection traces on next attempt.
6. **Ban buildup:** If discovery keeps picking bad endpoints, inspect `peer_addresses` / logs; raise `PEER_BAN_SCORE_THRESHOLD` temporarily or supply manual peers (exempt from the threshold). See [Stuck sync recovery](#stuck-sync-recovery).

Recover by fixing connectivity and rerunning **`pybitnode-sync`** with **`--blocks-max`** capped (e.g. 200); avoid `--rebuild` unless rebuilding from disk intentionally.
