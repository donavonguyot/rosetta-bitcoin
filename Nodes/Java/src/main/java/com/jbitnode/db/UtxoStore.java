package com.jbitnode.db;

import com.jbitnode.db.ProjectTracker.StoredUtxo;
import com.jbitnode.db.ProjectTracker.UtxoOutpoint;
import java.sql.SQLException;
import java.util.List;

/** Hot UTXO set operations used by block connection. */
public interface UtxoStore {
  StoredUtxo get(String chain, String txidHex, int vout) throws SQLException;

  /**
   * Batch-loads outpoints in one call. Returns one entry per requested outpoint, in order, with
   * {@code null} for outpoints not in the set. The default loops {@link #get}; RocksDB overrides it
   * with a single {@code multiGet}.
   */
  default List<StoredUtxo> getMany(String chain, List<UtxoOutpoint> outpoints) throws SQLException {
    List<StoredUtxo> result = new java.util.ArrayList<>(outpoints.size());
    for (UtxoOutpoint outpoint : outpoints) {
      result.add(get(chain, outpoint.txidHex(), outpoint.vout()));
    }
    return result;
  }

  void spendBatch(String chain, List<UtxoOutpoint> outpoints) throws SQLException;

  void addBatch(String chain, List<StoredUtxo> utxos) throws SQLException;

  long count(String chain) throws SQLException;
}
