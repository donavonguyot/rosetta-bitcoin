package com.jbitnode.messages;

import com.jbitnode.wire.WireSerialize;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/** getheaders message serialization. */
public final class GetHeadersMessage {

  public static final String COMMAND = "getheaders";

  private GetHeadersMessage() {}

  public record Message(int version, List<byte[]> locatorHashes, byte[] hashStop) {}

  public static byte[] serialize(Message message) {
    byte[] count = WireSerialize.writeCompactSize(message.locatorHashes().size());
    int size = 4 + count.length + message.locatorHashes().size() * 32 + 32;
    byte[] out = new byte[size];
    int offset = 0;
    System.arraycopy(WireSerialize.packInt32Le(message.version()), 0, out, offset, 4);
    offset += 4;
    System.arraycopy(count, 0, out, offset, count.length);
    offset += count.length;
    for (byte[] hash : message.locatorHashes()) {
      System.arraycopy(hash, 0, out, offset, 32);
      offset += 32;
    }
    System.arraycopy(message.hashStop(), 0, out, offset, 32);
    return out;
  }

  public static Message deserialize(byte[] payload) {
    int version = WireSerialize.unpackInt32Le(payload, 0);
    WireSerialize.CompactSizeResult count = WireSerialize.readCompactSize(payload, 4);
    int offset = count.nextOffset();
    List<byte[]> locatorHashes = new ArrayList<>();
    for (int i = 0; i < count.value(); i++) {
      locatorHashes.add(Arrays.copyOfRange(payload, offset, offset + 32));
      offset += 32;
    }
    if (offset + 32 != payload.length) {
      throw new IllegalArgumentException("invalid getheaders payload length");
    }
    byte[] hashStop = Arrays.copyOfRange(payload, offset, offset + 32);
    return new Message(version, locatorHashes, hashStop);
  }
}
