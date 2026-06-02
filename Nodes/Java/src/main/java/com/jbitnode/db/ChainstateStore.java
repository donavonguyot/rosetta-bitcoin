package com.jbitnode.db;

import java.io.IOException;
import java.sql.SQLException;
import java.util.List;

/** Authoritative operational chainstate surface above the hot UTXO store. */
public interface ChainstateStore extends AutoCloseable {
  ChainstateMetadata metadata() throws SQLException;

  ChainstateTip tip() throws SQLException;

  ChainstateStats stats() throws SQLException;

  UtxoStore utxoStore();

  String backend();

  ChainstateCommitResult commitBlock(
      ChainstateBlockCommit commit, ProjectTracker.UndoTimingSink timingSink)
      throws SQLException;

  List<ProjectTracker.UtxoUndoEntry> readUndo(String chain, int height) throws SQLException;

  @Override
  void close() throws IOException;
}
