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

/** Regression for testnet4 block 82921 P2SH redeem with OP_2DUP/OP_NOT/OP_SHA1. */
class P2sh82921RegressionTest {

  @Test
  void fixtureDocumentsExpectedRedeemScript() throws Exception {
    Map<String, Object> meta =
        new ObjectMapper()
            .readValue(
                FixtureLoader.readBytes("/fixtures/tx_p2sh_82921_meta.json"),
                new TypeReference<>() {});
    assertEquals(
        "OP_2DUP OP_EQUAL OP_NOT OP_VERIFY OP_SHA1 OP_SWAP OP_SHA1 OP_EQUAL",
        meta.get("redeem_script_asm"));
    assertTrue(
        ScriptTemplates.isP2sh(FixtureLoader.readHex("/fixtures/tx_p2sh_82921_prev_spk.hex")));
  }

  @Test
  void acceptsRealTestnet4Block82921P2shInput0() throws Exception {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2sh_82921.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2sh_82921_prev_spk.hex");
    List<ScriptVerify.SpentPrevout> spentPrevouts = loadPrevoutsFixture();

    assertDoesNotThrow(
        () ->
            ScriptVerify.verifyTransactionInput(
                tx,
                0,
                new ScriptVerify.VerifyInputOptions(
                    prevSpk, spentPrevouts.getFirst().amount(), spentPrevouts)));
  }

  private static List<ScriptVerify.SpentPrevout> loadPrevoutsFixture() throws Exception {
    byte[] jsonBytes = FixtureLoader.readBytes("/fixtures/tx_p2sh_82921_prevouts.json");
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
