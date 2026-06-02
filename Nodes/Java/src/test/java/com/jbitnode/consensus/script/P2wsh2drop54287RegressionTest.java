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

/** Regression anchor for testnet4 block 54287 P2WSH OP_2DROP witness spend (BLOCKER_LEDGER). */
class P2wsh2drop54287RegressionTest {

  @Test
  void acceptsRealTestnet4Block54287P2wsh2dropSpend() throws Exception {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2wsh_2drop_54287.hex");
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
  void rejects54287SpendWithCorruptedWitnessStack() throws Exception {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2wsh_2drop_54287.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2wsh_2drop_54287_prev_spk.hex");
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
                            Hex.decode("deadbeef"),
                            stack.get(1),
                            stack.get(2),
                            stack.get(3)))
                .toList());

    ScriptVerifyError error =
        assertThrows(
            ScriptVerifyError.class,
            () ->
                ScriptVerify.verifyTransactionInput(
                    corrupted,
                    0,
                    new ScriptVerify.VerifyInputOptions(prevSpk, spentPrevouts.getFirst().amount(), spentPrevouts)));
    assertTrue(error.getMessage().contains("script verification failed"));
  }

  @Test
  void witnessScriptStartsWithOp2Drop() {
    byte[] witnessScript = FixtureLoader.readHex("/fixtures/tx_p2wsh_2drop_54287_witness_script.hex");
    assertEquals(OpCodes.OP_2DROP, witnessScript[0] & 0xff);
  }

  private static List<ScriptVerify.SpentPrevout> loadPrevoutsFixture() throws Exception {
    byte[] jsonBytes = FixtureLoader.readBytes("/fixtures/tx_p2wsh_2drop_54287_prevouts.json");
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
