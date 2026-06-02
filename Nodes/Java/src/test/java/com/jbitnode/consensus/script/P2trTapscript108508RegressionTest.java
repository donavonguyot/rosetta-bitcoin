package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;

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
 * Regression for testnet4 block 108508 P2TR script-path spend (BLOCKER_LEDGER).
 *
 * <p>Tapscript uses OP_DEPTH OP_1SUB OP_IF with OP_CHECKSIGVERIFY / OP_CHECKSEQUENCEVERIFY branches.
 */
class P2trTapscript108508RegressionTest {

  static final long PREVOUT_AMOUNT = 1_500L;

  @Test
  void fixtureDocumentsOp1SubInTapscript() {
    byte[] tapscript = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_108508_tapscript.hex");
    boolean found = false;
    for (int i = 0; i < tapscript.length; i++) {
      if ((tapscript[i] & 0xff) == OpCodes.OP_1SUB) {
        found = true;
        break;
      }
    }
    assertEquals(true, found, "tapscript should contain OP_1SUB");
  }

  @Test
  void acceptsRealTestnet4Block108508TapscriptInput0() throws Exception {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_108508.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_108508_prev_spk.hex");
    List<ScriptVerify.SpentPrevout> spentPrevouts = loadPrevoutsFixture();

    assertDoesNotThrow(
        () ->
            ScriptVerify.verifyTransactionInput(
                tx,
                0,
                new ScriptVerify.VerifyInputOptions(prevSpk, PREVOUT_AMOUNT, spentPrevouts)));
  }

  private static List<ScriptVerify.SpentPrevout> loadPrevoutsFixture() throws Exception {
    byte[] jsonBytes = FixtureLoader.readBytes("/fixtures/tx_p2tr_tapscript_108508_prevouts.json");
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
