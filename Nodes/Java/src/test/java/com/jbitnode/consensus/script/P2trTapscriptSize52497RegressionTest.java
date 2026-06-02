package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TransactionParser;
import com.jbitnode.testutil.FixtureLoader;
import java.util.List;
import org.junit.jupiter.api.Test;

/**
 * Regression for testnet4 block 52497 P2TR script-path tapscript {@code OP_SIZE} dual-hashlock
 * 2-of-2 Schnorr spend (BLOCKER_LEDGER).
 *
 * <p>Tx {@code c62c3c4c40feb1850f17ccbd33693c26d3ce83910c5a3fe5c058f30ecec8c6e7}, input 0. Witness
 * stack len 6: two 64B Schnorr sigs, stack data, 16B preimage, tapscript, control block.
 */
class P2trTapscriptSize52497RegressionTest {

  static final long PREVOUT0_AMOUNT = 1_000L;

  @Test
  void fixtureDocumentsExpectedFields() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_size_52497.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, 0);
    assertTrue(parsed.nextOffset() == payload.length);

    Transaction tx = parsed.transaction();
    assertEquals(1, tx.inputs().size());
    assertEquals(6, tx.witness().getFirst().size());

    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_size_52497_prev_spk.hex");
    assertTrue(ScriptTemplates.isP2tr(prevSpk));
    assertEquals("P2TR", ScriptVerify.describeScriptPubKey(prevSpk));

    byte[] tapscript = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_size_52497_tapscript.hex");
    assertEquals(OpCodes.OP_SHA256, tapscript[1] & 0xFF);
    assertEquals(OpCodes.OP_CHECKSIG, tapscript[tapscript.length - 1] & 0xFF);
  }

  @Test
  void acceptsRealTestnet4Block52497TapscriptSizeInput0() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_size_52497.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    byte[] prevSpk0 = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_size_52497_prev_spk.hex");
    List<ScriptVerify.SpentPrevout> spentPrevouts =
        List.of(new ScriptVerify.SpentPrevout(PREVOUT0_AMOUNT, prevSpk0));

    assertDoesNotThrow(
        () ->
            ScriptVerify.verifyTransactionInput(
                tx,
                0,
                new ScriptVerify.VerifyInputOptions(prevSpk0, PREVOUT0_AMOUNT, spentPrevouts)));
  }

  @Test
  void rejects52497SpendWithoutSpentPrevouts() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_size_52497.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    byte[] prevSpk0 = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_size_52497_prev_spk.hex");

    ScriptVerifyError error =
        assertThrows(
            ScriptVerifyError.class,
            () ->
                ScriptVerify.verifyTransactionInput(
                    tx, 0, new ScriptVerify.VerifyInputOptions(prevSpk0, PREVOUT0_AMOUNT)));
    assertTrue(error.getMessage().contains("script verification failed"));
  }
}
