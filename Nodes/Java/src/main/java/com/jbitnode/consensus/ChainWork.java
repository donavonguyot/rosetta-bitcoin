package com.jbitnode.consensus;

import java.math.BigInteger;

/** Chainwork accumulation from compact bits (Bitcoin Core GetBlockProof semantics). */
public final class ChainWork {

  private static final BigInteger MAX_TARGET =
      BigInteger.ONE.shiftLeft(256).subtract(BigInteger.ONE);

  private ChainWork() {}

  /** Proof-of-work contribution for a header with the given compact bits. */
  public static BigInteger workForBits(long bits) {
    BigInteger target = Target.compactToTarget(bits);
    if (target.signum() == 0) {
      return BigInteger.ZERO;
    }
    return MAX_TARGET.divide(target.add(BigInteger.ONE)).add(BigInteger.ONE);
  }

  public static BigInteger accumulate(BigInteger previous, long bits) {
    return previous.add(workForBits(bits));
  }
}
