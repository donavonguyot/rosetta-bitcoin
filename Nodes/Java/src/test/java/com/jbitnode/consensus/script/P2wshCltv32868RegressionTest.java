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
 * Regression anchor for testnet4 block 32868 native P2WSH CLTV spend (BLOCKER_LEDGER).
 *
 * <p>Tx {@code 8add2663f689111add26c4bc52a2f6060d48e41750c143cdfa8564ac114d97dc}, input 0.
 * Witness script uses {@code OP_IF}/{@code OP_ELSE} with {@code OP_CHECKLOCKTIMEVERIFY} on the
 * ELSE branch under v0 program {@code 00201b3129860946f970569a12850caede1782d2c8163bb26e284bf3f4af1b4e5077}.
 */
class P2wshCltv32868RegressionTest {

  private static final long PREVOUT_AMOUNT = 10_000L;

  @Test
  void acceptsRealTestnet4Block32868P2wshCltvInput0() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2wsh_cltv_32868.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, 0);
    assertTrue(parsed.nextOffset() == payload.length);

    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2wsh_cltv_32868_prev_spk.hex");

    assertDoesNotThrow(
        () ->
            ScriptVerify.verifyTransactionInput(
                parsed.transaction(),
                0,
                new ScriptVerify.VerifyInputOptions(prevSpk, PREVOUT_AMOUNT)));
  }

  @Test
  void rejects32868SpendWithWrongPrevoutAmount() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2wsh_cltv_32868.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2wsh_cltv_32868_prev_spk.hex");

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
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2wsh_cltv_32868_prev_spk.hex");
    assertTrue(ScriptTemplates.isP2wsh(prevSpk));
    assertEquals("P2WSH", ScriptVerify.describeScriptPubKey(prevSpk));
  }
}
