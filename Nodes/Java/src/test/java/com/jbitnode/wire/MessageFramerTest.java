package com.jbitnode.wire;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.chain.ChainRegistry;
import org.junit.jupiter.api.Test;

class MessageFramerTest {

  @Test
  void roundTripsMessageFrame() {
    byte[] magic = ChainRegistry.TESTNET4.magic();
    byte[] payload = "payload".getBytes();
    byte[] framed = MessageFramer.buildMessage(magic, "version", payload);
    MessageHeader header = MessageFramer.parseHeader(framed);
    assertEquals("version", header.command());
    assertEquals(payload.length, header.length());
    assertTrue(MessageFramer.verifyChecksum(payload, header.checksum()));
  }

  @Test
  void headerToBytesRoundTrip() {
    byte[] magic = ChainRegistry.TESTNET4.magic();
    byte[] checksum = WireSerialize.messageChecksum(new byte[0]);
    MessageHeader header = new MessageHeader(magic, "verack", 0, checksum);
    MessageHeader parsed = MessageFramer.parseHeader(MessageFramer.headerToBytes(header));
    assertEquals("verack", parsed.command());
    assertEquals(0, parsed.length());
  }
}
