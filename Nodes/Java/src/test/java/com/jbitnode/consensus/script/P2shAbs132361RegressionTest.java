package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TransactionParser;
import com.jbitnode.testutil.FixtureLoader;
import com.jbitnode.util.Hex;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;

/** Regression for testnet4 block 132361 P2SH redeem with OP_ABS (0x90). */
class P2shAbs132361RegressionTest {

  @Test
  void fixtureDocumentsExpectedRedeemScript() throws Exception {
    Map<String, Object> meta =
        new ObjectMapper()
            .readValue(
                FixtureLoader.readBytes("/fixtures/tx_p2sh_abs_132361_meta.json"),
                new TypeReference<>() {});
    assertEquals(
        "OP_2DUP OP_EQUAL OP_NOT OP_VERIFY OP_ABS OP_SWAP OP_ABS OP_EQUAL",
        meta.get("redeem_script_asm"));
    byte[] redeemScript = FixtureLoader.readHex("/fixtures/tx_p2sh_abs_132361_redeem_script.hex");
    assertEquals(OpCodes.OP_ABS, redeemScript[4] & 0xff);
    assertEquals(OpCodes.OP_ABS, redeemScript[6] & 0xff);
  }

  @Test
  void acceptsRealTestnet4Block132361P2shInput0() throws Exception {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2sh_abs_132361.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2sh_abs_132361_prev_spk.hex");
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
    byte[] jsonBytes = FixtureLoader.readBytes("/fixtures/tx_p2sh_abs_132361_prevouts.json");
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
