package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertEquals;

import com.jbitnode.util.Hex;
import java.nio.charset.StandardCharsets;
import org.junit.jupiter.api.Test;

class ScriptHashTest {

  @Test
  void ripemd160Vectors() {
    assertEquals("9c1185a5c5e9fc54612808977ee8f548b2258d31", Hex.encode(ScriptHash.ripemd160(new byte[0])));
    assertEquals(
        "0bdc9d2d256b3ee9daae347be6f4dc835a467ffe",
        Hex.encode(ScriptHash.ripemd160("a".getBytes(StandardCharsets.US_ASCII))));
    assertEquals(
        "8eb208f7e05d987a9b044a8e98c6b087f15a0bfc",
        Hex.encode(ScriptHash.ripemd160("abc".getBytes(StandardCharsets.US_ASCII))));
    assertEquals(
        "12a053384a9c0c88e405a06c27dcf49ada62eb2b",
        Hex.encode(
            ScriptHash.ripemd160(
                "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
                    .getBytes(StandardCharsets.US_ASCII))));
  }

  @Test
  void hash160Vectors() {
    assertEquals("b472a266d0bd89c13706a4132ccfb16f7c3b9fcb", ScriptHash.hash160Hex(new byte[0]));
    assertEquals("bb1be98c142444d7a56aa3981c3942a978e4dc33", ScriptHash.hash160Hex("abc".getBytes(StandardCharsets.US_ASCII)));
  }

  @Test
  void hash160ProducesTwentyBytes() {
    assertEquals(40, ScriptHash.hash160Hex(new byte[] {0x01, 0x02}).length());
  }
}
