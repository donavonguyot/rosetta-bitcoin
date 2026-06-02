package com.jbitnode.cli;

import com.jbitnode.db.ChainstateMetadata;
import com.jbitnode.db.ChainstateStats;
import com.jbitnode.db.ChainstateStore;
import com.jbitnode.db.ChainstateTip;
import java.io.PrintStream;
import java.sql.SQLException;

/** Chunk-boundary view of the active chainstate backend. */
public record ChainstateStatus(
    String backend,
    int validatedHeight,
    String validatedHash,
    String status,
    String generationId,
    long backendUtxoCount) {

  static ChainstateStatus capture(ChainstateStore store, String chain)
      throws SQLException {
    ChainstateTip tip = store.tip();
    ChainstateMetadata metadata = store.metadata();
    ChainstateStats stats = store.stats();
    return new ChainstateStatus(
        store.backend(),
        tip.height(),
        tip.hash(),
        metadata.status(),
        metadata.generationId(),
        stats.utxoCount());
  }

  void print(PrintStream out) {
    StringBuilder line =
        new StringBuilder("chainstate_check backend=")
            .append(backend)
            .append(" validated_height=")
            .append(validatedHeight)
            .append(" validated_hash=")
            .append(validatedHash)
            .append(" chainstate_status=")
            .append(status)
            .append(" generation_id=")
            .append(generationId)
            .append(" backend_utxo_count=")
            .append(backendUtxoCount);
    out.println(line);
  }
}
