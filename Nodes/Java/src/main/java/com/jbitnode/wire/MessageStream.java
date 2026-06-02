package com.jbitnode.wire;

import java.io.ByteArrayOutputStream;
import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.Arrays;
import java.util.List;

/** Reads and writes framed Bitcoin P2P messages on a byte stream. */
public final class MessageStream {

  private final InputStream input;
  private final OutputStream output;
  private final byte[] magic;
  private byte[] buffer = new byte[8192];
  private int bufferLength;
  private int bufferOffset;

  public MessageStream(InputStream input, OutputStream output, byte[] magic) {
    this.input = input;
    this.output = output;
    this.magic = Arrays.copyOf(magic, magic.length);
  }

  public void send(String command, byte[] payload) throws IOException {
    byte[] frame = MessageFramer.buildMessage(magic, command, payload);
    output.write(frame);
    output.flush();
  }

  public NetworkMessage readMessage(long timeoutMs) throws IOException {
    long deadline = System.currentTimeMillis() + timeoutMs;
    while (true) {
      if (bufferLength - bufferOffset >= MessageFramer.HEADER_SIZE) {
        MessageHeader header =
            MessageFramer.parseHeader(
                Arrays.copyOfRange(buffer, bufferOffset, bufferOffset + MessageFramer.HEADER_SIZE));
        int total = MessageFramer.HEADER_SIZE + header.length();
        ensureCapacity(bufferOffset + total);
        if (bufferLength - bufferOffset >= total) {
          byte[] payload =
              Arrays.copyOfRange(
                  buffer, bufferOffset + MessageFramer.HEADER_SIZE, bufferOffset + total);
          bufferOffset += total;
          compactBuffer();
          if (!Arrays.equals(header.magic(), magic)) {
            throw new IOException("Unexpected network magic");
          }
          if (!MessageFramer.verifyChecksum(payload, header.checksum())) {
            throw new IOException("Checksum mismatch for " + header.command());
          }
          return new NetworkMessage(header.command(), payload);
        }
      }
      if (System.currentTimeMillis() >= deadline) {
        throw new IOException("Timed out waiting for message");
      }
      ensureCapacity(bufferLength + 4096);
      int read = input.read(buffer, bufferLength, buffer.length - bufferLength);
      if (read < 0) {
        throw new EOFException("Peer closed connection");
      }
      if (read == 0) {
        continue;
      }
      bufferLength += read;
    }
  }

  public NetworkMessage readUntilAnyCommand(List<String> commands, long timeoutMs)
      throws IOException {
    return readUntilAnyCommand(commands, timeoutMs, this::dispatchWhileWaiting);
  }

  public NetworkMessage readUntilAnyCommand(
      List<String> commands, long timeoutMs, InterimHandler handler) throws IOException {
    long deadline = System.currentTimeMillis() + timeoutMs;
    while (true) {
      long remaining = deadline - System.currentTimeMillis();
      if (remaining <= 0) {
        throw new IOException("Timed out waiting for one of " + commands);
      }
      NetworkMessage message = readMessage(remaining);
      if (commands.contains(message.command())) {
        return message;
      }
      handler.handle(this, message);
    }
  }

  public NetworkMessage readUntilCommand(String command, long timeoutMs) throws IOException {
    return readUntilCommand(command, timeoutMs, this::dispatchWhileWaiting);
  }

  public NetworkMessage readUntilCommand(
      String command, long timeoutMs, InterimHandler handler) throws IOException {
    long deadline = System.currentTimeMillis() + timeoutMs;
    while (true) {
      long remaining = deadline - System.currentTimeMillis();
      if (remaining <= 0) {
        throw new IOException("Timed out waiting for " + command);
      }
      NetworkMessage message = readMessage(remaining);
      if (command.equals(message.command())) {
        return message;
      }
      handler.handle(this, message);
    }
  }

  private void dispatchWhileWaiting(MessageStream stream, NetworkMessage message)
      throws IOException {
    if ("ping".equals(message.command())) {
      stream.send("pong", message.payload());
    }
  }

  private void ensureCapacity(int required) {
    if (required <= buffer.length) {
      return;
    }
    int newSize = Math.max(required, buffer.length * 2);
    buffer = Arrays.copyOf(buffer, newSize);
  }

  private void compactBuffer() {
    if (bufferOffset == 0) {
      return;
    }
    int remaining = bufferLength - bufferOffset;
    if (remaining > 0) {
      System.arraycopy(buffer, bufferOffset, buffer, 0, remaining);
    }
    bufferOffset = 0;
    bufferLength = remaining;
  }

  @FunctionalInterface
  public interface InterimHandler {
    void handle(MessageStream stream, NetworkMessage message) throws IOException;
  }
}
