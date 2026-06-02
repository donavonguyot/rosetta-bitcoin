package com.jbitnode.consensus;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.chain.Genesis;
import com.jbitnode.messages.BlockHeaderCodec;
import com.jbitnode.sync.HeaderValidator;
import java.math.BigInteger;
import org.junit.jupiter.api.Test;

class TargetTest {

  @Test
  void compactToTargetMatchesGenesisBits() {
    BigInteger target = Target.compactToTarget(Genesis.TESTNET4.bits());
    assertTrue(target.signum() > 0);
  }

  @Test
  void rejectsZeroMantissa() {
    assertThrows(HeaderValidationException.class, () -> Target.compactToTarget(0x01000000));
  }
}

class ChainWorkTest {

  @Test
  void workIncreasesWithValidBits() {
    BigInteger genesisWork = ChainWork.workForBits(Genesis.TESTNET4.bits());
    assertTrue(genesisWork.signum() > 0);
    BigInteger accumulated = ChainWork.accumulate(BigInteger.ZERO, Genesis.TESTNET4.bits());
    assertEquals(genesisWork, accumulated);
  }
}

class HeaderValidatorTest {

  @Test
  void validatesGenesisPrevAndPow() {
    HeaderValidator.validateHeader(
        Genesis.TESTNET4, new byte[32], BigInteger.ZERO);
    assertTrue(HeaderValidator.headerMeetsTarget(Genesis.TESTNET4));
  }

  @Test
  void rejectsBadPrevHash() {
    BlockHeader bad =
        new BlockHeader(
            1,
            new byte[32],
            Genesis.TESTNET4.merkleRoot(),
            Genesis.TESTNET4.timestamp() + 1,
            Genesis.TESTNET4.bits(),
            1);
    assertThrows(
        HeaderValidationException.class,
        () ->
            HeaderValidator.validateHeader(
                bad, BlockHeaderCodec.blockHash(Genesis.TESTNET4), BigInteger.ONE));
  }

  @Test
  void rejectsBadPow() {
    BlockHeader bad =
        new BlockHeader(
            1,
            BlockHeaderCodec.blockHash(Genesis.TESTNET4),
            new byte[32],
            Genesis.TESTNET4.timestamp() + 1,
            Genesis.TESTNET4.bits(),
            1);
    assertFalse(HeaderValidator.headerMeetsTarget(bad));
    assertThrows(
        HeaderValidationException.class,
        () ->
            HeaderValidator.validateHeader(
                bad,
                BlockHeaderCodec.blockHash(Genesis.TESTNET4),
                HeaderValidator.chainWorkForHeader(Genesis.TESTNET4)));
  }
}
