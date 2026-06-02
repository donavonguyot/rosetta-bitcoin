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
 * Regression for testnet4 block 70924 P2TR script-path tapscript spend.
 *
 * <p>Tx {@code 101d8cd4404f764295479dc7fb14f55623eb032fe8ffaab02482d99455eec5fb}, input 0.
 * Tapscript uses altstack, OP_MIN, OP_HASH160 chains, OP_PICK/TUCK/SUB/NEGATE/ADD finale arithmetic.
 */
class P2trTapscript70924RegressionTest {

  static final long PREVOUT_AMOUNT = 2_300_000L;

  @Test
  void fixtureDocumentsExpectedFields() {
    byte[] tapscript = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_70924_tapscript.hex");
    assertEquals(0x20, tapscript[0] & 0xFF);
    assertEquals(OpCodes.OP_CHECKSIGVERIFY, tapscript[33] & 0xFF);

    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_70924.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    assertEquals(139, tx.witness().getFirst().size());
    assertTrue(ScriptTemplates.isP2tr(FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_70924_prev_spk.hex")));
  }

  @Test
  void acceptsRealTestnet4Block70924TapscriptInput0() throws Exception {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_70924.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_70924_prev_spk.hex");
    List<ScriptVerify.SpentPrevout> spentPrevouts = loadPrevoutsFixture();

    assertDoesNotThrow(
        () ->
            ScriptVerify.verifyTransactionInput(
                tx,
                0,
                new ScriptVerify.VerifyInputOptions(prevSpk, PREVOUT_AMOUNT, spentPrevouts)));
  }

  private static List<ScriptVerify.SpentPrevout> loadPrevoutsFixture() throws Exception {
    byte[] jsonBytes = FixtureLoader.readBytes("/fixtures/tx_p2tr_tapscript_70924_prevouts.json");
    List<Map<String, Object>> rows = new ObjectMapper().readValue(jsonBytes, new TypeReference<>() {});
    Map<String, Object> row = rows.getFirst();
    return List.of(
        new ScriptVerify.SpentPrevout(
            ((Number) row.get("amount")).longValue(), Hex.decode((String) row.get("spk"))));
  }
}
