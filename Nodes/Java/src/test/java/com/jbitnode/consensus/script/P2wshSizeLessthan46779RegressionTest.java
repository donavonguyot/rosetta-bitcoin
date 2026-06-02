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
 * Regression for testnet4 block 46779 native P2WSH spend (BLOCKER_LEDGER).
 *
 * <p>Tx {@code fb9b18c782c2b45ccb77b4e22cbdf8b8cb1b8bf603289937968da52475e28aa5}, input 0.
 * Witness script {@code OP_SIZE PUSH(80) OP_LESSTHAN OP_VERIFY OP_CODESEPARATOR PUSH(33)
 * OP_CHECKSIG} with empty scriptSig.
 */
class P2wshSizeLessthan46779RegressionTest {

  private static final long PREVOUT_AMOUNT = 1143L;

  @Test
  void acceptsRealTestnet4Block46779P2wshSizeLessthanInput0() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2wsh_size_lessthan_46779.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2wsh_size_lessthan_46779_prev_spk.hex");

    assertDoesNotThrow(
        () ->
            ScriptVerify.verifyTransactionInput(
                tx, 0, new ScriptVerify.VerifyInputOptions(prevSpk, PREVOUT_AMOUNT)));
  }

  @Test
  void rejects46779SpendWithWrongPrevoutAmount() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2wsh_size_lessthan_46779.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2wsh_size_lessthan_46779_prev_spk.hex");

    ScriptVerifyError error =
        assertThrows(
            ScriptVerifyError.class,
            () ->
                ScriptVerify.verifyTransactionInput(
                    tx, 0, new ScriptVerify.VerifyInputOptions(prevSpk, 1)));
    assertTrue(error.getMessage().contains("script verification failed"));
  }

  @Test
  void detectsP2wshScriptTemplate() {
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2wsh_size_lessthan_46779_prev_spk.hex");
    assertTrue(ScriptTemplates.isP2wsh(prevSpk));
    assertEquals("P2WSH", ScriptVerify.describeScriptPubKey(prevSpk));
  }
}
