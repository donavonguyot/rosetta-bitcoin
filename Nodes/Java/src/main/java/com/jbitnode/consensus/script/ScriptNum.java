package com.jbitnode.consensus.script;

import java.util.Arrays;

/** Minimal script-number encode/decode for tapscript (BIP342). */
final class ScriptNum {

  static final int MAX_SCRIPTNUM_SIZE_LOCKTIME = 5;

  private ScriptNum() {}

  static int decodeScriptNum(byte[] item, int maxLen) {
    return (int) decodeScriptNumLong(item, maxLen);
  }

  static long decodeScriptNumLong(byte[] item, int maxLen) {
    if (item.length > maxLen) {
      throw new ScriptError("script number overflow");
    }
    if (item.length == 0) {
      return 0;
    }
    if ((item[item.length - 1] & 0x80) != 0) {
      byte[] magnitude = Arrays.copyOf(item, item.length);
      magnitude[magnitude.length - 1] &= 0x7f;
      boolean allZero = true;
      for (byte b : magnitude) {
        if (b != 0) {
          allZero = false;
          break;
        }
      }
      if (allZero) {
        return 0;
      }
      return -decodeMagnitude(magnitude);
    }
    return decodeMagnitude(item);
  }

  static byte[] encodeScriptNum(int value, int maxLen) {
    if (value == 0) {
      return new byte[0];
    }
    boolean negative = value < 0;
    int absValue = negative ? -value : value;
    byte[] magnitude = encodeMagnitude(absValue);
    if ((magnitude[magnitude.length - 1] & 0x80) != 0) {
      magnitude = Arrays.copyOf(magnitude, magnitude.length + 1);
    }
    if (negative) {
      magnitude[magnitude.length - 1] |= 0x80;
    }
    if (magnitude.length > maxLen) {
      throw new ScriptError("script number overflow");
    }
    return magnitude;
  }

  private static long decodeMagnitude(byte[] item) {
    long value = 0;
    for (int index = 0; index < item.length; index++) {
      value += (long) (item[index] & 0xff) << (8 * index);
    }
    return value;
  }

  private static byte[] encodeMagnitude(int absValue) {
    byte[] out = new byte[(Integer.SIZE - Integer.numberOfLeadingZeros(absValue) + 7) / 8];
    for (int index = 0; index < out.length; index++) {
      out[index] = (byte) (absValue >> (8 * index));
    }
    return out.length == 0 ? new byte[] {0} : out;
  }
}
