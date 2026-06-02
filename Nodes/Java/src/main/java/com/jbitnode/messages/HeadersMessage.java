package com.jbitnode.messages;

import com.jbitnode.consensus.BlockHeader;
import com.jbitnode.wire.WireSerialize;
import java.util.ArrayList;
import java.util.List;

/** headers message serialization (80-byte header + trailing compact-size tx count). */
public final class HeadersMessage {

  public static final String COMMAND = "headers";

  private HeadersMessage() {}

  public record Message(List<BlockHeader> headers) {}

  public static byte[] serialize(Message message) {
    byte[] count = WireSerialize.writeCompactSize(message.headers().size());
    int size = count.length + message.headers().size() * (BlockHeaderCodec.HEADER_SIZE + 1);
    byte[] out = new byte[size];
    int offset = 0;
    System.arraycopy(count, 0, out, offset, count.length);
    offset += count.length;
    for (BlockHeader header : message.headers()) {
      byte[] serialized = BlockHeaderCodec.serialize(header);
      System.arraycopy(serialized, 0, out, offset, serialized.length);
      offset += serialized.length;
      out[offset++] = 0x00;
    }
    return out;
  }

  public static Message deserialize(byte[] payload) {
    WireSerialize.CompactSizeResult count = WireSerialize.readCompactSize(payload, 0);
    int offset = count.nextOffset();
    List<BlockHeader> headers = new ArrayList<>();
    for (int i = 0; i < count.value(); i++) {
      BlockHeader header = BlockHeaderCodec.deserialize(payload, offset);
      offset += BlockHeaderCodec.HEADER_SIZE;
      WireSerialize.CompactSizeResult txCount = WireSerialize.readCompactSize(payload, offset);
      offset = txCount.nextOffset();
      headers.add(header);
    }
    return new Message(headers);
  }
}
