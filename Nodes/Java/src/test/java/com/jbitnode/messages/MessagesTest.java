package com.jbitnode.messages;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import com.jbitnode.chain.Genesis;
import com.jbitnode.consensus.BlockHeader;
import java.util.List;
import org.junit.jupiter.api.Test;

class HandshakeMessagesTest {

  private final NetworkAddress addr =
      new NetworkAddress(
          HandshakeMessages.NODE_NETWORK | HandshakeMessages.NODE_WITNESS, "127.0.0.1", 48_333);

  @Test
  void roundTripsVersionMessage() {
    VersionMessage version =
        HandshakeMessages.buildVersionMessage(
            70_016,
            HandshakeMessages.NODE_NETWORK | HandshakeMessages.NODE_WITNESS,
            addr,
            addr,
            "/jbitnode:0.1.0/",
            0,
            true);
    VersionMessage restored =
        HandshakeMessages.deserializeVersion(HandshakeMessages.serializeVersion(version));
    assertEquals(70_016, restored.version());
    assertEquals("/jbitnode:0.1.0/", restored.userAgent());
    assertEquals("127.0.0.1", restored.addrRecv().ip());
    assertEquals(48_333, restored.addrRecv().port());
    assertEquals(true, restored.relay());
  }

  @Test
  void serializesEmptyVerackAndSendheaders() {
    assertEquals(0, HandshakeMessages.serializeVerAck().length);
    assertEquals(0, HandshakeMessages.serializeSendHeaders().length);
  }

  @Test
  void roundTripsIpv6Address() {
    byte[] bytes = HandshakeMessages.ipToBytes("2001:db8::1");
    assertArrayEquals(bytes, HandshakeMessages.ipToBytes(HandshakeMessages.bytesToIp(bytes)));
  }

  @Test
  void rejectsInvalidIpv4() {
    assertThrows(IllegalArgumentException.class, () -> HandshakeMessages.ipToBytes("1.2.3"));
  }
}

class HeaderMessagesTest {

  @Test
  void roundTripsGetHeaders() {
    byte[] locator = BlockHeaderCodec.blockHash(Genesis.TESTNET4);
    GetHeadersMessage.Message message =
        new GetHeadersMessage.Message(70_016, List.of(locator), new byte[32]);
    GetHeadersMessage.Message restored =
        GetHeadersMessage.deserialize(GetHeadersMessage.serialize(message));
    assertEquals(70_016, restored.version());
    assertEquals(1, restored.locatorHashes().size());
  }

  @Test
  void rejectsInvalidGetHeadersLength() {
    byte[] bad = new byte[] {0, 0, 0, 0, 0};
    assertThrows(IllegalArgumentException.class, () -> GetHeadersMessage.deserialize(bad));
  }

  @Test
  void roundTripsHeadersMessage() {
    HeadersMessage.Message message = new HeadersMessage.Message(List.of(Genesis.TESTNET4));
    HeadersMessage.Message restored =
        HeadersMessage.deserialize(HeadersMessage.serialize(message));
    assertEquals(1, restored.headers().size());
    assertEquals(
        BlockHeaderCodec.blockHashHex(Genesis.TESTNET4),
        BlockHeaderCodec.blockHashHex(restored.headers().getFirst()));
  }

  @Test
  void blockHeaderCodecRoundTrip() {
    BlockHeader header = Genesis.TESTNET4;
    BlockHeader restored =
        BlockHeaderCodec.deserialize(BlockHeaderCodec.serialize(header), 0);
    assertEquals(header.version(), restored.version());
    assertEquals(header.timestamp(), restored.timestamp());
  }

  @Test
  void rejectsInvalidBlockHeaderFieldSizes() {
    assertThrows(
        IllegalArgumentException.class,
        () -> new BlockHeader(1, new byte[31], new byte[32], 0, 0, 0));
  }
}
