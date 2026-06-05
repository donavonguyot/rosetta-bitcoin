package com.jbitnode.db;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.chain.Genesis;
import com.jbitnode.util.Hex;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import java.nio.file.Path;
import java.util.List;

class ProjectTrackerNativeTest {
  private static final String BLOCK_1_HASH =
      "0000000012982b6d5f621229286b880e909984df669c2afabb102ce311b13f28";
  private static final String BLOCK_2_HASH =
      "00000000c14fbd32c7a931f7ff93f0cbf2d0d89fd6ce33c01403c6f819e9aa64";
  private static final String BLOCK_3_HASH =
      "000000000814f8d80366be4c74b95af453fa6a74aeb80cc4eb902bbd8ab6f481";

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

  @Test
  void nativeChainstateMaintainsUtxoCountWithoutPrefixScan(@TempDir Path tempDir)
      throws Exception {
    try (RocksDbOperationalStore operational =
            new RocksDbOperationalStore(tempDir.resolve("operational-rocksdb"), true);
        ChainstateStore chainstate =
            ChainstateStoreFactory.open(
                new ProjectTracker(operational),
                tempDir,
                "testnet4",
                java.util.Map.of("UTXO_BACKEND", "rocksdb"),
                ChainstateOpenMode.READ_WRITE)) {
      byte[] txidA = bytes32("11");
      byte[] txidB = bytes32("22");
      byte[] txidC = bytes32("33");
      byte[] spendableScript = new byte[] {0x51};
      byte[] opReturn = new byte[] {(byte) 0x6a, 0x01, 0x01};

      chainstate.commitBlock(
          new ChainstateBlockCommit(
              "testnet4",
              1,
              BLOCK_1_HASH,
              List.of(),
              List.of(
                  new ProjectTracker.StoredUtxo(txidA, 0, 1, 50, spendableScript, true),
                  new ProjectTracker.StoredUtxo(txidA, 1, 1, 25, spendableScript, true)),
              List.of()),
          ProjectTracker.UndoTimingSink.none());
      assertEquals(2, chainstate.stats().utxoCount());

      chainstate.commitBlock(
          new ChainstateBlockCommit(
              "testnet4",
              2,
              BLOCK_2_HASH,
              List.of(new ProjectTracker.UtxoOutpoint(Hex.encode(txidA), 0)),
              List.of(new ProjectTracker.StoredUtxo(txidB, 0, 2, 40, spendableScript, false)),
              List.of(
                  new ProjectTracker.UtxoUndoEntry(txidA, 0, 1, 50, spendableScript, true))),
          ProjectTracker.UndoTimingSink.none());
      assertEquals(2, chainstate.stats().utxoCount());

      chainstate.commitBlock(
          new ChainstateBlockCommit(
              "testnet4",
              3,
              BLOCK_3_HASH,
              List.of(
                  new ProjectTracker.UtxoOutpoint(Hex.encode(txidA), 1),
                  new ProjectTracker.UtxoOutpoint(Hex.encode(txidB), 0)),
              List.of(new ProjectTracker.StoredUtxo(txidC, 0, 3, 1, opReturn, false)),
              List.of(
                  new ProjectTracker.UtxoUndoEntry(txidA, 1, 1, 25, spendableScript, true),
                  new ProjectTracker.UtxoUndoEntry(txidB, 0, 2, 40, spendableScript, false))),
          ProjectTracker.UndoTimingSink.none());
      assertEquals(1, chainstate.stats().utxoCount());
    }
  }

  private static byte[] bytes32(String hexByte) {
    return Hex.decode(hexByte.repeat(32));
  }
}
