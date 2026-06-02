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

/** Regression anchor for testnet4 block 98631 P2WSH OP_NIP witness spend (BLOCKER_LEDGER). */
class P2wshNip98631RegressionTest {

  @Test
  void acceptsRealTestnet4Block98631P2wshNipSpend() throws Exception {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2wsh_nip_98631.hex");
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
  void rejects98631SpendWithCorruptedSignature() throws Exception {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2wsh_nip_98631.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    List<ScriptVerify.SpentPrevout> spentPrevouts = loadPrevoutsFixture();

    Transaction corrupted =
        new Transaction(
            tx.version(),
            tx.inputs(),
            tx.outputs(),
            tx.lockTime(),
            tx.witness().stream()
                .map(stack -> List.of(Hex.decode("deadbeef"), stack.get(1), stack.get(2), stack.get(3)))
                .toList());

    ScriptVerifyError error =
        assertThrows(
            ScriptVerifyError.class,
            () ->
                ScriptVerify.verifyTransactionInput(
                    corrupted,
                    0,
                    new ScriptVerify.VerifyInputOptions(
                        spentPrevouts.getFirst().scriptPubKey(),
                        spentPrevouts.getFirst().amount(),
                        spentPrevouts)));
    assertTrue(error.getMessage().contains("script verification failed"));
  }

  @Test
  void witnessScriptUsesOpNipBeforeFinalChecksig() {
    byte[] witnessScript =
        FixtureLoader.readHex("/fixtures/tx_p2wsh_nip_98631_witness_script.hex");
    assertEquals(OpCodes.OP_2DUP, witnessScript[0] & 0xff);
    assertEquals(OpCodes.OP_NIP, witnessScript[witnessScript.length - 2] & 0xff);
    assertEquals(OpCodes.OP_CHECKSIG, witnessScript[witnessScript.length - 1] & 0xff);
  }

  private static List<ScriptVerify.SpentPrevout> loadPrevoutsFixture() throws Exception {
    byte[] jsonBytes = FixtureLoader.readBytes("/fixtures/tx_p2wsh_nip_98631_prevouts.json");
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
