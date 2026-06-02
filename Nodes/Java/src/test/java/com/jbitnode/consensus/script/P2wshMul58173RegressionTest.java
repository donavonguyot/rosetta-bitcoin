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

/** Regression anchor for testnet4 block 58173 P2WSH OP_0NOTEQUAL witness spend (BLOCKER_LEDGER). */
class P2wshMul58173RegressionTest {

  @Test
  void acceptsRealTestnet4Block58173P2wshMulSpend() throws Exception {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2wsh_mul_58173.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    List<ScriptVerify.SpentPrevout> spentPrevouts = loadPrevoutsFixture();

    assertDoesNotThrow(
        () ->
            ScriptVerify.verifyTransactionInput(
                tx,
                0,
                new ScriptVerify.VerifyInputOptions(
                    spentPrevouts.getFirst().scriptPubKey(),
                    spentPrevouts.getFirst().amount(),
                    spentPrevouts)));
  }

  @Test
  void rejects58173SpendWithCorruptedSignature() throws Exception {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2wsh_mul_58173.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2wsh_mul_58173_prev_spk.hex");
    List<ScriptVerify.SpentPrevout> spentPrevouts = loadPrevoutsFixture();

    Transaction corrupted =
        new Transaction(
            tx.version(),
            tx.inputs(),
            tx.outputs(),
            tx.lockTime(),
            tx.witness().stream()
                .map(
                    stack ->
                        List.of(
                            stack.get(0),
                            stack.get(1),
                            Hex.decode("deadbeef"),
                            stack.get(3),
                            stack.get(4)))
                .toList());

    ScriptVerifyError error =
        assertThrows(
            ScriptVerifyError.class,
            () ->
                ScriptVerify.verifyTransactionInput(
                    corrupted,
                    0,
                    new ScriptVerify.VerifyInputOptions(
                        prevSpk, spentPrevouts.getFirst().amount(), spentPrevouts)));
    assertTrue(error.getMessage().contains("script verification failed"));
  }

  @Test
  void witnessScriptUsesOp0NotEqualAfterSize() {
    byte[] witnessScript = FixtureLoader.readHex("/fixtures/tx_p2wsh_mul_58173_witness_script.hex");
    assertEquals(OpCodes.OP_SIZE, witnessScript[72] & 0xff);
    assertEquals(OpCodes.OP_0NOTEQUAL, witnessScript[73] & 0xff);
    assertEquals(OpCodes.OP_0NOTEQUAL, witnessScript[113] & 0xff);
  }

  private static List<ScriptVerify.SpentPrevout> loadPrevoutsFixture() throws Exception {
    byte[] jsonBytes = FixtureLoader.readBytes("/fixtures/tx_p2wsh_mul_58173_prevouts.json");
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
