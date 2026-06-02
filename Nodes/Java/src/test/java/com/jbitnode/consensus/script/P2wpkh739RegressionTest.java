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
 * Regression anchor for testnet4 block 739 P2WPKH spend (BLOCKER_LEDGER height 739).
 *
 * <p>Tx {@code 475ff67b2f2631c6b443635951d81127dcf21898f697d5f7c31e88df836ee756}, input 0.
 */
class P2wpkh739RegressionTest {

  private static final long PREVOUT_AMOUNT = 5_000_000_000L;

  @Test
  void acceptsRealTestnet4Block739P2wpkhInput0() throws Exception {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2wpkh_739.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, 0);
    assertTrue(parsed.nextOffset() == payload.length);

    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2wpkh_739_prev_spk.hex");
    List<ScriptVerify.SpentPrevout> spentPrevouts = loadPrevoutsFixture();

    assertDoesNotThrow(
        () ->
            ScriptVerify.verifyTransactionInput(
                parsed.transaction(),
                0,
                new ScriptVerify.VerifyInputOptions(prevSpk, PREVOUT_AMOUNT, spentPrevouts)));
  }

  @Test
  void rejects739SpendWithWrongPrevoutAmount() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2wpkh_739.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2wpkh_739_prev_spk.hex");

    ScriptVerifyError error =
        assertThrows(
            ScriptVerifyError.class,
            () ->
                ScriptVerify.verifyTransactionInput(
                    tx, 0, new ScriptVerify.VerifyInputOptions(prevSpk, 1, List.of())));
    assertTrue(error.getMessage().contains("script verification failed"));
  }

  @Test
  void detectsP2wpkhScriptTemplate() {
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2wpkh_739_prev_spk.hex");
    assertTrue(ScriptTemplates.isP2wpkh(prevSpk));
    assertTrue(ScriptVerify.describeScriptPubKey(prevSpk).equals("P2WPKH"));
  }

  private static List<ScriptVerify.SpentPrevout> loadPrevoutsFixture() throws Exception {
    byte[] jsonBytes = FixtureLoader.readBytes("/fixtures/tx_p2wpkh_739_prevouts.json");
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
