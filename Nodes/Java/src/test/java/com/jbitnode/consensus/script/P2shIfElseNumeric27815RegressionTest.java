package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TransactionParser;
import com.jbitnode.testutil.FixtureLoader;
import com.jbitnode.util.Hex;
import org.junit.jupiter.api.Test;

/**
 * Regression anchor for testnet4 block 27815 P2SH IF/ELSE numeric branch spend (BLOCKER_LEDGER).
 *
 * <p>Tx {@code 2a691884927c92649b0c8759f929b931ba21d75bb21bc21f4a3b5868be0bc4d7}, input 0. Branch
 * selector is {@code OP_1}; IF branch runs {@code OP_SWAP OP_SUB OP_GREATERTHAN OP_VERIFY} comparing
 * 2024 − 2001 against 18.
 */
class P2shIfElseNumeric27815RegressionTest {

  private static final long PREVOUT_AMOUNT = 740_492L;

  @Test
  void acceptsRealTestnet4Block27815P2shIfElseNumericInput0() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2sh_ifelse_27815.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, 0);
    assertTrue(parsed.nextOffset() == payload.length);

    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2sh_ifelse_27815_prev_spk.hex");

    assertDoesNotThrow(
        () ->
            ScriptVerify.verifyTransactionInput(
                parsed.transaction(),
                0,
                new ScriptVerify.VerifyInputOptions(prevSpk, PREVOUT_AMOUNT)));
  }

  @Test
  void rejects27815SpendWithWrongPrevoutScriptPubKey() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2sh_ifelse_27815.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    byte[] wrongSpk = Hex.decode("a914000000000000000000000000000000000000000087");

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
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2sh_ifelse_27815_prev_spk.hex");
    assertTrue(ScriptTemplates.isP2sh(prevSpk));
    assertEquals("P2SH", ScriptVerify.describeScriptPubKey(prevSpk));
  }
}
