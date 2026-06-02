package com.jbitnode.consensus.connect;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.chain.ChainRegistry;
import com.jbitnode.db.ChainstateSession;
import com.jbitnode.testutil.NativeChainstateFixtures;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Map;

class BlockConnectorNativeTest {

  @Test
  void connectsEarlyFixtureBlocksIntoNativeRocksDbChainstate(@TempDir Path tempDir)
      throws Exception {
    Path dataDir = tempDir.resolve("data-java");
    var chain = ChainRegistry.get("testnet4");

    try (ChainstateSession session =
        ChainstateSession.openReadWrite(
            dataDir, dataDir.resolve("ignored.db"), chain, Map.of("UTXO_BACKEND", "rocksdb"), false)) {
      NativeChainstateFixtures.seedHeaders(session.tracker(), chain, 2);

      BlockConnector.ConnectResult first =
          BlockConnector.connectInCurrentTransaction(
              session.tracker(),
              session.chainstateStore(),
              chain.name(),
              1,
              NativeChainstateFixtures.blockPayload(1),
              com.jbitnode.messages.BlockHeaderCodec.blockHash(com.jbitnode.chain.Genesis.TESTNET4),
              NativeChainstateFixtures.blockHashInternal(1),
              BlockConnector.TimingSink.none());
      BlockConnector.ConnectResult second =
          BlockConnector.connectInCurrentTransaction(
              session.tracker(),
              session.chainstateStore(),
              chain.name(),
              2,
              NativeChainstateFixtures.blockPayload(2),
              NativeChainstateFixtures.blockHashInternal(1),
              NativeChainstateFixtures.blockHashInternal(2),
              BlockConnector.TimingSink.none());

      assertEquals(1, first.height());
      assertEquals(2, second.height());
      assertEquals(NativeChainstateFixtures.blockHashHex(2), session.tracker().getValidatedHash(chain.name()));
      assertEquals(2, session.chainstateStore().tip().height());
      assertEquals(4, session.chainstateStore().stats().utxoCount());
      assertTrue(session.chainstateStore().readUndo(chain.name(), 2).isEmpty());
      assertTrue(Files.exists(ChainstateSession.nativeStorageMarker(dataDir)));
      assertTrue(Files.notExists(dataDir.resolve("jbitnode.db")));
    }
  }
}
