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
 * Regression for testnet4 block 67562 P2TR script-path tapscript {@code OP_HASH256} spend.
 *
 * <p>Tx {@code d3c78c53f3558feeafe22384db58b5ee1d96c5657f366b5b84cf39aedda42c6b}, input 0.
 * Witness stack len 6: two Schnorr sigs, hex preimage, branch selector, tapscript, control block.
 */
class P2trTapscriptHash25667562RegressionTest {

  static final long PREVOUT_AMOUNT = 69_597L;

  @Test
  void fixtureDocumentsExpectedFields() {
    byte[] tapscript = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_hash256_67562_tapscript.hex");
    assertEquals(OpCodes.OP_IF, tapscript[0] & 0xFF);
    assertEquals(OpCodes.OP_HASH256, tapscript[1] & 0xFF);

    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_hash256_67562.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    assertEquals(6, tx.witness().getFirst().size());
    assertTrue(ScriptTemplates.isP2tr(FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_hash256_67562_prev_spk.hex")));
  }

  @Test
  void acceptsRealTestnet4Block67562TapscriptHash256Input0() throws Exception {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_hash256_67562.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_hash256_67562_prev_spk.hex");
    List<ScriptVerify.SpentPrevout> spentPrevouts = loadPrevoutsFixture();

    assertDoesNotThrow(
        () ->
            ScriptVerify.verifyTransactionInput(
                tx,
                0,
                new ScriptVerify.VerifyInputOptions(prevSpk, PREVOUT_AMOUNT, spentPrevouts)));
  }

  private static List<ScriptVerify.SpentPrevout> loadPrevoutsFixture() throws Exception {
    byte[] jsonBytes = FixtureLoader.readBytes("/fixtures/tx_p2tr_tapscript_hash256_67562_prevouts.json");
    List<Map<String, Object>> rows = new ObjectMapper().readValue(jsonBytes, new TypeReference<>() {});
    Map<String, Object> row = rows.getFirst();
    return List.of(
        new ScriptVerify.SpentPrevout(
            ((Number) row.get("amount")).longValue(), Hex.decode((String) row.get("spk"))));
  }
}
