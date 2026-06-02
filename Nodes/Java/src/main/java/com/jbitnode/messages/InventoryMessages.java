package com.jbitnode.messages;

import com.jbitnode.wire.WireSerialize;
import com.jbitnode.wire.WireSerialize.CompactSizeResult;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Set;

/** inv / getdata / notfound inventory vectors. */
public final class InventoryMessages {

  public static final int MSG_TX = 1;
  public static final int MSG_BLOCK = 2;
  public static final int MSG_WITNESS_TX = MSG_TX | (1 << 30);
  public static final int MSG_WITNESS_BLOCK = MSG_BLOCK | (1 << 30);

  public static final Set<Integer> BLOCK_INVENTORY_TYPES =
      Set.of(MSG_BLOCK, MSG_WITNESS_BLOCK);

  private InventoryMessages() {}

  public record InventoryVector(int type, byte[] hash) {}

  public record InvMessage(List<InventoryVector> inventory) {}

  public static final class GetDataMessage {
    public static final String COMMAND = "getdata";

    private GetDataMessage() {}

    public static byte[] serialize(InvMessage message) {
      return InvMessageCodec.serialize(message);
    }

    public static InvMessage deserialize(byte[] payload) {
      return InvMessageCodec.deserialize(payload);
    }
  }

  public static final class NotFoundMessage {
    public static final String COMMAND = "notfound";

    private NotFoundMessage() {}

    public static byte[] serialize(InvMessage message) {
      return InvMessageCodec.serialize(message);
    }

    public static InvMessage deserialize(byte[] payload) {
      return InvMessageCodec.deserialize(payload);
    }
  }

  public static final class InvMessageCodec {
    public static final String COMMAND = "inv";

    private InvMessageCodec() {}

    public static byte[] serialize(InvMessage message) {
      byte[] count = WireSerialize.writeCompactSize(message.inventory().size());
      int size = count.length + message.inventory().size() * 36;
      byte[] out = new byte[size];
      int offset = 0;
      System.arraycopy(count, 0, out, offset, count.length);
      offset += count.length;
      for (InventoryVector item : message.inventory()) {
        byte[] encoded = InventoryVectorCodec.serialize(item);
        System.arraycopy(encoded, 0, out, offset, encoded.length);
        offset += encoded.length;
      }
      return out;
    }

    public static InvMessage deserialize(byte[] payload) {
      CompactSizeResult count = WireSerialize.readCompactSize(payload, 0);
      int offset = count.nextOffset();
      List<InventoryVector> inventory = new ArrayList<>();
      for (int index = 0; index < count.value(); index++) {
        if (offset + 36 > payload.length) {
          throw new IllegalArgumentException("invalid inv payload length");
        }
        InventoryVector item = InventoryVectorCodec.deserialize(payload, offset);
        inventory.add(item);
        offset += 36;
      }
      if (offset != payload.length) {
        throw new IllegalArgumentException("invalid inv payload length");
      }
      return new InvMessage(List.copyOf(inventory));
    }
  }

  static final class InventoryVectorCodec {
    private InventoryVectorCodec() {}

    static byte[] serialize(InventoryVector item) {
      if (item.hash().length != 32) {
        throw new IllegalArgumentException("inventory hash must be 32 bytes");
      }
      byte[] out = new byte[36];
      System.arraycopy(WireSerialize.packUint32Le(item.type()), 0, out, 0, 4);
      System.arraycopy(item.hash(), 0, out, 4, 32);
      return out;
    }

    static InventoryVector deserialize(byte[] data, int offset) {
      long type = WireSerialize.unpackUint32Le(data, offset);
      byte[] hash = Arrays.copyOfRange(data, offset + 4, offset + 36);
      return new InventoryVector((int) type, hash);
    }
  }

  public static boolean hasBlockInventory(InvMessage message) {
    for (InventoryVector item : message.inventory()) {
      if (BLOCK_INVENTORY_TYPES.contains(item.type())) {
        return true;
      }
    }
    return false;
  }

  public static boolean inventoryContainsHash(InvMessage message, byte[] hash) {
    for (InventoryVector item : message.inventory()) {
      if (Arrays.equals(item.hash(), hash)) {
        return true;
      }
    }
    return false;
  }
}
