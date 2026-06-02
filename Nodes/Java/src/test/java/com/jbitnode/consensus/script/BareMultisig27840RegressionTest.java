package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.consensus.tx.OutPoint;
import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TransactionParser;
import com.jbitnode.consensus.tx.TxIn;
import com.jbitnode.consensus.tx.TxOut;
import com.jbitnode.testutil.FixtureLoader;
import com.jbitnode.util.Hex;
import java.util.List;
import org.junit.jupiter.api.Test;

/**
 * Regression anchor for testnet4 block 27840 bare 2-of-3 multisig spend (BLOCKER_LEDGER).
 *
 * <p>Tx {@code f2b2a965cac99c85f71f8705454793183e93a47b558c485dec92c1101bdacf55}, input 0.
 * scriptPubKey is OP_2 + three uncompressed pubkeys + OP_3 OP_CHECKMULTISIG; scriptSig carries
 * OP_0 dummy and two DER signatures.
 */
class BareMultisig27840RegressionTest {

  private static final long PREVOUT_AMOUNT = 477_645L;

  @Test
  void acceptsRealTestnet4Block27840BareMultisigInput0() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_bare_multisig_27840.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, 0);
    assertTrue(parsed.nextOffset() == payload.length);

    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_bare_multisig_27840_prev_spk.hex");

    assertDoesNotThrow(
        () ->
            ScriptVerify.verifyTransactionInput(
                parsed.transaction(),
                0,
                new ScriptVerify.VerifyInputOptions(prevSpk, PREVOUT_AMOUNT)));
  }

  @Test
  void rejects27840SpendWithWrongPrevoutScriptPubKey() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_bare_multisig_27840.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    byte[] wrongSpk = new byte[] {(byte) OpCodes.OP_1};

    ScriptVerifyError error =
        assertThrows(
            ScriptVerifyError.class,
            () ->
                ScriptVerify.verifyTransactionInput(
                    tx, 0, new ScriptVerify.VerifyInputOptions(wrongSpk, PREVOUT_AMOUNT)));
    assertTrue(
        error.getMessage().contains("script verification failed")
            || error.getMessage().contains("unsupported scriptPubKey template"));
  }

  @Test
  void rejectsBareMultisigSpendWithWitnessStack() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_bare_multisig_27840.hex");
    Transaction base = TransactionParser.deserialize(payload, 0).transaction();
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_bare_multisig_27840_prev_spk.hex");
    Transaction withWitness =
        new Transaction(
            base.version(),
            base.inputs(),
            base.outputs(),
            base.lockTime(),
            List.of(List.of(new byte[] {0x01})));

    ScriptVerifyError error =
        assertThrows(
            ScriptVerifyError.class,
            () ->
                ScriptVerify.verifyTransactionInput(
                    withWitness,
                    0,
                    new ScriptVerify.VerifyInputOptions(prevSpk, PREVOUT_AMOUNT)));
    assertTrue(error.getMessage().contains("script verification failed"));
  }

  @Test
  void detectsBareMultisigScriptTemplate() {
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_bare_multisig_27840_prev_spk.hex");
    assertTrue(ScriptTemplates.isBareMultisig(prevSpk));
    assertEquals("bare_multisig", ScriptVerify.describeScriptPubKey(prevSpk));
  }

  @Test
  void bareMultisigTemplateRejectsInvalidShapes() {
    byte[] valid = FixtureLoader.readHex("/fixtures/tx_bare_multisig_27840_prev_spk.hex");
    assertTrue(ScriptTemplates.isBareMultisig(valid));
    assertTrue(!ScriptTemplates.isBareMultisig(new byte[] {(byte) (OpCodes.OP_1 + 1)}));
    assertTrue(!ScriptTemplates.isBareMultisig(new byte[] {(byte) (OpCodes.OP_1 + 1), 0x04}));
    assertTrue(
        !ScriptTemplates.isBareMultisig(
            Hex.decode("524104" + "00".repeat(65) + "53ae")));
    assertTrue(!ScriptTemplates.isBareMultisig(new byte[] {(byte) (OpCodes.OP_1 + 1), 0x21, 0x02}));
    byte[] truncated = java.util.Arrays.copyOf(valid, 3);
    assertTrue(!ScriptTemplates.isBareMultisig(truncated));
  }

  @Test
  void rejectsUnsupportedBareMultisigWithTooManyPubkeys() {
    StringBuilder script = new StringBuilder("52");
    for (int index = 0; index < 21; index++) {
      script.append("41").append("ab".repeat(65));
    }
    script.append("55ae");
    assertTrue(!ScriptTemplates.isBareMultisig(Hex.decode(script.toString())));
  }

  @Test
  void rejectsBareMultisigWhenRequiredExceedsPubkeyCount() {
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_bare_multisig_27840_prev_spk.hex");
    byte[] mutated = prevSpk.clone();
    mutated[0] = (byte) (OpCodes.OP_1 + 3);
    assertTrue(!ScriptTemplates.isBareMultisig(mutated));
  }

  @Test
  void rejectsBareMultisigWhenPubkeyCountMismatch() {
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_bare_multisig_27840_prev_spk.hex");
    byte[] mutated = prevSpk.clone();
    mutated[mutated.length - 2] = (byte) (OpCodes.OP_1 + 1);
    assertTrue(!ScriptTemplates.isBareMultisig(mutated));
  }

  @Test
  void rejectsBareMultisigMissingCheckmultisig() {
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_bare_multisig_27840_prev_spk.hex");
    byte[] truncated = java.util.Arrays.copyOf(prevSpk, prevSpk.length - 1);
    assertTrue(!ScriptTemplates.isBareMultisig(truncated));
  }

  @Test
  void rejectsBareMultisigWithTrailingBytes() {
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_bare_multisig_27840_prev_spk.hex");
    byte[] extended = new byte[prevSpk.length + 1];
    System.arraycopy(prevSpk, 0, extended, 0, prevSpk.length);
    extended[extended.length - 1] = (byte) OpCodes.OP_1;
    assertTrue(!ScriptTemplates.isBareMultisig(extended));
  }

  @Test
  void isEcdsaPubkeyCoversCompressedAndUncompressed() {
    assertTrue(ScriptTemplates.isEcdsaPubkey(Hex.decode("02" + "11".repeat(32))));
    assertTrue(ScriptTemplates.isEcdsaPubkey(Hex.decode("03" + "22".repeat(32))));
    assertTrue(ScriptTemplates.isEcdsaPubkey(Hex.decode("04" + "33".repeat(64))));
    assertTrue(!ScriptTemplates.isEcdsaPubkey(new byte[] {0x05}));
    assertTrue(!ScriptTemplates.isEcdsaPubkey(new byte[] {0x02}));
  }

  @Test
  void classifierLabelsBareMultisig() {
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_bare_multisig_27840_prev_spk.hex");
    assertEquals(
        "bare_multisig", com.jbitnode.scripts.ScriptTemplateClassifier.classify(prevSpk));
  }

  @Test
  void rejectsUnsupportedTemplateWhenNotBareMultisig() {
    byte[] nonTemplateScript = new byte[] {0x6a, 0x00};
    Transaction tx =
        new Transaction(
            1,
            List.of(new TxIn(new OutPoint(new byte[32], 0), new byte[0], 0xffff_ffffL)),
            List.of(new TxOut(1, nonTemplateScript)),
            0,
            List.of());
    ScriptVerifyError error =
        assertThrows(
            ScriptVerifyError.class,
            () ->
                ScriptVerify.verifyTransactionInput(
                    tx, 0, new ScriptVerify.VerifyInputOptions(nonTemplateScript, 1)));
    assertTrue(error.getMessage().contains("unsupported scriptPubKey template"));
  }
}
