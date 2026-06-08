# Agent Brief Template

Use this for a scoped documentation pass. The brief is temporary: it guides one
batch and then expires. Do not turn it into a permanent file inventory, status
tracker, or port queue.

```text
Task:
  Add high-signal documentation for <port> <surface>.

Surface:
  <P2P handshake / sync orchestration / block connect / script verification /
  chainstate status / proof entrypoint>

Files to inspect first:
  - <path>
  - <path>
  - <path>

Shared docs to use:
  - Nodes/Shared/CODE_DOCUMENTATION.md
  - <contract path>
  - <contract path>

Vocabulary to preserve:
  - <canonical phrase>
  - <canonical phrase>

Allowed edits:
  - Add or improve comments/docblocks.
  - Add or improve port architecture prose for the scoped surface.
  - Fix nearby documentation links if they are wrong.

Forbidden edits:
  - No executable logic changes.
  - No test expectation changes.
  - No manifest, proof artifact, Project DB, or generated output changes.
  - No current status claims.
  - No comment-density cleanup outside the scoped surface.

Acceptance:
  - The file is easier for an agent to skim.
  - A human language expert learns the relevant Bitcoin invariant.
  - Comments point to Shared docs instead of duplicating them.
  - Project/scripts/check_doc_drift.py passes after Markdown edits.
```

## Example Ephemeral Brief

```text
Task:
  Add high-signal documentation for Java P2P/sync.

Surface:
  P2P handshake and batch sync ordering.

Files to inspect first:
  - Nodes/Java/src/main/java/com/jbitnode/p2p/PeerConnection.java
  - Nodes/Java/src/main/java/com/jbitnode/cli/LiveNodeService.java
  - Nodes/Java/src/main/java/com/jbitnode/sync/BlockSync.java
  - Nodes/Java/src/main/java/com/jbitnode/storage/DatadirLock.java

Shared docs to use:
  - Nodes/Shared/CODE_DOCUMENTATION.md
  - Nodes/Shared/STATUS_CONTRACT.md
  - Nodes/Shared/consensus/VALIDATION_PIPELINE.md
  - Nodes/Shared/chainstate/CHAINSTATE_STORE.md

Vocabulary to preserve:
  - deferred advanced negotiation
  - honest start_height
  - block-local UTXO view
  - atomic chainstate commit
  - single-writer datadir lock
```

## Example Ephemeral Brief — TypeScript P2P/chainstate

```text
Task:
  Add high-signal documentation for TypeScript P2P/chainstate.

Surface:
  P2P handshake, batch sync ordering, chainstate session, and datadir lock.

Files to inspect first:
  - Nodes/TypeScript/src/p2p/peer.ts
  - Nodes/TypeScript/src/p2p/manager.ts
  - Nodes/TypeScript/src/cli/syncRunner.ts
  - Nodes/TypeScript/src/node.ts
  - Nodes/TypeScript/src/storage/syncLock.ts
  - Nodes/TypeScript/src/chainstate/chainstateSession.ts
  - Nodes/TypeScript/docs/ARCHITECTURE.md

Shared docs to use:
  - Nodes/Shared/CODE_DOCUMENTATION.md
  - Nodes/Shared/STATUS_CONTRACT.md
  - Nodes/Shared/consensus/VALIDATION_PIPELINE.md
  - Nodes/Shared/chainstate/CHAINSTATE_STORE.md

Vocabulary to preserve:
  - deferred advanced negotiation
  - honest start_height
  - block-local UTXO view
  - atomic chainstate commit
  - single-writer datadir lock
  - runtime truth
```
