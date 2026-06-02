package com.jbitnode.wire;

import static org.junit.jupiter.api.Assertions.assertEquals;

import com.jbitnode.chain.ChainRegistry;
import com.jbitnode.messages.HandshakeMessages;
import com.jbitnode.messages.HeadersMessage;
import com.jbitnode.consensus.BlockHeader;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.util.ArrayList;
import java.util.List;
import org.junit.jupiter.api.Test;

class MessageStreamTest {

  @Test
  void readsAndWritesFramedMessages() throws IOException {
    ByteArrayOutputStream output = new ByteArrayOutputStream();
    MessageStream stream =
        new MessageStream(new ByteArrayInputStream(new byte[0]), output, ChainRegistry.TESTNET4.magic());
    stream.send(HandshakeMessages.VERACK_COMMAND, HandshakeMessages.serializeVerAck());
    byte[] written = output.toByteArray();
    MessageStream reader =
        new MessageStream(
            new ByteArrayInputStream(written), new ByteArrayOutputStream(), ChainRegistry.TESTNET4.magic());
    NetworkMessage message = reader.readMessage(1000);
    assertEquals(HandshakeMessages.VERACK_COMMAND, message.command());
    assertEquals(0, message.payload().length);
  }

  @Test
  void readUntilCommandSkipsOtherMessages() throws IOException {
    byte[] ping =
        MessageFramer.buildMessage(
            ChainRegistry.TESTNET4.magic(), "ping", WireSerialize.packUint64Le(42));
    byte[] verack =
        MessageFramer.buildMessage(
            ChainRegistry.TESTNET4.magic(),
            HandshakeMessages.VERACK_COMMAND,
            HandshakeMessages.serializeVerAck());
    byte[] combined = new byte[ping.length + verack.length];
    System.arraycopy(ping, 0, combined, 0, ping.length);
    System.arraycopy(verack, 0, combined, ping.length, verack.length);
    MessageStream reader =
        new MessageStream(
            new ByteArrayInputStream(combined), new ByteArrayOutputStream(), ChainRegistry.TESTNET4.magic());
    NetworkMessage message = reader.readUntilCommand(HandshakeMessages.VERACK_COMMAND, 1000);
    assertEquals(HandshakeMessages.VERACK_COMMAND, message.command());
  }

  @Test
  void respondsToPingWhileWaiting() throws IOException {
    byte[] ping =
        MessageFramer.buildMessage(
            ChainRegistry.TESTNET4.magic(), "ping", WireSerialize.packUint64Le(99));
    byte[] headers =
        MessageFramer.buildMessage(
            ChainRegistry.TESTNET4.magic(),
            HeadersMessage.COMMAND,
            HeadersMessage.serialize(new HeadersMessage.Message(List.of())));
    byte[] combined = new byte[ping.length + headers.length];
    System.arraycopy(ping, 0, combined, 0, ping.length);
    System.arraycopy(headers, 0, combined, ping.length, headers.length);
    ByteArrayOutputStream output = new ByteArrayOutputStream();
    MessageStream reader =
        new MessageStream(
            new ByteArrayInputStream(combined), output, ChainRegistry.TESTNET4.magic());
    NetworkMessage message = reader.readUntilCommand(HeadersMessage.COMMAND, 1000);
    assertEquals(HeadersMessage.COMMAND, message.command());
    NetworkMessage pong =
        new MessageStream(
                new ByteArrayInputStream(output.toByteArray()),
                new ByteArrayOutputStream(),
                ChainRegistry.TESTNET4.magic())
            .readMessage(1000);
    assertEquals("pong", pong.command());
  }

  @Test
  void readsLargeHeadersPayload() throws IOException {
    List<BlockHeader> headers = new ArrayList<>();
    for (int i = 0; i < 300; i++) {
      headers.add(com.jbitnode.chain.Genesis.TESTNET4);
    }
    byte[] payload = HeadersMessage.serialize(new HeadersMessage.Message(headers));
    byte[] frame =
        MessageFramer.buildMessage(ChainRegistry.TESTNET4.magic(), HeadersMessage.COMMAND, payload);
    MessageStream reader =
        new MessageStream(
            new ByteArrayInputStream(frame), new ByteArrayOutputStream(), ChainRegistry.TESTNET4.magic());
    NetworkMessage message = reader.readMessage(5000);
    assertEquals(HeadersMessage.COMMAND, message.command());
    assertEquals(payload.length, message.payload().length);
  }

  @Test
  void readUntilAnyCommandAcceptsFirstMatch() throws IOException {
    byte[] ping =
        MessageFramer.buildMessage(
            ChainRegistry.TESTNET4.magic(), "ping", WireSerialize.packUint64Le(42));
    byte[] verack =
        MessageFramer.buildMessage(
            ChainRegistry.TESTNET4.magic(),
            HandshakeMessages.VERACK_COMMAND,
            HandshakeMessages.serializeVerAck());
    byte[] combined = new byte[ping.length + verack.length];
    System.arraycopy(ping, 0, combined, 0, ping.length);
    System.arraycopy(verack, 0, combined, ping.length, verack.length);
    MessageStream reader =
        new MessageStream(
            new ByteArrayInputStream(combined), new ByteArrayOutputStream(), ChainRegistry.TESTNET4.magic());
    NetworkMessage message =
        reader.readUntilAnyCommand(
            List.of(HandshakeMessages.VERACK_COMMAND, HeadersMessage.COMMAND), 1000);
    assertEquals(HandshakeMessages.VERACK_COMMAND, message.command());
  }

  @Test
  void timesOutWhenNoData() {
    MessageStream reader =
        new MessageStream(
            new ByteArrayInputStream(new byte[0]),
            new ByteArrayOutputStream(),
            ChainRegistry.TESTNET4.magic());
    org.junit.jupiter.api.Assertions.assertThrows(
        IOException.class, () -> reader.readMessage(50));
  }
}
