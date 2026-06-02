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

/** Regression for testnet4 block 82856 P2TR script-path OP_SHA1 spend. */
class P2trTapscript82856RegressionTest {

  static final long PREVOUT_AMOUNT = 1_000L;

  @Test
  void fixtureDocumentsExpectedFields() {
    byte[] tapscript = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_82856_tapscript.hex");
    assertEquals(OpCodes.OP_SHA1, tapscript[0] & 0xff);

    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_82856.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    assertEquals(3, tx.witness().getFirst().size());
    assertTrue(
        ScriptTemplates.isP2tr(
            FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_82856_prev_spk.hex")));
  }

  @Test
  void acceptsRealTestnet4Block82856TapscriptInput0() throws Exception {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_82856.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_82856_prev_spk.hex");
    List<ScriptVerify.SpentPrevout> spentPrevouts = loadPrevoutsFixture();

    assertDoesNotThrow(
        () ->
            ScriptVerify.verifyTransactionInput(
                tx,
                0,
                new ScriptVerify.VerifyInputOptions(prevSpk, PREVOUT_AMOUNT, spentPrevouts)));
  }

  private static List<ScriptVerify.SpentPrevout> loadPrevoutsFixture() throws Exception {
    byte[] jsonBytes = FixtureLoader.readBytes("/fixtures/tx_p2tr_tapscript_82856_prevouts.json");
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
