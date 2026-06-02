package com.jbitnode.wire;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import org.junit.jupiter.api.Test;

class WireSerializeTest {

  @Test
  void roundTripsCompactSize() {
    for (long value : new long[] {0, 12, 252, 0xfd, 0xffff, 0x1_0000, 0xffff_ffffL}) {
      byte[] encoded = WireSerialize.writeCompactSize(value);
      WireSerialize.CompactSizeResult decoded = WireSerialize.readCompactSize(encoded, 0);
      assertEquals(value, decoded.value());
      assertEquals(encoded.length, decoded.nextOffset());
    }
  }

  @Test
  void doubleSha256IsDeterministic() {
    byte[] first = WireSerialize.doubleSha256(new byte[] {1, 2, 3});
    byte[] second = WireSerialize.doubleSha256(new byte[] {1, 2, 3});
    assertArrayEquals(first, second);
  }

  @Test
  void messageChecksumUsesFirstFourBytes() {
    byte[] payload = "payload".getBytes();
    byte[] checksum = WireSerialize.messageChecksum(payload);
    assertEquals(4, checksum.length);
    assertArrayEquals(java.util.Arrays.copyOfRange(WireSerialize.doubleSha256(payload), 0, 4), checksum);
  }

  @Test
  void rejectsTruncatedCompactSize() {
    assertThrows(ArrayIndexOutOfBoundsException.class, () -> WireSerialize.readCompactSize(new byte[0], 0));
  }
}
