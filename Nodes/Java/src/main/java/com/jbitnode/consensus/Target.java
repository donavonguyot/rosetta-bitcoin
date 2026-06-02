package com.jbitnode.consensus;

import java.math.BigInteger;

/** Compact bits (nBits) to target conversion. */
public final class Target {

  private Target() {}

  public static BigInteger compactToTarget(long bits) {
    long exponent = bits >>> 24;
    long mantissa = bits & 0x007f_ffffL;
    if (mantissa == 0) {
      throw new HeaderValidationException("Invalid compact bits: 0x" + Long.toHexString(bits));
    }
    if (exponent <= 3) {
      return BigInteger.valueOf(mantissa >> (8 * (3 - exponent)));
    }
    return BigInteger.valueOf(mantissa).shiftLeft((int) (8 * (exponent - 3)));
  }
}
