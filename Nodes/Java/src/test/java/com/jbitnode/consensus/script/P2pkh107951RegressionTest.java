package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TransactionParser;
import com.jbitnode.consensus.tx.TxIn;
import com.jbitnode.testutil.FixtureLoader;
import org.junit.jupiter.api.Test;

/**
 * Regression anchor for testnet4 block 107951 P2PKH input 0 (BLOCKER_LEDGER).
 *
 * <p>Tx {@code e03dcb1abb013ee01a379d2fd01822ac00acb9df0a9e483a23f162bcc2787206}, input 0.
 * scriptSig pushes OP_1 before sig+pubkey; Core legacy verify allows extra stack items below
 * a true top (no SCRIPT_VERIFY_CLEANSTACK on bare P2PKH).
 */
class P2pkh107951RegressionTest {

  private static final long PREVOUT_AMOUNT = 100_000L;

  @Test
  void accepts107951Input0P2pkhExtraScriptSigStackItem() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2pkh_107951.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2pkh_107951_prev_spk.hex");

    assertDoesNotThrow(
        () ->
            ScriptVerify.verifyTransactionInput(
                tx, 0, new ScriptVerify.VerifyInputOptions(prevSpk, PREVOUT_AMOUNT)));
  }

  @Test
  void rejects107951SpendWithTamperedSignature() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2pkh_107951.hex");
    Transaction base = TransactionParser.deserialize(payload, 0).transaction();
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2pkh_107951_prev_spk.hex");
    byte[] scriptSig = base.inputs().getFirst().scriptSig().clone();
    scriptSig[4] ^= 0x01;
    Transaction tampered =
        new Transaction(
            base.version(),
            java.util.List.of(
                new TxIn(base.inputs().getFirst().previousOutput(), scriptSig, base.inputs().getFirst().sequence())),
            base.outputs(),
            base.lockTime(),
            base.witness());

    ScriptVerifyError error =
        assertThrows(
            ScriptVerifyError.class,
            () ->
                ScriptVerify.verifyTransactionInput(
                    tampered, 0, new ScriptVerify.VerifyInputOptions(prevSpk, PREVOUT_AMOUNT)));
    assertTrue(error.getMessage().contains("script verification failed"));
  }

  @Test
  void detectsP2pkhScriptTemplate() {
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2pkh_107951_prev_spk.hex");
    assertTrue(ScriptTemplates.isP2pkh(prevSpk));
    assertEquals("P2PKH", ScriptVerify.describeScriptPubKey(prevSpk));
  }
}
