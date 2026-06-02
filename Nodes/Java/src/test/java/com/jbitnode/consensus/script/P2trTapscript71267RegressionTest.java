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
 * Regression for testnet4 block 71267 P2TR script-path tapscript spend.
 *
 * <p>Tx {@code ba53adeb3f9816cbbe4a08c7440aaff989acb4d1e558cacadc44ec0d6dbe12e1}, input 0.
 * Tapscript uses OP_ROLL/OP_DEPTH/OP_ROT stack choreography with altstack and numeric compares.
 */
class P2trTapscript71267RegressionTest {

  static final long PREVOUT_AMOUNT = 42_000_000L;

  @Test
  void fixtureDocumentsExpectedFields() {
    byte[] tapscript = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_71267_tapscript.hex");
    assertEquals(0x14, tapscript[0] & 0xFF);
    assertEquals(OpCodes.OP_SWAP, tapscript[21] & 0xFF);

    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_71267.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    assertEquals(100, tx.witness().getFirst().size());
    assertTrue(
        ScriptTemplates.isP2tr(
            FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_71267_prev_spk.hex")));
  }

  @Test
  void acceptsRealTestnet4Block71267TapscriptInput0() throws Exception {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_71267.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_71267_prev_spk.hex");
    List<ScriptVerify.SpentPrevout> spentPrevouts = loadPrevoutsFixture();

    assertDoesNotThrow(
        () ->
            ScriptVerify.verifyTransactionInput(
                tx,
                0,
                new ScriptVerify.VerifyInputOptions(prevSpk, PREVOUT_AMOUNT, spentPrevouts)));
  }

  private static List<ScriptVerify.SpentPrevout> loadPrevoutsFixture() throws Exception {
    byte[] jsonBytes = FixtureLoader.readBytes("/fixtures/tx_p2tr_tapscript_71267_prevouts.json");
    List<Map<String, Object>> rows = new ObjectMapper().readValue(jsonBytes, new TypeReference<>() {});
    Map<String, Object> row = rows.getFirst();
    return List.of(
        new ScriptVerify.SpentPrevout(
            ((Number) row.get("amount")).longValue(), Hex.decode((String) row.get("spk"))));
  }
}
