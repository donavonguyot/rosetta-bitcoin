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
 * Regression for testnet4 block 44295 P2TR script-path spend ending in {@code OP_NIP}
 * (BLOCKER_LEDGER).
 *
 * <p>Tx {@code cb835ce1d726993515c27df94a358bf327b03323fb0e82c823c1faab31b28786}, input 0.
 * Witness stack len 3: 64B Schnorr sig, tapscript, 33-byte control block.
 *
 * <p>Tapscript: x-only key {@code OP_CHECKSIGVERIFY}, {@code OP_IF} envelope, trailing push +
 * {@code OP_NIP}.
 */
class P2trScriptPath44295RegressionTest {

  static final String TXID =
      "cb835ce1d726993515c27df94a358bf327b03323fb0e82c823c1faab31b28786";
  static final long PREVOUT_AMOUNT = 716L;

  @Test
  void fixtureDocumentsExpectedFields() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2tr_scriptpath_44295.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, 0);
    assertTrue(parsed.nextOffset() == payload.length);

    Transaction tx = parsed.transaction();
    assertEquals(1, tx.inputs().size());
    assertEquals(1, tx.outputs().size());
    assertEquals(1, tx.witness().size());
    assertEquals(3, tx.witness().getFirst().size());

    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2tr_scriptpath_44295_prev_spk.hex");
    assertTrue(ScriptTemplates.isP2tr(prevSpk));
    assertEquals("P2TR", ScriptVerify.describeScriptPubKey(prevSpk));

    assertEquals(64, FixtureLoader.readHex("/fixtures/tx_p2tr_scriptpath_44295_witness_0.hex").length);
    assertEquals(
        199, FixtureLoader.readHex("/fixtures/tx_p2tr_scriptpath_44295_tapscript.hex").length);
    assertEquals(
        33, FixtureLoader.readHex("/fixtures/tx_p2tr_scriptpath_44295_control_block.hex").length);

    byte[] tapscript = FixtureLoader.readHex("/fixtures/tx_p2tr_scriptpath_44295_tapscript.hex");
    assertEquals(OpCodes.OP_NIP, tapscript[tapscript.length - 1] & 0xFF);
  }

  @Test
  void acceptsRealTestnet4Block44295ScriptPathInput0() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2tr_scriptpath_44295.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2tr_scriptpath_44295_prev_spk.hex");
    List<ScriptVerify.SpentPrevout> spentPrevouts =
        List.of(new ScriptVerify.SpentPrevout(PREVOUT_AMOUNT, prevSpk));

    assertDoesNotThrow(
        () ->
            ScriptVerify.verifyTransactionInput(
                tx, 0, new ScriptVerify.VerifyInputOptions(prevSpk, PREVOUT_AMOUNT, spentPrevouts)));
  }

  @Test
  void rejects44295SpendWithoutSpentPrevouts() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2tr_scriptpath_44295.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2tr_scriptpath_44295_prev_spk.hex");

    ScriptVerifyError error =
        assertThrows(
            ScriptVerifyError.class,
            () ->
                ScriptVerify.verifyTransactionInput(
                    tx, 0, new ScriptVerify.VerifyInputOptions(prevSpk, PREVOUT_AMOUNT)));
    assertTrue(error.getMessage().contains("script verification failed"));
  }
}
