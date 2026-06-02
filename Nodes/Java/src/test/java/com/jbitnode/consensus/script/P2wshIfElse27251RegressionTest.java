package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TransactionParser;
import com.jbitnode.testutil.FixtureLoader;
import com.jbitnode.util.Hex;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;

/**
 * Regression anchor for testnet4 block 27251 P2WSH IF/ELSE multisig spend (BLOCKER_LEDGER).
 *
 * <p>Tx {@code a66a655defd3f3abef44ea0ba71dd9939b4b81f894a04fc18160c9ca5e78b0a0}. Witness script
 * uses {@code OP_IF} single-sig / {@code OP_ELSE} 2-of-3 {@code OP_CHECKMULTISIG}; branch selector
 * {@code 0x01} on stack takes the IF branch.
 */
class P2wshIfElse27251RegressionTest {

  @Test
  void acceptsRealTestnet4Block27251P2wshIfElseAllInputs() throws Exception {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2wsh_ifelse_27251.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, 0);
    assertTrue(parsed.nextOffset() == payload.length);

    List<ScriptVerify.SpentPrevout> spentPrevouts = loadPrevoutsFixture();
    Transaction tx = parsed.transaction();

    for (int inputIndex = 0; inputIndex < spentPrevouts.size(); inputIndex++) {
      ScriptVerify.SpentPrevout prevout = spentPrevouts.get(inputIndex);
      int index = inputIndex;
      assertDoesNotThrow(
          () ->
              ScriptVerify.verifyTransactionInput(
                  tx,
                  index,
                  new ScriptVerify.VerifyInputOptions(
                      prevout.scriptPubKey(), prevout.amount(), spentPrevouts)));
    }
  }

  @Test
  void rejects27251SpendWithWrongPrevoutAmount() throws Exception {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2wsh_ifelse_27251.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2wsh_ifelse_27251_prev_spk.hex");
    List<ScriptVerify.SpentPrevout> spentPrevouts = loadPrevoutsFixture();

    ScriptVerifyError error =
        assertThrows(
            ScriptVerifyError.class,
            () ->
                ScriptVerify.verifyTransactionInput(
                    tx, 0, new ScriptVerify.VerifyInputOptions(prevSpk, 1, spentPrevouts)));
    assertTrue(error.getMessage().contains("script verification failed"));
  }

  @Test
  void detectsP2wshScriptTemplate() {
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2wsh_ifelse_27251_prev_spk.hex");
    assertTrue(ScriptTemplates.isP2wsh(prevSpk));
    assertEquals("P2WSH", ScriptVerify.describeScriptPubKey(prevSpk));
  }

  @Test
  void witnessScriptUsesIfElseEnvelope() {
    byte[] witnessScript = FixtureLoader.readHex("/fixtures/tx_p2wsh_ifelse_27251_witness_script.hex");
    assertEquals(OpCodes.OP_IF, witnessScript[0] & 0xff);
    assertTrue(witnessScript.length > 10);
  }

  private static List<ScriptVerify.SpentPrevout> loadPrevoutsFixture() throws Exception {
    byte[] jsonBytes = FixtureLoader.readBytes("/fixtures/tx_p2wsh_ifelse_27251_prevouts.json");
    List<Map<String, Object>> rows =
        new ObjectMapper().readValue(jsonBytes, new TypeReference<>() {});
    List<ScriptVerify.SpentPrevout> spentPrevouts = new ArrayList<>(rows.size());
    for (Map<String, Object> row : rows) {
      long amount = ((Number) row.get("amount")).longValue();
      byte[] spk = Hex.decode((String) row.get("spk"));
      spentPrevouts.add(new ScriptVerify.SpentPrevout(amount, spk));
    }
    return spentPrevouts;
  }
}
