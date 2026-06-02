package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import com.jbitnode.consensus.tx.OutPoint;
import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TxIn;
import com.jbitnode.consensus.tx.TxOut;
import com.jbitnode.util.Hex;
import java.util.List;
import org.junit.jupiter.api.Test;

class LegacySighashTest {

  private static Transaction twoInputTx() {
    byte[] prevA = Hex.decode("aa".repeat(32));
    byte[] prevB = Hex.decode("bb".repeat(32));
    return new Transaction(
        2,
        List.of(
            new TxIn(new OutPoint(prevA, 0), new byte[0], 0xffff_fffdL),
            new TxIn(new OutPoint(prevB, 1), new byte[0], 2)),
        List.of(new TxOut(10, new byte[] {0x51}), new TxOut(20, new byte[] {0x52})),
        0,
        List.of(List.of(), List.of()));
  }

  @Test
  void rejectsOutOfRangeInputIndex() {
    Transaction tx =
        new Transaction(
            1,
            List.of(new TxIn(new OutPoint(new byte[32], 0), new byte[0], 0xffff_ffffL)),
            List.of(new TxOut(1, new byte[] {0x51})),
            0,
            List.of());
    assertThrows(
        IllegalArgumentException.class,
        () -> LegacySighash.legacySighash(tx, 1, new byte[] {0x51}, 1));
  }

  @Test
  void sighashSingleWithoutMatchingOutputReturnsOne() {
    Transaction tx =
        new Transaction(
            1,
            List.of(new TxIn(new OutPoint(new byte[32], 0), new byte[0], 1)),
            List.of(),
            0,
            List.of());
    byte[] expected = new byte[32];
    expected[0] = 0x01;
    assertArrayEquals(expected, LegacySighash.legacySighash(tx, 0, new byte[] {0x51}, 3));
  }

  @Test
  void sighashSingleKeepsSigningInputSequence() {
    Transaction tx = twoInputTx();
    byte[] scriptCode = new byte[] {0x51};
    byte[] withSequence = LegacySighash.legacySighash(tx, 0, scriptCode, 3);
    Transaction zeroSequence =
        new Transaction(
            tx.version(),
            List.of(
                new TxIn(tx.inputs().get(0).previousOutput(), new byte[0], 0),
                tx.inputs().get(1)),
            tx.outputs(),
            tx.lockTime(),
            tx.witness());
    byte[] withoutSequence = LegacySighash.legacySighash(zeroSequence, 0, scriptCode, 3);
    assertEquals(32, withSequence.length);
    assertEquals(32, withoutSequence.length);
    // Signing input nSequence 0xfffffffd must affect the digest for SIGHASH_SINGLE.
    org.junit.jupiter.api.Assertions.assertFalse(
        java.util.Arrays.equals(withSequence, withoutSequence));
  }

  @Test
  void coversAnyoneCanPayNoneAndSingleOutputBranches() {
    Transaction tx = twoInputTx();
    byte[] scriptCode = new byte[] {0x51};
    assertEquals(32, LegacySighash.legacySighash(tx, 0, scriptCode, 0x81 | 1).length);
    assertEquals(32, LegacySighash.legacySighash(tx, 0, scriptCode, 2).length);
    assertEquals(32, LegacySighash.legacySighash(tx, 1, scriptCode, 3).length);
  }

  @Test
  void sighashSinglePlaceholderUsesNullTxOutValue() {
    assertArrayEquals(
        LegacySighash.serializeTxOut(LegacySighash.SIGHASH_SINGLE_PLACEHOLDER_OUTPUT),
        LegacySighash.serializeTxOut(new TxOut(-1, new byte[0])));
  }

  @Test
  void sighashSingleUsesEmptyPlaceholderOutputsBeforeSignedIndex() {
    Transaction tx = twoInputTx();
    byte[] scriptCode = new byte[] {0x51};
    byte[] input1 = LegacySighash.legacySighash(tx, 1, scriptCode, 3);
    // Prior outputs must not affect the digest for inputIndex > 0.
    Transaction changedPriorOutput =
        new Transaction(
            tx.version(),
            tx.inputs(),
            List.of(new TxOut(999, new byte[] {0x52}), tx.outputs().get(1)),
            tx.lockTime(),
            tx.witness());
    byte[] withChangedPriorOutput = LegacySighash.legacySighash(changedPriorOutput, 1, scriptCode, 3);
    assertArrayEquals(input1, withChangedPriorOutput);
  }

  @Test
  void sighashAllZeroesNonSigningInputSequences() {
    Transaction tx = twoInputTx();
    byte[] scriptCode = new byte[] {0x51};
    byte[] signingInput0 = LegacySighash.legacySighash(tx, 0, scriptCode, 1);
    byte[] signingInput1 = LegacySighash.legacySighash(tx, 1, scriptCode, 1);
    org.junit.jupiter.api.Assertions.assertFalse(
        java.util.Arrays.equals(signingInput0, signingInput1));
  }

  @Test
  void serializeHelpersRoundTripOutPointAndTxOut() {
    OutPoint outPoint = new OutPoint(Hex.decode("cc".repeat(32)), 7);
    byte[] serialized = LegacySighash.serializeOutPoint(outPoint);
    assertEquals(36, serialized.length);
    TxOut output = new TxOut(123, new byte[] {0x51, 0x52});
    assertEquals(1 + 8 + 2, LegacySighash.serializeTxOut(output).length);
  }
}
