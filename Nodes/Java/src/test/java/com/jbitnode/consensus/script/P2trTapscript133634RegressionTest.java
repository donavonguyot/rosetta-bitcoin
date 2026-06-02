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

/** Regression for testnet4 block 133634 P2TR script-path CSV disable-flag spend. */
class P2trTapscript133634RegressionTest {

  static final long PREVOUT_AMOUNT = 5_000L;

  @Test
  void fixtureDocumentsExpectedFields() {
    byte[] tapscript = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_133634_tapscript.hex");
    assertEquals(0x05, tapscript[0] & 0xff);
    assertEquals(OpCodes.OP_CHECKSEQUENCEVERIFY, tapscript[6] & 0xff);

    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_133634.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    assertEquals(3, tx.witness().getFirst().size());
    assertTrue(
        ScriptTemplates.isP2tr(
            FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_133634_prev_spk.hex")));
  }

  @Test
  void acceptsRealTestnet4Block133634TapscriptInput0() throws Exception {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_133634.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_133634_prev_spk.hex");
    List<ScriptVerify.SpentPrevout> spentPrevouts = loadPrevoutsFixture();

    assertDoesNotThrow(
        () ->
            ScriptVerify.verifyTransactionInput(
                tx,
                0,
                new ScriptVerify.VerifyInputOptions(prevSpk, PREVOUT_AMOUNT, spentPrevouts)));
  }

  private static List<ScriptVerify.SpentPrevout> loadPrevoutsFixture() throws Exception {
    byte[] jsonBytes = FixtureLoader.readBytes("/fixtures/tx_p2tr_tapscript_133634_prevouts.json");
    List<Map<String, Object>> rows = new ObjectMapper().readValue(jsonBytes, new TypeReference<>() {});
    return rows.stream()
        .map(
            row ->
                new ScriptVerify.SpentPrevout(
                    ((Number) row.get("amount")).longValue(), Hex.decode((String) row.get("spk"))))
        .toList();
  }
}
