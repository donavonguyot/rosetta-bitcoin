package com.jbitnode.cli;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.fasterxml.jackson.databind.node.ObjectNode;
import com.jbitnode.chain.ChainRegistry;
import com.jbitnode.db.ChainstateBlockCommit;
import com.jbitnode.db.ChainstateSession;
import com.jbitnode.db.ProjectTracker;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;

class DbStatusNativeTest {
  private static final String BLOCK_1_HASH =
      "0000000012982b6d5f621229286b880e909984df669c2afabb102ce311b13f28";

  @Test
  void statusReadsNativeStoresWithoutCreatingLocalSqlite(@TempDir Path tempDir) throws Exception {
    Path dataDir = tempDir.resolve("data-java");
    var chain = ChainRegistry.get("testnet4");
    try (ChainstateSession session =
        ChainstateSession.openReadWrite(
            dataDir, dataDir.resolve("ignored.db"), chain, Map.of("UTXO_BACKEND", "rocksdb"), true)) {
      session
          .chainstateStore()
          .commitBlock(
              new ChainstateBlockCommit("testnet4", 1, BLOCK_1_HASH, List.of(), List.of(), List.of()),
              ProjectTracker.UndoTimingSink.none());
    }

    ObjectNode status = DbStatusService.summaryFromDataDir(dataDir, "testnet4");

    assertEquals("rocksdb", status.get("chainstate_backend").asText());
    assertEquals(1, status.get("validated_height").asInt());
    assertEquals(BLOCK_1_HASH, status.get("validated_hash").asText());
    assertTrue(Files.exists(ChainstateSession.nativeStorageMarker(dataDir)));
    assertFalse(Files.exists(dataDir.resolve("jbitnode.db")));
  }
}
