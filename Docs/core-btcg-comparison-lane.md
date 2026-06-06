# Core/btcg Comparison Lane

This document records the Stage 4 comparison-lane boundary that follows the
retired RosettaBitcoin archive harvest and IL value audit. It turns the old
port-grid lesson into current RB policy: references and witnesses can calibrate
claims, but they do not replace RB-owned proof.

## Lane Roles

| Role | Meaning |
|------|---------|
| `RB port` | A port under `Nodes/<Port>/` that independently validates blocks and can earn Project benchmark and consensus gates with port-owned evidence. |
| `Reference Core` | The local Bitcoin Core testnet4 byte-serving repeatability substrate described in `Nodes/Reference/README.md`. It is a comparison surface, not a validity oracle. |
| `btcg` | External operational comparison candidate. RB names it as a future comparison target only; there is no current RB path, command, artifact, or Project import surface for it. |
| `witness/reference` | A non-port surface that may provide bytes, checkpoints, fixture context, or operational comparison data, but cannot prove RB validity. |
| `comparison artifact` | A compact future artifact labeled as witness/reference evidence. It must not be imported as current port proof unless Project later gains an intentional comparison category. |

## Allowed Support

Core and future btcg comparison work may support:

- block and header byte serving;
- hash and height checkpoints;
- fixture extraction and prevout context;
- operational posture comparison;
- public-claim calibration before open source release.

These uses can make RB claims sharper, but they do not create RB claims by
themselves.

## Forbidden Substitution

Core, btcg, and comparison artifacts must not:

- clear RB consensus blockers;
- substitute for a port-owned `port.script_corpus_result.v1` script corpus proof;
- prove RocksDB, native crypto, Docker, supervisor, or storage compliance for
  an RB port;
- satisfy `tip_once` or `tip_maintenance` for an RB port;
- count as current evidence in Project unless Project explicitly adds a
  comparison/witness category later.

An RB port earns current status only through RB-native evidence: Shared
fixtures/contracts, port-owned proof artifacts, current evidence selection, and
Project imports.

## Gate Comparison Frame

| RB gate | What comparison can say | What only an RB port can prove |
|---------|-------------------------|--------------------------------|
| `baseline_5k` | Reference Core can serve bytes and provide expected height/hash context. | The port's Docker proof, RocksDB/native crypto posture, `45/45` corpus result, `core_spendable_v1` UTXO count, and Project preflight. |
| `shakedown_50k` | Core/btcg can help calibrate operational expectations and fixed-height checkpoints. | Independent validation to `50000`, telemetry, timing buckets, slow-block summary, and fresh-state proof. |
| `performance_100k` | Core/btcg can provide a comparison backdrop for speed and operational maturity. | Comparable `100000` validation evidence with complete Project-importable telemetry. |
| `tip_once` | Core/btcg can describe the external operational target and finish checkpoint. | Empty-state-to-tip validation by the RB port with no skipped consensus rules. |
| `tip_maintenance` | Core/btcg can contextualize near-tip behavior and public expectations. | Sustained `blocks_current` behavior, restart/reconnect handling, and port-owned health telemetry. |

## Artifact Policy

Future comparison artifacts should be small, machine-readable or concise
Markdown, and explicitly labeled as `comparison` or `witness` material. They
should record the external surface, command or source if one exists, observed
height/hash, timestamp, and the claim they calibrate.

Do not store Core datadirs, btcg datadirs, block files, logs, generated reports,
or copied external source in RB. If a comparison fact becomes relevant to a
current claim, rewrite it into an RB-native doc, Shared fixture/contract, or
compact proof artifact with a clear evidence boundary.

## Stage 4 Decision

The comparison lane exists to prevent two opposite mistakes: treating RB as
credible without operational comparison, and treating operational comparison as
proof. Reference Core and future btcg evidence may make RB more honest in public,
but RB ports still stand or fall on their own independently validated evidence.
