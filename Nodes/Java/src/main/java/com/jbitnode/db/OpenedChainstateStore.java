package com.jbitnode.db;

import java.io.IOException;
import java.sql.SQLException;
import java.util.List;

final class OpenedChainstateStore implements ChainstateStore {

  private final ProjectTracker tracker;
  private final String chain;
  private final UtxoStoreFactory.OpenedUtxoStore openedUtxoStore;
  private ChainstateMetadata metadata;

  OpenedChainstateStore(
      ProjectTracker tracker,
      String chain,
      UtxoStoreFactory.OpenedUtxoStore openedUtxoStore,
      ChainstateMetadata metadata) {
    this.tracker = tracker;
    this.chain = chain;
    this.openedUtxoStore = openedUtxoStore;
    this.metadata = metadata;
  }

  @Override
  public ChainstateMetadata metadata() {
    return metadata;
  }

  void refreshMetadata(ChainstateMetadata metadata) {
    this.metadata = metadata;
  }

  @Override
  public ChainstateTip tip() throws SQLException {
    if (openedUtxoStore.store() instanceof RocksDbChainstateStore rocksDb) {
      ChainstateTip nativeTip = rocksDb.readTip(chain);
      if (nativeTip != null) {
        return nativeTip;
      }
    }
    return new ChainstateTip(tracker.getValidatedHeight(chain), tracker.getValidatedHash(chain));
  }

  @Override
  public ChainstateStats stats() throws SQLException {
    if (metadata.utxoCount() >= 0) {
      return new ChainstateStats(metadata.utxoCount());
    }
    if (openedUtxoStore.store() instanceof RocksDbChainstateStore rocksDb) {
      Long maintained = rocksDb.readMaintainedUtxoCount();
      if (maintained != null) {
        return new ChainstateStats(maintained);
      }
    }
    return new ChainstateStats(openedUtxoStore.store().count(chain));
  }

  @Override
  public UtxoStore utxoStore() {
    return openedUtxoStore.store();
  }

  @Override
  public String backend() {
    return openedUtxoStore.backend();
  }

  @Override
  public ChainstateCommitResult commitBlock(
      ChainstateBlockCommit commit, ProjectTracker.UndoTimingSink timingSink)
      throws SQLException {
    if (openedUtxoStore.store() instanceof RocksDbChainstateStore rocksDb) {
      ChainstateCommitResult nativeResult = rocksDb.commitBlockNative(commit, metadata, timingSink);
      refreshMetadata(nativeResult.metadata());
      updateOperationalTip(commit, nativeResult.metadata());
      return nativeResult;
    }
    throw new SQLException("unsupported native chainstate backend: " + openedUtxoStore.backend());
  }

  @Override
  public List<ProjectTracker.UtxoUndoEntry> readUndo(String chain, int height) throws SQLException {
    if (openedUtxoStore.store() instanceof RocksDbChainstateStore rocksDb) {
      return rocksDb.readUndo(chain, height);
    }
    return List.of();
  }

  private void updateOperationalTip(ChainstateBlockCommit commit, ChainstateMetadata metadata)
      throws SQLException {
    tracker.setValidatedTip(commit.chain(), commit.height(), commit.blockHashHex());
    ChainstateStoreFactory.writeMetadata(tracker, metadata);
  }

  @Override
  public void close() throws IOException {
    openedUtxoStore.close();
  }
}
