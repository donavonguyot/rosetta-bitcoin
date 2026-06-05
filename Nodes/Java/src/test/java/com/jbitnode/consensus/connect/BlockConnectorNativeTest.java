package com.jbitnode.consensus.connect;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.chain.ChainRegistry;
import com.jbitnode.consensus.BlockHeader;
import com.jbitnode.consensus.block.Block;
import com.jbitnode.consensus.tx.OutPoint;
import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TxIn;
import com.jbitnode.consensus.tx.TxOut;
import com.jbitnode.db.ChainstateSession;
import com.jbitnode.testutil.NativeChainstateFixtures;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;

class BlockConnectorNativeTest {
  @Test
  void spendableOutputRejectsCoreUnspendableScripts() {
    assertFalse(BlockConnector.isSpendableOutput(new byte[] {}));
    assertFalse(BlockConnector.isSpendableOutput(new byte[] {(byte) 0x6a, 0x01, 0x02}));
    assertTrue(BlockConnector.isSpendableOutput(new byte[] {0x51}));
  }

  @Test
  void summarizesSlowBlockShapeDeterministically() {
    Transaction coinbase =
        new Transaction(
            1,
            List.of(new TxIn(new OutPoint(new byte[32], 0xffff_ffffL), new byte[] {0x01}, 0)),
            List.of(new TxOut(50, p2pkh())),
            0,
            List.of());
    Transaction legacy =
        new Transaction(
            1,
            List.of(new TxIn(new OutPoint(bytes32(0x11), 0), new byte[] {0x47}, 0xffff_fffeL)),
            List.of(new TxOut(25, p2sh()), new TxOut(0, opReturn())),
            0,
            List.of());
    Transaction witness =
        new Transaction(
            2,
            List.of(
                new TxIn(new OutPoint(bytes32(0x22), 0), new byte[] {}, 0xffff_fffdL),
                new TxIn(new OutPoint(bytes32(0x33), 1), new byte[] {}, 0xffff_fffcL)),
            List.of(new TxOut(20, p2wpkh()), new TxOut(10, p2wsh()), new TxOut(1, p2tr())),
            0,
            List.of(List.of(new byte[] {0x30}), List.of()));
    Transaction other =
        new Transaction(
            1,
            List.of(new TxIn(new OutPoint(bytes32(0x44), 2), new byte[] {}, 0xffff_fffbL)),
            List.of(new TxOut(1, new byte[] {}), new TxOut(1, new byte[] {(byte) 0xff})),
            0,
            List.of());
    Block block =
        new Block(
            new BlockHeader(1, new byte[32], new byte[32], 0, 0, 0),
            List.of(coinbase, legacy, witness, other));

    BlockConnector.BlockShapeSummary summary = BlockConnector.summarizeBlockShape(block).build();

    assertEquals(4, summary.txCount());
    assertEquals(5, summary.vinCount());
    assertEquals(8, summary.voutCount());
    assertEquals(4, summary.scriptInputCount());
    assertEquals(
        Map.of("coinbase", 1, "empty_spend", 2, "legacy_scriptsig", 1, "witness", 1),
        summary.inputShapeCounts());
    assertEquals(
        Map.of(
            "empty", 1,
            "op_return", 1,
            "other", 1,
            "p2pkh", 1,
            "p2sh", 1,
            "p2tr", 1,
            "p2wpkh", 1,
            "p2wsh", 1),
        summary.outputScriptTypes());
  }

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
      assertEquals(2, session.chainstateStore().stats().utxoCount());
      assertTrue(session.chainstateStore().readUndo(chain.name(), 2).isEmpty());
      assertTrue(Files.exists(ChainstateSession.nativeStorageMarker(dataDir)));
    }
  }

  private static byte[] bytes32(int value) {
    byte[] bytes = new byte[32];
    java.util.Arrays.fill(bytes, (byte) value);
    return bytes;
  }

  private static byte[] p2pkh() {
    byte[] script = new byte[25];
    script[0] = 0x76;
    script[1] = (byte) 0xa9;
    script[2] = 0x14;
    script[23] = (byte) 0x88;
    script[24] = (byte) 0xac;
    return script;
  }

  private static byte[] p2sh() {
    byte[] script = new byte[23];
    script[0] = (byte) 0xa9;
    script[1] = 0x14;
    script[22] = (byte) 0x87;
    return script;
  }

  private static byte[] p2wpkh() {
    byte[] script = new byte[22];
    script[0] = 0x00;
    script[1] = 0x14;
    return script;
  }

  private static byte[] p2wsh() {
    byte[] script = new byte[34];
    script[0] = 0x00;
    script[1] = 0x20;
    return script;
  }

  private static byte[] p2tr() {
    byte[] script = new byte[34];
    script[0] = 0x51;
    script[1] = 0x20;
    return script;
  }

  private static byte[] opReturn() {
    return new byte[] {(byte) 0x6a, 0x01, 0x01};
  }
}
