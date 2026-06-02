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
 * Regression for testnet4 block 46599 P2TR script-path spend (BLOCKER_LEDGER).
 *
 * <p>Tx {@code d16704313ed3cd64f082c92b40d72ccf5ede213f739c3f217caf59f1ca6c962f}, input 0.
 * Same tapscript template as @44295; terminal stack item {@code 0x809e…} requires Core-accurate
 * {@code castToBool} (0x80 false only as last byte).
 */
class P2trScriptPath46599RegressionTest {

  static final String TXID =
      "d16704313ed3cd64f082c92b40d72ccf5ede213f739c3f217caf59f1ca6c962f";
  static final long PREVOUT_AMOUNT = 716L;

  @Test
  void fixtureDocumentsExpectedFields() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2tr_scriptpath_46599.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, 0);
    assertTrue(parsed.nextOffset() == payload.length);

    Transaction tx = parsed.transaction();
    assertEquals(1, tx.inputs().size());
    assertEquals(1, tx.outputs().size());
    assertEquals(1, tx.witness().size());
    assertEquals(3, tx.witness().getFirst().size());

    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2tr_scriptpath_46599_prev_spk.hex");
    assertTrue(ScriptTemplates.isP2tr(prevSpk));
    assertEquals("P2TR", ScriptVerify.describeScriptPubKey(prevSpk));

    assertEquals(64, FixtureLoader.readHex("/fixtures/tx_p2tr_scriptpath_46599_witness_0.hex").length);
    assertEquals(
        199, FixtureLoader.readHex("/fixtures/tx_p2tr_scriptpath_46599_tapscript.hex").length);
    assertEquals(
        33, FixtureLoader.readHex("/fixtures/tx_p2tr_scriptpath_46599_control_block.hex").length);

    byte[] tapscript = FixtureLoader.readHex("/fixtures/tx_p2tr_scriptpath_46599_tapscript.hex");
    assertEquals(OpCodes.OP_NIP, tapscript[tapscript.length - 1] & 0xFF);
  }

  @Test
  void acceptsRealTestnet4Block46599ScriptPathInput0() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2tr_scriptpath_46599.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2tr_scriptpath_46599_prev_spk.hex");
    List<ScriptVerify.SpentPrevout> spentPrevouts =
        List.of(new ScriptVerify.SpentPrevout(PREVOUT_AMOUNT, prevSpk));

    assertDoesNotThrow(
        () ->
            ScriptVerify.verifyTransactionInput(
                tx, 0, new ScriptVerify.VerifyInputOptions(prevSpk, PREVOUT_AMOUNT, spentPrevouts)));
  }

  @Test
  void rejects46599SpendWithoutSpentPrevouts() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2tr_scriptpath_46599.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2tr_scriptpath_46599_prev_spk.hex");

    ScriptVerifyError error =
        assertThrows(
            ScriptVerifyError.class,
            () ->
                ScriptVerify.verifyTransactionInput(
                    tx, 0, new ScriptVerify.VerifyInputOptions(prevSpk, PREVOUT_AMOUNT)));
    assertTrue(error.getMessage().contains("script verification failed"));
  }
}
