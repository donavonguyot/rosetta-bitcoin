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
 * Regression anchor for testnet4 block 27807 P2SH IF/ELSE SHA256 hashlock spend (BLOCKER_LEDGER).
 *
 * <p>Tx {@code d1a68c8f20cc0ce8297e4f4b5ec297af1c6f98630e8105fd9d63b39c004c4ff0}, input 0. Branch
 * selector is empty push (OP_0); ELSE branch runs {@code OP_SHA256 OP_EQUALVERIFY} then {@code
 * OP_CHECKSIG}.
 */
class P2shIfElseSha25627807RegressionTest {

  private static final long PREVOUT_AMOUNT = 489_171L;

  @Test
  void acceptsRealTestnet4Block27807P2shIfElseSha256Input0() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2sh_ifelse_27807.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, 0);
    assertTrue(parsed.nextOffset() == payload.length);

    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2sh_ifelse_27807_prev_spk.hex");

    assertDoesNotThrow(
        () ->
            ScriptVerify.verifyTransactionInput(
                parsed.transaction(),
                0,
                new ScriptVerify.VerifyInputOptions(prevSpk, PREVOUT_AMOUNT)));
  }

  @Test
  void rejects27807SpendWithWrongPrevoutScriptPubKey() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2sh_ifelse_27807.hex");
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
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2sh_ifelse_27807_prev_spk.hex");
    assertTrue(ScriptTemplates.isP2sh(prevSpk));
    assertEquals("P2SH", ScriptVerify.describeScriptPubKey(prevSpk));
  }
}
