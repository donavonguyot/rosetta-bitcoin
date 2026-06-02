package com.jbitnode.db;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.chain.Genesis;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import java.nio.file.Path;
import java.util.List;

class ProjectTrackerNativeTest {
  private static final String BLOCK_1_HASH =
      "0000000012982b6d5f621229286b880e909984df669c2afabb102ce311b13f28";

  @Test
  void storesHeadersBlocksSyncStateAndEventsInOperationalRocksDb(@TempDir Path tempDir)
      throws Exception {
    Path operationalPath = tempDir.resolve("operational-rocksdb");
    try (RocksDbOperationalStore store = new RocksDbOperationalStore(operationalPath, true)) {
      ProjectTracker tracker = new ProjectTracker(store);
      tracker.ensureGenesis("testnet4", Genesis.TESTNET4, "genesis-hash");
      tracker.recordHeader("testnet4", 1, "block-1", "genesis-hash", "header-1");
      store.recordBlock(new OperationalStore.BlockIndexRecord("testnet4", 1, "block-1", 0, 0, 10));
      tracker.upsertSyncState(
          "testnet4", new ProjectTracker.SyncStatePatch(1, "block-1", 2, "blocks_idle"));
      tracker.logEvent("test", "event", "info", "{}");

      assertEquals(2, tracker.headerCount());
      assertEquals("block-1", tracker.getHeaderHash("testnet4", 1));
      assertEquals("header-1", tracker.getHeaderSerializedHex("testnet4", 1));
      assertEquals(1, tracker.maxStoredBlockHeight("testnet4"));
      assertTrue(tracker.listMissingBlockHeights("testnet4", 10).isEmpty());
      assertEquals("blocks_idle", tracker.getSyncState("testnet4").orElseThrow().syncStatus());
      assertNull(tracker.getValidatedHash("unknown"));
    }
    try (RocksDbOperationalStore reopened = new RocksDbOperationalStore(operationalPath, false)) {
      ProjectTracker tracker = new ProjectTracker(reopened);
      assertEquals("block-1", tracker.getHeaderHash("testnet4", 1));
      assertEquals(1, tracker.maxStoredBlockHeight("testnet4"));
      assertEquals("blocks_idle", tracker.getSyncState("testnet4").orElseThrow().syncStatus());
    }
  }

  @Test
  void nativeChainstateCommitUpdatesOperationalTip(@TempDir Path tempDir) throws Exception {
    try (RocksDbOperationalStore operational =
            new RocksDbOperationalStore(tempDir.resolve("operational-rocksdb"), true);
        ChainstateStore chainstate =
            ChainstateStoreFactory.open(
                new ProjectTracker(operational),
                tempDir,
                "testnet4",
                java.util.Map.of("UTXO_BACKEND", "rocksdb"),
                ChainstateOpenMode.READ_WRITE)) {
      ProjectTracker tracker = new ProjectTracker(operational);
      ChainstateBlockCommit commit =
          new ChainstateBlockCommit("testnet4", 1, BLOCK_1_HASH, List.of(), List.of(), List.of());

      chainstate.commitBlock(commit, ProjectTracker.UndoTimingSink.none());

      assertEquals(1, tracker.getValidatedHeight("testnet4"));
      assertEquals(BLOCK_1_HASH, tracker.getValidatedHash("testnet4"));
      assertEquals(1, chainstate.tip().height());
    }
  }
}
