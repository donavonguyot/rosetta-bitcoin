package com.jbitnode.sync;

import com.jbitnode.consensus.BlockHeader;
import com.jbitnode.consensus.ChainWork;
import com.jbitnode.consensus.HeaderValidationException;
import com.jbitnode.consensus.Target;
import com.jbitnode.messages.BlockHeaderCodec;
import com.jbitnode.util.Hex;
import java.math.BigInteger;
import java.util.Arrays;

/** Validates block header prev-linkage, compact bits, PoW, and chainwork accumulation. */
public final class HeaderValidator {

  private HeaderValidator() {}

  public static void validateHeader(
      BlockHeader header, byte[] expectedPrevInternal, BigInteger previousChainWork) {
    if (!Arrays.equals(header.prevBlock(), expectedPrevInternal)) {
      throw new HeaderValidationException(
          "prev_block mismatch: expected "
              + Hex.encode(Hex.reverse(expectedPrevInternal))
              + ", got "
              + Hex.encode(Hex.reverse(header.prevBlock())));
    }
    validateBits(header.bits());
    if (!headerMeetsTarget(header)) {
      throw new HeaderValidationException(
          "proof of work failed for bits 0x" + Long.toHexString(header.bits()));
    }
    BigInteger nextWork = ChainWork.accumulate(previousChainWork, header.bits());
    if (nextWork.compareTo(previousChainWork) <= 0) {
      throw new HeaderValidationException("chainwork must increase");
    }
  }

  public static void validateBits(long bits) {
    Target.compactToTarget(bits);
  }

  public static boolean headerMeetsTarget(BlockHeader header) {
    try {
      BigInteger target = Target.compactToTarget(header.bits());
      if (target.signum() == 0) {
        return false;
      }
      byte[] hash = BlockHeaderCodec.blockHash(header);
      BigInteger hashInt = new BigInteger(1, Hex.reverse(hash));
      return hashInt.compareTo(target) <= 0;
    } catch (HeaderValidationException e) {
      return false;
    }
  }

  public static BigInteger chainWorkForHeader(BlockHeader header) {
    return ChainWork.workForBits(header.bits());
  }
}
