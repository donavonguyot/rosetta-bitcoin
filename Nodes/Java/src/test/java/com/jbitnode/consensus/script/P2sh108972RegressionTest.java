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
 * Regression anchor for testnet4 block 108972 P2SH stack-op redeem spend (BLOCKER_LEDGER).
 *
 * <p>Tx {@code 9a3d5d60b83e3b0d0469be19e8df6510c04d6d89f7e9db14b509dbf853da79f0}, input 0.
 * scriptSig pushes five {@code OP_1} values plus redeem script
 * {@code OP_IF OP_2SWAP OP_PICK OP_2OVER OP_DEPTH OP_3DUP OP_ELSE … OP_ENDIF OP_PICK}; empty witness.
 */
class P2sh108972RegressionTest {

  private static final long PREVOUT_AMOUNT = 10_000L;

  @Test
  void acceptsRealTestnet4Block108972P2shStackOpsInput0() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2sh_108972.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, 0);
    assertTrue(parsed.nextOffset() == payload.length);

    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2sh_108972_prev_spk.hex");

    assertDoesNotThrow(
        () ->
            ScriptVerify.verifyTransactionInput(
                parsed.transaction(),
                0,
                new ScriptVerify.VerifyInputOptions(prevSpk, PREVOUT_AMOUNT)));
  }

  @Test
  void rejects108972SpendWithWrongPrevoutScriptPubKey() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2sh_108972.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    byte[] wrongSpk = FixtureLoader.readHex("/fixtures/tx_p2sh_82112_prev_spk.hex");

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
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2sh_108972_prev_spk.hex");
    assertTrue(ScriptTemplates.isP2sh(prevSpk));
    assertEquals("P2SH", ScriptVerify.describeScriptPubKey(prevSpk));
  }
}
