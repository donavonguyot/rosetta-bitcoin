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
 * Regression anchor for testnet4 block 22830 P2TR script-path spend (BLOCKER_LEDGER).
 *
 * <p>Tx {@code 630725d944cb0ddba2e249f248b725d1f136fc3d698e8dc4f6be61e9103fa33c}, input 0.
 * Prevout: tx {@code 745ba1ca…} vout 0, 798 sats, P2TR {@code 5120f6b0…}.
 */
class P2trScriptPath22830RegressionTest {

  static final String TXID =
      "630725d944cb0ddba2e249f248b725d1f136fc3d698e8dc4f6be61e9103fa33c";
  static final long PREVOUT_AMOUNT = 798L;

  @Test
  void fixtureDocumentsExpectedFields() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2tr_scriptpath_22830.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, 0);
    assertTrue(parsed.nextOffset() == payload.length);

    Transaction tx = parsed.transaction();
    assertEquals(1, tx.inputs().size());
    assertEquals(1, tx.outputs().size());
    assertEquals(1, tx.witness().size());
    assertEquals(3, tx.witness().getFirst().size());

    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2tr_scriptpath_22830_prev_spk.hex");
    assertTrue(ScriptTemplates.isP2tr(prevSpk));
    assertEquals("P2TR", ScriptVerify.describeScriptPubKey(prevSpk));

    assertEquals(64, FixtureLoader.readHex("/fixtures/tx_p2tr_scriptpath_22830_witness_0.hex").length);
    assertEquals(73, FixtureLoader.readHex("/fixtures/tx_p2tr_scriptpath_22830_tapscript.hex").length);
    assertEquals(33, FixtureLoader.readHex("/fixtures/tx_p2tr_scriptpath_22830_control_block.hex").length);
  }

  @Test
  void acceptsRealTestnet4Block22830ScriptPathInput0() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2tr_scriptpath_22830.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2tr_scriptpath_22830_prev_spk.hex");
    List<ScriptVerify.SpentPrevout> spentPrevouts =
        List.of(new ScriptVerify.SpentPrevout(PREVOUT_AMOUNT, prevSpk));

    assertDoesNotThrow(
        () ->
            ScriptVerify.verifyTransactionInput(
                tx, 0, new ScriptVerify.VerifyInputOptions(prevSpk, PREVOUT_AMOUNT, spentPrevouts)));
  }

  @Test
  void rejects22830SpendWithoutSpentPrevouts() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2tr_scriptpath_22830.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2tr_scriptpath_22830_prev_spk.hex");

    ScriptVerifyError error =
        assertThrows(
            ScriptVerifyError.class,
            () ->
                ScriptVerify.verifyTransactionInput(
                    tx, 0, new ScriptVerify.VerifyInputOptions(prevSpk, PREVOUT_AMOUNT)));
    assertTrue(error.getMessage().contains("script verification failed"));
  }
}
