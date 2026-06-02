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
import java.util.Map;
import org.junit.jupiter.api.Test;

/** Regression anchor for testnet4 block 63603 P2SH OP_2DUP redeem spend (BLOCKER_LEDGER). */
class P2sh2dup63603RegressionTest {

  @Test
  void acceptsRealTestnet4Block63603P2sh2dupInput0() throws Exception {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2sh_2dup_63603.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, 0);
    assertTrue(parsed.nextOffset() == payload.length);

    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2sh_2dup_63603_prev_spk.hex");
    long prevAmount = loadPrevAmount();

    assertDoesNotThrow(
        () ->
            ScriptVerify.verifyTransactionInput(
                parsed.transaction(),
                0,
                new ScriptVerify.VerifyInputOptions(prevSpk, prevAmount)));
  }

  @Test
  void rejects63603SpendWithWrongPrevoutScriptPubKey() throws Exception {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2sh_2dup_63603.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    byte[] wrongSpk = Hex.decode("a914000000000000000000000000000000000000000087");

    ScriptVerifyError error =
        assertThrows(
            ScriptVerifyError.class,
            () ->
                ScriptVerify.verifyTransactionInput(
                    tx, 0, new ScriptVerify.VerifyInputOptions(wrongSpk, loadPrevAmount())));
    assertTrue(error.getMessage().contains("script verification failed"));
  }

  @Test
  void redeemScriptUsesOp2dupBeforeAddEqualVerifyChain() {
    byte[] redeemScript =
        FixtureLoader.readHex("/fixtures/tx_p2sh_2dup_63603_redeem_script.hex");
    assertEquals(OpCodes.OP_2DUP, redeemScript[0] & 0xff);
    assertEquals(OpCodes.OP_ADD, redeemScript[1] & 0xff);
    assertEquals(OpCodes.OP_1 + 6, redeemScript[2] & 0xff);
    assertEquals(OpCodes.OP_EQUALVERIFY, redeemScript[3] & 0xff);
    assertEquals(OpCodes.OP_SUB, redeemScript[4] & 0xff);
    assertEquals(OpCodes.OP_1 + 2, redeemScript[5] & 0xff);
    assertEquals(OpCodes.OP_EQUAL, redeemScript[6] & 0xff);
  }

  private static long loadPrevAmount() throws Exception {
    byte[] jsonBytes = FixtureLoader.readBytes("/fixtures/tx_p2sh_2dup_63603_meta.json");
    Map<String, Object> meta = new ObjectMapper().readValue(jsonBytes, new TypeReference<>() {});
    return ((Number) meta.get("prev_amount_sats")).longValue();
  }
}
