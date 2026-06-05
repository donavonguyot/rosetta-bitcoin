# Port Baseline 5k Template

Use these templates when adding or reshaping a port toward the strict 5k
baseline. Replace `{{port}}`, `{{Port}}`, `{{node_id}}`, and command paths with
the real port values.

The template encodes the baseline stance:

- RocksDB owns runtime truth.
- Native crypto is required in the proof path.
- `docker_proof_local` means Docker/local Reference P2P to height `5000`.
- WAL stays enabled.
- `prefetch_depth=4` and `script_runner_mode=parallel`.
- UTXO accounting is `core_spendable_v1` with count `4574`.
- Compact proof JSON lands under `Nodes/Shared/conformance/results/`.

## RocksDB Runtime Truth Wording

New port docs, tests, and proof artifacts should describe the storage rule as
positive RocksDB runtime truth:

- Preferred fixture ID: `storage.rocksdb_runtime_truth`.
- Preferred proof fields: `chainstate_backend=rocksdb`,
  `runtime_truth_backend=rocksdb`, and `rocksdb_runtime_truth=true`.
- Preferred prose: RocksDB owns runtime truth; Project DB is mission control.

Do not introduce storage-backend scare wording in new docs or test names.
Historical proof fields with older names are Project importer aliases, not
template vocabulary.

After adapting a port, validate the shape through Project:

```bash
python3 Project/scripts/import_all.py --db Project/project.db --rebuild
python3 Project/scripts/preflight_port_baseline.py --db Project/project.db --port {{port}} --strict
```
