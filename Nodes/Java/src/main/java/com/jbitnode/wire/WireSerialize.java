package com.jbitnode.wire;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;

/** Bitcoin wire serialization primitives (little-endian, compact size, double-SHA256). */
public final class WireSerialize {

  private WireSerialize() {}

  public static byte[] doubleSha256(byte[] data) {
    try {
      MessageDigest sha256 = MessageDigest.getInstance("SHA-256");
      byte[] first = sha256.digest(data);
      return sha256.digest(first);
    } catch (NoSuchAlgorithmException e) {
      throw new IllegalStateException("SHA-256 unavailable", e);
    }
  }

  public static byte[] messageChecksum(byte[] payload) {
    byte[] hash = doubleSha256(payload);
    byte[] checksum = new byte[4];
    System.arraycopy(hash, 0, checksum, 0, 4);
    return checksum;
  }

  public static byte[] packInt32Le(int value) {
    return ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(value).array();
  }

  public static int unpackInt32Le(byte[] data, int offset) {
    return ByteBuffer.wrap(data, offset, 4).order(ByteOrder.LITTLE_ENDIAN).getInt();
  }

  public static byte[] packUint32Le(long value) {
    return ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt((int) (value & 0xffff_ffffL)).array();
  }

  public static long unpackUint32Le(byte[] data, int offset) {
    return Integer.toUnsignedLong(
        ByteBuffer.wrap(data, offset, 4).order(ByteOrder.LITTLE_ENDIAN).getInt());
  }

  public static byte[] packInt64Le(long value) {
    return ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putLong(value).array();
  }

  public static long unpackInt64Le(byte[] data, int offset) {
    return ByteBuffer.wrap(data, offset, 8).order(ByteOrder.LITTLE_ENDIAN).getLong();
  }

  public static byte[] packUint64Le(long value) {
    return packInt64Le(value);
  }

  public static long unpackUint64Le(byte[] data, int offset) {
    return unpackInt64Le(data, offset);
  }

  public static byte[] packUint16Be(int value) {
    return ByteBuffer.allocate(2).order(ByteOrder.BIG_ENDIAN).putShort((short) value).array();
  }

  public static int unpackUint16Be(byte[] data, int offset) {
    return Short.toUnsignedInt(
        ByteBuffer.wrap(data, offset, 2).order(ByteOrder.BIG_ENDIAN).getShort());
  }

  public static byte[] writeCompactSize(long value) {
    if (value < 0xfd) {
      return new byte[] {(byte) value};
    }
    if (value <= 0xffff) {
      byte[] out = new byte[3];
      out[0] = (byte) 0xfd;
      out[1] = (byte) (value & 0xff);
      out[2] = (byte) ((value >> 8) & 0xff);
      return out;
    }
    if (value <= 0xffff_ffffL) {
      byte[] out = new byte[5];
      out[0] = (byte) 0xfe;
      ByteBuffer.wrap(out, 1, 4).order(ByteOrder.LITTLE_ENDIAN).putInt((int) value);
      return out;
    }
    byte[] out = new byte[9];
    out[0] = (byte) 0xff;
    ByteBuffer.wrap(out, 1, 8).order(ByteOrder.LITTLE_ENDIAN).putLong(value);
    return out;
  }

  public static CompactSizeResult readCompactSize(byte[] data, int offset) {
    int first = data[offset] & 0xff;
    if (first < 0xfd) {
      return new CompactSizeResult(first, offset + 1);
    }
    if (first == 0xfd) {
      int value = (data[offset + 1] & 0xff) | ((data[offset + 2] & 0xff) << 8);
      return new CompactSizeResult(value, offset + 3);
    }
    if (first == 0xfe) {
      long value = unpackUint32Le(data, offset + 1);
      return new CompactSizeResult(value, offset + 5);
    }
    long value = unpackInt64Le(data, offset + 1);
    return new CompactSizeResult(value, offset + 9);
  }

  public record CompactSizeResult(long value, int nextOffset) {}
}
