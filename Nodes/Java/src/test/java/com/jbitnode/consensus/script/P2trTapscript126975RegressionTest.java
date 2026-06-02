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

/** Regression for testnet4 block 126975 P2TR script-path mega tapscript spend. */
class P2trTapscript126975RegressionTest {

  static final long PREVOUT_AMOUNT = 420L;

  @Test
  void fixtureDocumentsExpectedFields() {
    byte[] tapscript = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_126975_tapscript.hex");
    assertEquals(OpCodes.OP_1, tapscript[0] & 0xff);
    assertTrue(tapscript.length > 10_000);

    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_126975.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    assertEquals(540, tx.witness().getFirst().size());
    assertTrue(
        ScriptTemplates.isP2tr(
            FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_126975_prev_spk.hex")));
  }

  @Test
  void acceptsRealTestnet4Block126975TapscriptInput0() throws Exception {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_126975.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_126975_prev_spk.hex");
    List<ScriptVerify.SpentPrevout> spentPrevouts = loadPrevoutsFixture();

    assertDoesNotThrow(
        () ->
            ScriptVerify.verifyTransactionInput(
                tx,
                0,
                new ScriptVerify.VerifyInputOptions(prevSpk, PREVOUT_AMOUNT, spentPrevouts)));
  }

  private static List<ScriptVerify.SpentPrevout> loadPrevoutsFixture() throws Exception {
    byte[] jsonBytes = FixtureLoader.readBytes("/fixtures/tx_p2tr_tapscript_126975_prevouts.json");
    List<Map<String, Object>> rows = new ObjectMapper().readValue(jsonBytes, new TypeReference<>() {});
    return rows.stream()
        .map(
            row ->
                new ScriptVerify.SpentPrevout(
                    ((Number) row.get("amount")).longValue(), Hex.decode((String) row.get("spk"))))
        .toList();
  }
}
