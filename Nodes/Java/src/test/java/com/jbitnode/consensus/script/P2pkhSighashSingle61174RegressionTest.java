package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TransactionParser;
import com.jbitnode.testutil.FixtureLoader;
import org.junit.jupiter.api.Test;

/**
 * Regression anchor for testnet4 block 61174 P2PKH SIGHASH_SINGLE input 1 (BLOCKER_LEDGER).
 *
 * <p>Tx {@code 4942f8db3e32bd1f114fbfb5c500e0f9cd06c3c235ffe77b07087750b86cc0ea}, input 1.
 * Three-input tx; all inputs use SIGHASH_SINGLE. Legacy sighash must emit empty placeholder
 * outputs before the signed index (Core RawSignatureHash), not prior real outputs.
 */
class P2pkhSighashSingle61174RegressionTest {

  private static final long PREVOUT_AMOUNT = 20_000L;

  @Test
  void placeholderSighashIgnoresPriorRealOutputsForInput1() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2pkh_61174.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2pkh_61174_prev_spk.hex");
    byte[] withPlaceholder = LegacySighash.legacySighash(tx, 1, prevSpk, 3);
    Transaction changedPrior =
        new Transaction(
            tx.version(),
            tx.inputs(),
            java.util.List.of(new com.jbitnode.consensus.tx.TxOut(999, new byte[] {0x52}), tx.outputs().get(1)),
            tx.lockTime(),
            tx.witness());
    byte[] withChangedPrior = LegacySighash.legacySighash(changedPrior, 1, prevSpk, 3);
    assertArrayEquals(withPlaceholder, withChangedPrior);
  }

  @Test
  void accepts61174Input1P2pkhSighashSingle() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2pkh_61174.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2pkh_61174_prev_spk.hex");

    assertDoesNotThrow(
        () ->
            ScriptVerify.verifyTransactionInput(
                tx, 1, new ScriptVerify.VerifyInputOptions(prevSpk, PREVOUT_AMOUNT)));
  }

  @Test
  void accepts61174Input2P2pkhSighashSingleOutOfRange() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2pkh_61174.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2pkh_61174_prev_spk_in2.hex");

    assertDoesNotThrow(
        () ->
            ScriptVerify.verifyTransactionInput(
                tx, 2, new ScriptVerify.VerifyInputOptions(prevSpk, 18_000L)));
  }

  @Test
  void rejects61174SpendWithTamperedSignature() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2pkh_61174.hex");
    Transaction base = TransactionParser.deserialize(payload, 0).transaction();
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2pkh_61174_prev_spk.hex");
    byte[] scriptSig = base.inputs().get(1).scriptSig().clone();
    scriptSig[10] ^= 0x01;
    Transaction tampered =
        new Transaction(
            base.version(),
            java.util.List.of(
                base.inputs().get(0),
                new com.jbitnode.consensus.tx.TxIn(
                    base.inputs().get(1).previousOutput(), scriptSig, base.inputs().get(1).sequence()),
                base.inputs().get(2)),
            base.outputs(),
            base.lockTime(),
            base.witness());

    ScriptVerifyError error =
        assertThrows(
            ScriptVerifyError.class,
            () ->
                ScriptVerify.verifyTransactionInput(
                    tampered, 1, new ScriptVerify.VerifyInputOptions(prevSpk, PREVOUT_AMOUNT)));
    assertTrue(error.getMessage().contains("script verification failed"));
  }

  @Test
  void detectsP2pkhScriptTemplate() {
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2pkh_61174_prev_spk.hex");
    assertTrue(ScriptTemplates.isP2pkh(prevSpk));
    assertEquals("P2PKH", ScriptVerify.describeScriptPubKey(prevSpk));
  }
}
