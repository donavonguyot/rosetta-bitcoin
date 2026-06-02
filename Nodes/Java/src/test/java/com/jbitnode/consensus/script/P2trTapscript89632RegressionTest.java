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
 * Regression for testnet4 block 89632 P2TR tapscript nested IF/CLTV/CSV spend with nVersion=1.
 *
 * <p>BIP65/BIP112 require CLTV/CSV to no-op on version-1 txs in tapscript (same as legacy).
 */
class P2trTapscript89632RegressionTest {

  static final long PREVOUT_AMOUNT = 59_330L;

  @Test
  void fixtureDocumentsExpectedFields() {
    byte[] tapscript = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_89632_tapscript.hex");
    assertEquals(OpCodes.OP_CHECKLOCKTIMEVERIFY, tapscript[112] & 0xff, "CLTV in inner branch");
    assertEquals(OpCodes.OP_CHECKSEQUENCEVERIFY, tapscript[150] & 0xff, "CSV in else branch");

    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_89632.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    assertEquals(1, tx.version());
    assertEquals(8, tx.witness().getFirst().size());
    assertTrue(
        ScriptTemplates.isP2tr(
            FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_89632_prev_spk.hex")));
  }

  @Test
  void acceptsRealTestnet4Block89632TapscriptInput0() throws Exception {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_89632.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_89632_prev_spk.hex");
    List<ScriptVerify.SpentPrevout> spentPrevouts = loadPrevoutsFixture();

    assertDoesNotThrow(
        () ->
            ScriptVerify.verifyTransactionInput(
                tx,
                0,
                new ScriptVerify.VerifyInputOptions(prevSpk, PREVOUT_AMOUNT, spentPrevouts)));
  }

  private static List<ScriptVerify.SpentPrevout> loadPrevoutsFixture() throws Exception {
    byte[] jsonBytes = FixtureLoader.readBytes("/fixtures/tx_p2tr_tapscript_89632_prevouts.json");
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
