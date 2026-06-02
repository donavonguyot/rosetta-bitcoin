package com.jbitnode.testutil;

import com.jbitnode.chain.ChainParams;
import com.jbitnode.chain.Genesis;
import com.jbitnode.consensus.block.Block;
import com.jbitnode.consensus.block.BlockDeserializer;
import com.jbitnode.db.ProjectTracker;
import com.jbitnode.messages.BlockHeaderCodec;
import com.jbitnode.util.Hex;
import java.sql.SQLException;
import java.util.LinkedHashMap;
import java.util.Map;

/** Helpers for native LevelDB chainstate tests using early testnet4 blocks. */
public final class NativeChainstateFixtures {

  private NativeChainstateFixtures() {}

  public static byte[] blockPayload(int height) {
    return FixtureLoader.readHex("/fixtures/block" + height + "_wire.hex");
  }

  public static Block block(int height) {
    return BlockDeserializer.deserialize(blockPayload(height));
  }

  public static String blockHashHex(int height) {
    return BlockHeaderCodec.blockHashHex(block(height).header());
  }

  public static byte[] blockHashInternal(int height) {
    return Hex.reverse(Hex.decode(blockHashHex(height)));
  }

  public static void seedGenesis(ProjectTracker tracker, ChainParams chain) throws SQLException {
    tracker.ensureGenesis(chain.name(), Genesis.forChain(chain.name()), chain.genesisHash());
  }

  public static void seedHeaders(ProjectTracker tracker, ChainParams chain, int throughHeight)
      throws SQLException {
    seedGenesis(tracker, chain);
    String previousHash = chain.genesisHash();
    for (int height = 1; height <= throughHeight; height++) {
      Block block = block(height);
      String blockHash = BlockHeaderCodec.blockHashHex(block.header());
      tracker.recordHeader(
          chain.name(),
          height,
          blockHash,
          previousHash,
          Hex.encode(BlockHeaderCodec.serialize(block.header())));
      previousHash = blockHash;
    }
    tracker.upsertSyncState(
        chain.name(),
        new ProjectTracker.SyncStatePatch(
            throughHeight, previousHash, throughHeight + 1, "headers_current"));
  }

  public static Map<String, byte[]> payloadsByInternalHash(int throughHeight) {
    Map<String, byte[]> payloads = new LinkedHashMap<>();
    for (int height = 1; height <= throughHeight; height++) {
      payloads.put(Hex.encode(blockHashInternal(height)), blockPayload(height));
    }
    return payloads;
  }
}
