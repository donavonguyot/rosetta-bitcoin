# Zigibit consumers in RB

RB remains the canonical source until the repository move is explicitly approved.
The external-checkout path is ready for rehearsals without creating a repository.
Keep the deferred mempool branches and the drives POC isolated; this cutover does
not merge or validate their behavior.

## Select immutable inputs

From a clean RB revision, export to a new directory outside RB:

```sh
python3 Project/scripts/export_zig_standalone.py /tmp/zigibit-cutover
export RB_ZIG_SOURCE=/tmp/zigibit-cutover
python3 Project/scripts/zig_checkout.py verify
python3 Project/scripts/run_zig_external_lab.py
```

Use Python 3.11 or newer for Project tools. `RB_ZIG_MANIFEST` optionally selects
an inventory other than `standalone-manifest.json`. After a future standalone
move, generate `.zig-cache/ci-source-manifest.json` with the node's
`scripts/snapshot_ci_source.py` and point `RB_ZIG_MANIFEST` at it. The adapter's
explicit `--source` and `--manifest` arguments override environment selections.
A missing, dirty, changed, escaping, or incomplete input is an error; an external
selection never silently uses `Nodes/Zig` instead.

## Consumer boundaries

| Consumer | External-checkout behavior |
| --- | --- |
| `run_zig_external_lab.py` | Full offline acceptance, fresh bounded 5k, storage smoke and separate-process restart; fresh unique state per run. |
| `provenance.prepare_port("zig")` | Builds from external source, checks build-info and binary hash, retains fixture package and immutable image receipt, returns pinned image/fixture paths. |
| `make -C Nodes/Zig docker-*` | With `RB_ZIG_SOURCE`, the RB Compose wrapper uses the verified external image and fixture package. RB still owns topology, commands and evidence destinations. |
| Ranked Project campaigns | Use the same selector through warm/build and provenance preparation. Existing campaign/preflight and volume policies still apply; this is not a fresh benchmark result. |
| Capture/activity tools | RB-owned byte collection. Capture diagnostics go to `RB_STATE_ROOT/project-campaigns/mempool-capture/blockers.jsonl`, never the node source ledger. Curate durable blockers explicitly. |
| Host lab make targets | Reject external selection; run build/tests in the selected standalone tree. |
| `run_zig_50k.py`, `run_crypto_lane.py --port zig` | Historical RB crypto campaigns; reject external selection. Adapt explicitly before rerunning against standalone source. Existing evidence remains retained. |

RB's compatibility Make/Compose files remain in `Nodes/Zig` until the actual
move. They are optional lab glue in an export; standalone builds and Docker
acceptance never invoke them. On the move, retain this glue in RB and update
manifest command paths together. The node source and Dockerfile consumed by
external mode already come from the selected checkout.

For example, `make -C Nodes/Zig docker-build` prepares the selected external
runtime; `make -C Nodes/Zig docker-script-corpus` executes it. Existing Docker
proof targets retain their existing volume/reset semantics: use the external lab
adapter for an extraction rehearsal with automatically isolated fresh volumes.
Host state and retained build receipts live below `RB_STATE_ROOT` (default
`~/.rblab`). Compose uses the immutable image ID. Receipts bind the external
revision, inventory checksum, fixture package and actual node binary hash; the
existing Project `binary_sha256` field for image receipts identifies the image.

The external lab's results are reviewed and imported separately. They do not
replace ranked benchmarks, prove crash/power-loss recovery, or satisfy empty-state
tip/maintenance gates. Project remains the source for current imported status.

## Handoff and deferred work

The exact deferred branch heads and preservation receipt are documented in
[git topology](git-topology.md). Capture-order replay, stimulus funding/broadcast,
and derived fixtures remain deferred. The drives POC owns native-store durability,
replay, and cloud orchestration in its separate branch. Merge/rebase it against
this cutover before exporting its changes, then rerun acceptance for that revision.

Completed source-split and documentation plans and the older crypto campaign plan
are archived under `Docs/history/zigibit/`; they are not standalone onboarding.
The remaining move actions are repository creation, history-transfer choice,
remote/security/branch settings, final pinned export, and relocating RB-only
compatibility glue. No new repository is created by these tools.
