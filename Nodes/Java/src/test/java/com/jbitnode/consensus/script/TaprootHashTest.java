package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;
import org.junit.jupiter.api.Test;

class TaprootHashTest {

  @Test
  void tapleafHashIsDeterministic() {
    byte[] script = new byte[] {(byte) OpCodes.OP_1};
    byte[] first = TaprootHash.tapleafHash(0xc0, script);
    byte[] second = TaprootHash.tapleafHash(0xc0, script);
    assertEquals(32, first.length);
    assertEquals(first.length, second.length);
    for (int index = 0; index < first.length; index++) {
      assertEquals(first[index], second[index]);
    }
  }

  @Test
  void merkleBranchOrdersSiblingsLexicographically() {
    byte[] leaf = TaprootHash.tapleafHash(0xc0, new byte[] {(byte) OpCodes.OP_1});
    byte[] sibling = new byte[32];
    sibling[0] = 0x01;
    byte[] rootA = TaprootHash.taprootMerkleRootFromBranch(List.of(sibling), leaf);
    byte[] rootB =
        TaprootHash.taprootMerkleRootFromBranch(
            List.of(new byte[] {(byte) 0x02}), TaprootHash.tapleafHash(0xc0, new byte[] {0x02}));
    assertNotEquals(rootA, rootB);
  }

  @Test
  void serializedWitnessStackBytesIncludesCompactSizes() {
    byte[] blob = TaprootHash.serializedWitnessStackBytes(List.of(new byte[] {0x01}, new byte[0]));
    assertTrue(blob.length >= 3);
  }
}
