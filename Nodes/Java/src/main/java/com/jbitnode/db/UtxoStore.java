package com.jbitnode.db;

import com.jbitnode.db.ProjectTracker.StoredUtxo;
import com.jbitnode.db.ProjectTracker.UtxoOutpoint;
import java.sql.SQLException;
import java.util.List;

/** Hot UTXO set operations used by block connection. */
public interface UtxoStore {
  StoredUtxo get(String chain, String txidHex, int vout) throws SQLException;

  void spendBatch(String chain, List<UtxoOutpoint> outpoints) throws SQLException;

  void addBatch(String chain, List<StoredUtxo> utxos) throws SQLException;

  long count(String chain) throws SQLException;
}
