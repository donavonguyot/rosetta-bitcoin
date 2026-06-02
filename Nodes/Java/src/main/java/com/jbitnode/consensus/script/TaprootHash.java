package com.jbitnode.consensus.script;

import com.jbitnode.wire.WireSerialize;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.util.Arrays;
import java.util.Comparator;
import java.util.List;

/** BIP341 TapLeaf / TapBranch merkle helpers and witness serialization for tapscript weight. */
final class TaprootHash {

  static final int TAPROOT_LEAF_VERSION_TAPSCRIPT = 0xc0;

  private TaprootHash() {}

  static byte[] tapleafHash(int leafVersion, byte[] tapscriptBytes) {
    ByteArrayOutputStream message = new ByteArrayOutputStream();
    try {
      message.write(leafVersion & 0xff);
      message.write(WireSerialize.writeCompactSize(tapscriptBytes.length));
      message.write(tapscriptBytes);
    } catch (IOException error) {
      throw new IllegalStateException("tapleaf hash serialization failed", error);
    }
    return ScriptHash.bitcoinTaggedHash("TapLeaf", message.toByteArray());
  }

  static byte[] tapbranchHash(byte[] left, byte[] right) {
    byte[] pair =
        compareLex(left, right) < 0 ? concat(left, right) : concat(right, left);
    return ScriptHash.bitcoinTaggedHash("TapBranch", pair);
  }

  static byte[] taprootMerkleRootFromBranch(List<byte[]> branchNodes, byte[] leafHash) {
    byte[] accumulator = leafHash;
    for (byte[] sibling : branchNodes) {
      accumulator = tapbranchHash(accumulator, sibling);
    }
    return accumulator;
  }

  static byte[] serializedWitnessStackBytes(List<byte[]> stack) {
    ByteArrayOutputStream blob = new ByteArrayOutputStream();
    try {
      blob.write(WireSerialize.writeCompactSize(stack.size()));
      for (byte[] item : stack) {
        blob.write(WireSerialize.writeCompactSize(item.length));
        blob.write(item);
      }
    } catch (IOException error) {
      throw new IllegalStateException("witness stack serialization failed", error);
    }
    return blob.toByteArray();
  }

  private static int compareLex(byte[] left, byte[] right) {
    return Comparator.comparing((byte[] bytes) -> bytes, Arrays::compareUnsigned).compare(left, right);
  }

  private static byte[] concat(byte[] left, byte[] right) {
    byte[] out = Arrays.copyOf(left, left.length + right.length);
    System.arraycopy(right, 0, out, left.length, right.length);
    return out;
  }
}
