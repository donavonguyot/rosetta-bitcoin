package com.jbitnode.db;

import com.jbitnode.sync.ChainInconsistentException;
import java.nio.file.Files;
import java.sql.SQLException;

/** Central startup checks for the active operational chainstate. */
public final class ChainstateInvariants {

  private ChainstateInvariants() {}

  public static void verify(
      ProjectTracker tracker,
      String chain,
      ChainstateStore store,
      ChainstateOpenMode mode,
      boolean requireBackendAligned)
      throws SQLException, ChainstateInvariantException, ChainInconsistentException {
    ChainstateMetadata metadata = store.metadata();
    if (!metadata.usable() && mode != ChainstateOpenMode.REBUILD) {
      throw new ChainstateInvariantException(
          "active chainstate backend "
              + metadata.backendName()
              + " is "
              + metadata.status()
              + " (expected usable)");
    }
    ChainstateTip activeTip = store.tip();
    if (activeTip.height() != metadata.tipHeight()) {
      throw new ChainstateInvariantException(
          "active chainstate native tip height "
              + activeTip.height()
              + " does not match metadata tip height "
              + metadata.tipHeight());
    }
    if (activeTip.hash() != null
        && metadata.tipHash() != null
        && !metadata.tipHash().isBlank()
        && !metadata.tipHash().equals(activeTip.hash())) {
      throw new ChainstateInvariantException(
          "active chainstate native tip hash does not match metadata tip hash");
    }
    if (activeTip.height() > 0 && !Files.exists(metadata.backendPath())) {
      throw new ChainstateInvariantException(
          "active chainstate backend path is missing: " + metadata.backendPath());
    }
    if ("rocksdb".equals(metadata.backendName()) && store.utxoStore() instanceof RocksDbChainstateStore rocksDb) {
      String codecVersion = rocksDb.getMetadata(ChainstateStoreFactory.CODEC_VERSION);
      if (!"2".equals(codecVersion)) {
        throw new ChainstateInvariantException(
            "active RocksDB chainstate codec_version is " + codecVersion + " (expected 2)");
      }
    }
    if (activeTip.height() > tracker.maxStoredBlockHeight(chain) && activeTip.height() > 0) {
      throw new ChainstateInvariantException(
          "active chainstate tip height "
              + activeTip.height()
              + " exceeds stored block height "
              + tracker.maxStoredBlockHeight(chain));
    }
  }
}
