package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertEquals;

import org.junit.jupiter.api.Test;

class ScriptHashTest {

  @Test
  void hash160EmptyVector() {
    assertEquals(
        "b472a266d0bd89c13706a4132ccfb16f7c3b9fcb", ScriptHash.hash160Hex(new byte[0]));
  }

  @Test
  void hash160ProducesTwentyBytes() {
    assertEquals(40, ScriptHash.hash160Hex(new byte[] {0x01, 0x02}).length());
  }
}
