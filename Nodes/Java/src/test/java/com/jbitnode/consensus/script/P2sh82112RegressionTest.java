package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TransactionParser;
import com.jbitnode.testutil.FixtureLoader;
import org.junit.jupiter.api.Test;

/**
 * Regression anchor for testnet4 block 82112 P2SH OP_NOP redeem spend (BLOCKER_LEDGER).
 *
 * <p>Tx {@code 35bf3590d157faee540dfed36421d3178691ca954d3a3d399d0f7d47927c77f6}, input 0.
 * scriptSig pushes {@code -2184 97} plus redeem script {@code OP_NOP}; empty witness.
 */
class P2sh82112RegressionTest {

  private static final long PREVOUT_AMOUNT = 4_132L;

  @Test
  void acceptsRealTestnet4Block82112P2shOpNopInput0() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2sh_82112.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, 0);
    assertTrue(parsed.nextOffset() == payload.length);

    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2sh_82112_prev_spk.hex");

    assertDoesNotThrow(
        () ->
            ScriptVerify.verifyTransactionInput(
                parsed.transaction(),
                0,
                new ScriptVerify.VerifyInputOptions(prevSpk, PREVOUT_AMOUNT)));
  }

  @Test
  void rejects82112SpendWithWrongPrevoutScriptPubKey() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2sh_82112.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    byte[] wrongSpk =
        FixtureLoader.readHex("/fixtures/tx_p2sh_add_51340_prev_spk.hex");

    ScriptVerifyError error =
        assertThrows(
            ScriptVerifyError.class,
            () ->
                ScriptVerify.verifyTransactionInput(
                    tx, 0, new ScriptVerify.VerifyInputOptions(wrongSpk, PREVOUT_AMOUNT)));
    assertTrue(error.getMessage().contains("script verification failed"));
  }

  @Test
  void detectsP2shScriptTemplate() {
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2sh_82112_prev_spk.hex");
    assertTrue(ScriptTemplates.isP2sh(prevSpk));
    assertEquals("P2SH", ScriptVerify.describeScriptPubKey(prevSpk));
  }
}
