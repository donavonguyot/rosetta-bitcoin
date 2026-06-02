package com.jbitnode.util;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import org.junit.jupiter.api.Test;

class HexTest {

  @Test
  void encodeDecodeRoundTrip() {
    byte[] data = {0x00, (byte) 0xda, (byte) 0x84, (byte) 0xf2};
    assertArrayEquals(data, Hex.decode(Hex.encode(data)));
  }

  @Test
  void reverseBytes() {
    assertArrayEquals(new byte[] {3, 2, 1}, Hex.reverse(new byte[] {1, 2, 3}));
  }

  @Test
  void rejectsOddLengthHex() {
    assertThrows(IllegalArgumentException.class, () -> Hex.decode("abc"));
  }
}
