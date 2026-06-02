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
 * Regression anchor for testnet4 block 27042 native P2WSH spend (BLOCKER_LEDGER).
 *
 * <p>Tx {@code 0864a600ee15635ebb60678c1f25ea043f8470a126b0fb0d7acd2e10afd1bf33}, input 0.
 * Witness script is 2-of-2 {@code OP_CHECKMULTISIG} under BIP141 v0 program
 * {@code 0020379e4b5ccd93422995b409b9c862c8bc7fd92999bb0e92dc9649c03e8ab9fb68}.
 */
class P2wsh27042RegressionTest {

  private static final long PREVOUT_AMOUNT = 94_800L;

  @Test
  void acceptsRealTestnet4Block27042P2wshInput0() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2wsh_27042.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, 0);
    assertTrue(parsed.nextOffset() == payload.length);

    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2wsh_27042_prev_spk.hex");

    assertDoesNotThrow(
        () ->
            ScriptVerify.verifyTransactionInput(
                parsed.transaction(),
                0,
                new ScriptVerify.VerifyInputOptions(prevSpk, PREVOUT_AMOUNT)));
  }

  @Test
  void rejects27042SpendWithWrongPrevoutAmount() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2wsh_27042.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2wsh_27042_prev_spk.hex");

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
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2wsh_27042_prev_spk.hex");
    assertTrue(ScriptTemplates.isP2wsh(prevSpk));
    assertEquals("P2WSH", ScriptVerify.describeScriptPubKey(prevSpk));
  }
}
