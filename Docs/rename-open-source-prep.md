# Rename/Open-Source Prep

> **Archive Record.** This document describes a completed process and is preserved
> for provenance and decision history only. It is not active guidance. Query
> Project for current status.

This document records the Stage 5 preparation boundary for publishing this
workspace as RosettaBitcoin. The workspace directory has been renamed to
the workspace root; this document does not create Git remotes
or publish a repository.

## Public Identity

The public project name and active local workspace name are `RosettaBitcoin`.
Public documentation should use RosettaBitcoin for the project. `RB` may remain
only as an intentional short nickname or internal package identifier.

## Selected Policy

- License: MIT License, copyright `2026 Donavon Guyot`.
- Security disclosure: GitHub private vulnerability reporting after the public
  repository exists.
- Public archive posture: readers should start with
  `Docs/public-archive-provenance.md`; detailed harvest docs remain local
  evidence-boundary records.

## Remaining Pre-Publication Blockers

Before publication, decide and record:

- repository host, owner, and public repository name;
- final Project status refresh and current evidence selection;
- final artifact/ignore review for datadirs, DBs, logs, generated output,
  dependency trees, old archive bulk, and nested Git histories.

Enable GitHub private vulnerability reporting when the public repository exists.

## Public Claim Rules

Public claims must be backed by current RosettaBitcoin evidence:

- Project reports from `Project/project.db`;
- Shared contracts, fixtures, and rule ledgers;
- current evidence selected in `Nodes/Shared/conformance/current_evidence.json`;
- compact proof JSON under `Nodes/Shared/conformance/results/`.

Do not use the retired the retired archive workspace archive, IL,
old proof ladders, old generated reports, comparison witnesses, or narrative
assets as support for current claims. They may be cited only as provenance or
archive context.

## Known Limitations Posture

Bounded gates such as `baseline_5k`, `shakedown_50k`, and
`performance_100k` are evidence, not the binary end state. The binary gate
remains:

```text
From empty local state on Bitcoin testnet4, the node reaches and maintains tip
while independently validating every stored connected block.
```

Report `tip_once` and `tip_maintenance` from Project. Do not hand-maintain a
README table that implies those gates are complete.

## Public Archive Boundary

The old the retired archive workspace workspace remains external
archaeology. Do not copy these into the public repository:

- portal, book, or audio bulk assets;
- old source trees, proof runners, or generated ports;
- live DBs, datadirs, block files, logs, or chainstate;
- dependency trees and generated build output;
- old roadmap/control-room state;
- nested `.git` histories.

If a historical fact matters, rewrite it into a RosettaBitcoin-native doc, Shared
contract, fixture, or compact proof artifact before using it.

## Rename Status

The active workspace now lives at `~/RosettaBitcoin`. The retired workspace
remains external at `~/ArchiveRosettaBitcoin`.

Historical proof JSON and Project DB rows may keep old absolute paths as run
metadata until fresh post-rename evidence replaces them. Future artifact writers
should use repo-relative paths or omit ephemeral log paths.

## Release Checklist

Before publication:

1. Confirm repository host/name and enable GitHub private vulnerability
   reporting.
2. Refresh Project imports and capture current `port-status`,
   `benchmark-suite`, `current-evidence`, and `consensus-runway` reports.
3. Run artifact scans and confirm ignored runtime state is not staged.
4. Review README language for conservative evidence-backed claims.
5. Decide whether detailed archive-harvest docs remain public docs or are
   summarized into release notes.
