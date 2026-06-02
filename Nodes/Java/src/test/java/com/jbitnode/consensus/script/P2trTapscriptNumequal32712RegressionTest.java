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
 * Regression for testnet4 block 32712 P2TR tapscript {@code OP_NUMEQUAL} 2-of-3
 * (BLOCKER_LEDGER).
 *
 * <p>Tx {@code 6b586a4f831e267749a3c2e50b866fe5badb582d3d388ea636669cbdc13acd94}, input 0.
 * Tapscript: CHECKSIG + CHECKSIGADD + CHECKSIGADD + OP_2 OP_NUMEQUAL.
 *
 * <p>Python scout: {@code
 * test_real_testnet4_block32712_p2tr_tapscript_checksigadd_2of3_numequal_accepted}.
 */
class P2trTapscriptNumequal32712RegressionTest {

  static final String TXID =
      "6b586a4f831e267749a3c2e50b866fe5badb582d3d388ea636669cbdc13acd94";
  static final long P2TR_AMOUNT = 50_000L;

  @Test
  void acceptsRealTestnet4Block32712TapscriptNumequalInput0() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_numequal_32712.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    byte[] prevSpk =
        FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_numequal_32712_prev_spk.hex");
    List<ScriptVerify.SpentPrevout> spentPrevouts =
        List.of(new ScriptVerify.SpentPrevout(P2TR_AMOUNT, prevSpk));

    assertDoesNotThrow(
        () ->
            ScriptVerify.verifyTransactionInput(
                tx, 0, new ScriptVerify.VerifyInputOptions(prevSpk, P2TR_AMOUNT, spentPrevouts)));
  }

  @Test
  void rejects32712SpendWithoutSpentPrevouts() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_numequal_32712.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    byte[] prevSpk =
        FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_numequal_32712_prev_spk.hex");

    ScriptVerifyError error =
        assertThrows(
            ScriptVerifyError.class,
            () ->
                ScriptVerify.verifyTransactionInput(
                    tx, 0, new ScriptVerify.VerifyInputOptions(prevSpk, P2TR_AMOUNT)));
    assertTrue(error.getMessage().contains("script verification failed"));
  }

  @Test
  void fixtureDocumentsExpectedFields() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_numequal_32712.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, 0);
    assertTrue(parsed.nextOffset() == payload.length);

    Transaction tx = parsed.transaction();
    assertEquals(1, tx.inputs().size());
    assertEquals(1, tx.outputs().size());
    assertEquals(1, tx.witness().size());
    assertEquals(5, tx.witness().getFirst().size());

    byte[] tapscript =
        FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_numequal_32712_tapscript.hex");
    assertEquals(0x9c, tapscript[tapscript.length - 1] & 0xFF);
  }
}
