package com.jbitnode.consensus.block;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import com.jbitnode.testutil.FixtureLoader;
import org.junit.jupiter.api.Test;

class BlockDeserializerTest {

  @Test
  void deserializesCommittedBlkFixture() {
    byte[] payload = FixtureLoader.readHex("/fixtures/block1_wire.hex");
    Block block = BlockDeserializer.deserialize(payload);
    assertEquals(1, block.transactions().size());
    assertEquals(1, block.transactions().getFirst().version());
  }

  @Test
  void rejectsTrailingBytes() {
    byte[] payload = FixtureLoader.readHex("/fixtures/block1_wire.hex");
    byte[] padded = new byte[payload.length + 1];
    System.arraycopy(payload, 0, padded, 0, payload.length);
    padded[payload.length] = 0x00;
    assertThrows(IllegalArgumentException.class, () -> BlockDeserializer.deserialize(padded));
  }
}
