package com.jbitnode.messages;

import com.jbitnode.consensus.BlockHeader;
import com.jbitnode.util.Hex;
import com.jbitnode.wire.WireSerialize;
import java.util.Arrays;

/** Serialize and hash 80-byte block headers. */
public final class BlockHeaderCodec {

  public static final int HEADER_SIZE = 80;

  private BlockHeaderCodec() {}

  public static byte[] serialize(BlockHeader header) {
    byte[] buf = new byte[HEADER_SIZE];
    System.arraycopy(WireSerialize.packInt32Le(header.version()), 0, buf, 0, 4);
    System.arraycopy(header.prevBlock(), 0, buf, 4, 32);
    System.arraycopy(header.merkleRoot(), 0, buf, 36, 32);
    System.arraycopy(WireSerialize.packUint32Le(header.timestamp()), 0, buf, 68, 4);
    System.arraycopy(WireSerialize.packUint32Le(header.bits()), 0, buf, 72, 4);
    System.arraycopy(WireSerialize.packUint32Le(header.nonce()), 0, buf, 76, 4);
    return buf;
  }

  public static BlockHeader deserialize(byte[] data, int offset) {
    int version = WireSerialize.unpackInt32Le(data, offset);
    byte[] prevBlock = Arrays.copyOfRange(data, offset + 4, offset + 36);
    byte[] merkleRoot = Arrays.copyOfRange(data, offset + 36, offset + 68);
    long timestamp = WireSerialize.unpackUint32Le(data, offset + 68);
    long bits = WireSerialize.unpackUint32Le(data, offset + 72);
    long nonce = WireSerialize.unpackUint32Le(data, offset + 76);
    return new BlockHeader(version, prevBlock, merkleRoot, timestamp, bits, nonce);
  }

  public static byte[] blockHash(BlockHeader header) {
    return WireSerialize.doubleSha256(serialize(header));
  }

  public static String blockHashHex(BlockHeader header) {
    return Hex.encode(Hex.reverse(blockHash(header)));
  }
}
