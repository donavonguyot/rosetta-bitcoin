package com.jbitnode.messages;

import com.jbitnode.consensus.BlockHeader;

/** Raw block wire message (header + transactions). */
public final class BlockMessage {

  public static final String COMMAND = "block";

  private BlockMessage() {}

  public static byte[] serialize(byte[] payload) {
    return payload;
  }

  public static byte[] deserialize(byte[] payload) {
    return payload;
  }

  public static byte[] blockHashFromPayload(byte[] payload) {
    BlockHeader header = BlockHeaderCodec.deserialize(payload, 0);
    return BlockHeaderCodec.blockHash(header);
  }

  public static String blockHashHexFromPayload(byte[] payload) {
    return BlockHeaderCodec.blockHashHex(BlockHeaderCodec.deserialize(payload, 0));
  }
}
