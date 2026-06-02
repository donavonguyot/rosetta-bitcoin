package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TransactionParser;
import com.jbitnode.testutil.FixtureLoader;
import com.jbitnode.util.Hex;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;

/**
 * Regression for testnet4 block 78841 P2TR script-path tapscript spend.
 *
 * <p>Tx {@code bf0784a56eabe4ecee38125cd3734bfc9684ea217b1a77a895cc6428d08386a6}, input 1.
 * Tapscript opens with OP_MAX and reuses OP_TUCK/altstack/OP_ADD finale from 70924-style paths.
 */
class P2trTapscript78841RegressionTest {

  static final long PREVOUT_AMOUNT = 330L;

  @Test
  void fixtureDocumentsExpectedFields() {
    byte[] tapscript = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_78841_tapscript.hex");
    assertEquals(0x00, tapscript[0] & 0xFF);
    assertEquals(OpCodes.OP_MAX, tapscript[1] & 0xFF);

    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_78841.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    assertEquals(46, tx.witness().get(1).size());
    assertTrue(
        ScriptTemplates.isP2tr(
            FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_78841_prev_spk.hex")));
  }

  @Test
  void acceptsRealTestnet4Block78841TapscriptInput1() throws Exception {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_78841.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_78841_prev_spk.hex");
    List<ScriptVerify.SpentPrevout> spentPrevouts = loadPrevoutsFixture();

    assertDoesNotThrow(
        () ->
            ScriptVerify.verifyTransactionInput(
                tx,
                1,
                new ScriptVerify.VerifyInputOptions(prevSpk, PREVOUT_AMOUNT, spentPrevouts)));
  }

  private static List<ScriptVerify.SpentPrevout> loadPrevoutsFixture() throws Exception {
    byte[] jsonBytes = FixtureLoader.readBytes("/fixtures/tx_p2tr_tapscript_78841_prevouts.json");
    List<Map<String, Object>> rows = new ObjectMapper().readValue(jsonBytes, new TypeReference<>() {});
    return rows.stream()
        .map(
            row ->
                new ScriptVerify.SpentPrevout(
                    ((Number) row.get("amount")).longValue(),
                    Hex.decode((String) row.get("spk"))))
        .toList();
  }
}
