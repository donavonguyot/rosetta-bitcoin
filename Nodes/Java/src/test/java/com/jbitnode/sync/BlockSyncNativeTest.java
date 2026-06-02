package com.jbitnode.sync;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.chain.ChainRegistry;
import com.jbitnode.db.ChainstateSession;
import com.jbitnode.testutil.NativeChainstateFixtures;
import com.jbitnode.util.Hex;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Map;

class BlockSyncNativeTest {

  @Test
  void syncsFixtureBlocksAndPersistsNativeTipAcrossRestart(@TempDir Path tempDir)
      throws Exception {
    Path dataDir = tempDir.resolve("data-java");
    var chain = ChainRegistry.get("testnet4");
    Map<String, String> env = Map.of("UTXO_BACKEND", "rocksdb");

    try (ChainstateSession session =
        ChainstateSession.openReadWrite(dataDir, dataDir.resolve("ignored.db"), chain, env, false)) {
      NativeChainstateFixtures.seedHeaders(session.tracker(), chain, 2);

      BlockSync.Result result =
          BlockSync.syncFromBlockSource(
              new FixtureBlockSource(NativeChainstateFixtures.payloadsByInternalHash(2)),
              chain,
              session.tracker(),
              session.blockStorage(),
              session.chainstateStore(),
              2,
              BlockSync.TimingSink.none(),
              false);

      assertEquals(2, result.downloaded());
      assertEquals(2, result.connected());
      assertEquals(2, result.validatedHeight());
      assertEquals("blocks_current", result.syncStatus());
      assertEquals(2, session.tracker().blockCount(chain.name()));
      assertArrayEquals(
          NativeChainstateFixtures.blockPayload(2),
          session.blockStorage().readBlock(chain.name(), 2));
    }

    try (ChainstateSession restarted =
        ChainstateSession.openReadWrite(dataDir, dataDir.resolve("ignored.db"), chain, env, false)) {
      assertEquals(2, restarted.tracker().getValidatedHeight(chain.name()));
      assertEquals(NativeChainstateFixtures.blockHashHex(2), restarted.tracker().getValidatedHash(chain.name()));
      assertEquals(2, restarted.chainstateStore().tip().height());
      assertEquals("blocks_current", restarted.tracker().getSyncState(chain.name()).orElseThrow().syncStatus());
      assertTrue(Files.exists(ChainstateSession.nativeStorageMarker(dataDir)));
      assertTrue(Files.notExists(dataDir.resolve("jbitnode.db")));
    }
  }

  private record FixtureBlockSource(Map<String, byte[]> payloads) implements BlockSync.BlockSource {
    @Override
    public byte[] requestBlock(byte[] blockHashInternal) {
      return payloads.get(Hex.encode(blockHashInternal));
    }

    @Override
    public void markBlockDownloadCapabilities() {}
  }
}
