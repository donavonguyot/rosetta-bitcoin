# Status Contract

Status is a consensus-adjacent API. It must report the active operational truth,
not stale project metadata.

## Required Fields

Every node status export must include:

```text
node_id
implementation
runtime_surface
chain
network
sync_status
runtime_status
binary_gate_status

header_height
header_hash
stored_block_height
stored_block_hash

validated_height
validated_hash
chainstate_backend
chainstate_backend_path
chainstate_generation_id
chainstate_status
chainstate_utxo_count

native_crypto_backend
native_crypto_available
taproot_tweak_backend

block_gap_count
current_blocker
last_error
active_writer_pid
lock_status
updated_at
```

## Status Values

`sync_status` should use stable values:

```text
starting
headers_syncing
headers_current
blocks_syncing
blocks_current
blocks_idle
blocks_blocked
live_idle
error
```

`binary_gate_status` uses:

```text
not_attempted
failed
passed
```

`chainstate_status` uses:

```text
missing
initializing
rebuilding
usable
corrupted
readonly
misaligned
```

`runtime_surface` should identify where the status came from:

```text
host
docker
supervisor
readonly_export
unknown
```

`runtime_status` reports whether the status command observed a live process:

```text
running
paused
stopped
not_running
unknown
```

## Active Backend Rule

`validated_height`, `validated_hash`, and `chainstate_utxo_count` must come from
the active chainstate backend. If the node mirrors those fields into another
store, the mirror must not be reported as canonical unless it matches the active
backend.

If the active backend is RocksDB, LevelDB, MDBX, or another key/value store,
SQLite UTXO counts are irrelevant except as a diagnostic comparison.

## Blocker Rule

`current_blocker` is present only when it still blocks the active chainstate.
Once validation advances beyond a blocker height, status must suppress or mark
the blocker as superseded.

Required blocker fields:

```text
height
block_hash
txid
input_index
spent_script_pubkey
failure
missing_rule
source
created_at
```

Operational failures such as peer unavailability, transient `notfound`, or stale
locks are not consensus blockers. They should appear in `last_error` or project
run history instead.

## Project DB Export

Ports may export status snapshots into `Project/project.db`, but the project DB
is observational only. A node must be able to validate and report status without
opening the project DB.

Status importers must prefer port-emitted JSON over direct DB reads. Direct
chainstate reads are allowed only for explicitly documented read-only diagnostic
tools.

## All-Port Workflow

The root all-port workflow is:

1. Run each port's own status command or status exporter.
2. Normalize missing optional fields to empty strings, `-1`, or `unknown`.
3. Import the JSON with `Project/scripts/import_status_snapshot.py`.
4. Rebuild or refresh Project imports.
5. Query Project projections instead of editing status Markdown:

```bash
python3 Project/scripts/import_all.py --db Project/project.db --rebuild
python3 Project/scripts/report.py --db Project/project.db --section port-status
sqlite-utils query Project/project.db \
  "select * from latest_port_status order by port"
```
