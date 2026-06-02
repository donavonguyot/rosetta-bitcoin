package com.jbitnode.db;

import com.jbitnode.db.ProjectTracker.StoredUtxo;
import com.jbitnode.db.ProjectTracker.UtxoOutpoint;
import com.jbitnode.db.ProjectTracker.UtxoUndoEntry;
import java.util.List;

/** Durable mutation required to connect one validated block. */
public record ChainstateBlockCommit(
    String chain,
    int height,
    String blockHashHex,
    List<UtxoOutpoint> spentOutpoints,
    List<StoredUtxo> createdUtxos,
    List<UtxoUndoEntry> undoEntries) {}
