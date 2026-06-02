package com.jbitnode.util;

/** Hex encoding helpers for block hashes and wire payloads. */
public final class Hex {

  private Hex() {}

  public static byte[] decode(String hex) {
    if (hex.length() % 2 != 0) {
      throw new IllegalArgumentException("Odd-length hex string");
    }
    byte[] out = new byte[hex.length() / 2];
    for (int i = 0; i < out.length; i++) {
      out[i] = (byte) Integer.parseInt(hex.substring(i * 2, i * 2 + 2), 16);
    }
    return out;
  }

  public static String encode(byte[] data) {
    StringBuilder sb = new StringBuilder(data.length * 2);
    for (byte b : data) {
      sb.append(String.format("%02x", b & 0xff));
    }
    return sb.toString();
  }

  public static byte[] reverse(byte[] data) {
    byte[] out = new byte[data.length];
    for (int i = 0; i < data.length; i++) {
      out[i] = data[data.length - 1 - i];
    }
    return out;
  }
}
