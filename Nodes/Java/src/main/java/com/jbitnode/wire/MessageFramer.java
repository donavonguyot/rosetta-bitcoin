package com.jbitnode.wire;

import java.nio.charset.StandardCharsets;
import java.util.Arrays;

/** Bitcoin P2P message envelope framing (magic, command, length, checksum, payload). */
public final class MessageFramer {

  public static final int HEADER_SIZE = 24;

  private MessageFramer() {}

  public static MessageHeader parseHeader(byte[] data) {
    if (data.length < HEADER_SIZE) {
      throw new IllegalArgumentException(
          "header requires " + HEADER_SIZE + " bytes, got " + data.length);
    }
    byte[] magic = Arrays.copyOfRange(data, 0, 4);
    String command =
        new String(data, 4, 12, StandardCharsets.US_ASCII).replaceAll("\0+$", "");
    int length = WireSerialize.unpackInt32Le(data, 16);
    byte[] checksum = Arrays.copyOfRange(data, 20, 24);
    return new MessageHeader(magic, command, length, checksum);
  }

  public static byte[] headerToBytes(MessageHeader header) {
    byte[] buf = new byte[HEADER_SIZE];
    System.arraycopy(header.magic(), 0, buf, 0, 4);
    byte[] cmd = new byte[12];
    byte[] commandBytes = header.command().getBytes(StandardCharsets.US_ASCII);
    System.arraycopy(commandBytes, 0, cmd, 0, Math.min(commandBytes.length, 12));
    System.arraycopy(cmd, 0, buf, 4, 12);
    System.arraycopy(WireSerialize.packInt32Le(header.length()), 0, buf, 16, 4);
    System.arraycopy(header.checksum(), 0, buf, 20, 4);
    return buf;
  }

  public static byte[] buildMessage(byte[] magic, String command, byte[] payload) {
    byte[] checksum = WireSerialize.messageChecksum(payload);
    byte[] header =
        headerToBytes(new MessageHeader(magic, command, payload.length, checksum));
    byte[] frame = new byte[header.length + payload.length];
    System.arraycopy(header, 0, frame, 0, header.length);
    System.arraycopy(payload, 0, frame, header.length, payload.length);
    return frame;
  }

  public static boolean verifyChecksum(byte[] payload, byte[] checksum) {
    return Arrays.equals(WireSerialize.messageChecksum(payload), checksum);
  }
}
