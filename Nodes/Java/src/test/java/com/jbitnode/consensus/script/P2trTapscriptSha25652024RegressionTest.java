package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TransactionParser;
import com.jbitnode.testutil.FixtureLoader;
import com.jbitnode.util.Hex;
import java.util.List;
import org.junit.jupiter.api.Test;

/**
 * Regression for testnet4 block 52024 P2TR script-path tapscript {@code OP_SHA256} hashlock spend
 * (BLOCKER_LEDGER).
 *
 * <p>Tx {@code d57def620b54b9f2f31ca5c4356be2e79c15be29233151186c6944b65bbd663d}, input 0. Witness
 * stack len 4: 65B Schnorr sig, 32B preimage, tapscript, 33-byte control block.
 *
 * <p>Tapscript: {@code OP_SHA256} hash {@code OP_EQUALVERIFY} x-only key {@code OP_CHECKSIG}.
 */
class P2trTapscriptSha25652024RegressionTest {

  static final String TXID =
      "d57def620b54b9f2f31ca5c4356be2e79c15be29233151186c6944b65bbd663d";
  static final long PREVOUT0_AMOUNT = 1_200_000L;
  static final long PREVOUT1_AMOUNT = 100_000_000L;

  @Test
  void fixtureDocumentsExpectedFields() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_sha256_52024.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, 0);
    assertTrue(parsed.nextOffset() == payload.length);

    Transaction tx = parsed.transaction();
    assertEquals(2, tx.inputs().size());
    assertEquals(2, tx.witness().size());
    assertEquals(4, tx.witness().getFirst().size());

    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_sha256_52024_prev_spk.hex");
    assertTrue(ScriptTemplates.isP2tr(prevSpk));
    assertEquals("P2TR", ScriptVerify.describeScriptPubKey(prevSpk));

    byte[] tapscript = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_sha256_52024_tapscript.hex");
    assertEquals(OpCodes.OP_SHA256, tapscript[0] & 0xFF);
    assertEquals(OpCodes.OP_EQUALVERIFY, tapscript[34] & 0xFF);
    assertEquals(OpCodes.OP_CHECKSIG, tapscript[tapscript.length - 1] & 0xFF);
  }

  @Test
  void acceptsRealTestnet4Block52024TapscriptSha256Input0() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_sha256_52024.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    byte[] prevSpk0 = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_sha256_52024_prev_spk.hex");
    byte[] prevSpk1 = Hex.decode("0014fd641852669905e0191fc95a1881fb73952b5716");
    List<ScriptVerify.SpentPrevout> spentPrevouts =
        List.of(
            new ScriptVerify.SpentPrevout(PREVOUT0_AMOUNT, prevSpk0),
            new ScriptVerify.SpentPrevout(PREVOUT1_AMOUNT, prevSpk1));

    assertDoesNotThrow(
        () ->
            ScriptVerify.verifyTransactionInput(
                tx,
                0,
                new ScriptVerify.VerifyInputOptions(prevSpk0, PREVOUT0_AMOUNT, spentPrevouts)));
  }

  @Test
  void rejects52024SpendWithoutSpentPrevouts() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_sha256_52024.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    byte[] prevSpk0 = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_sha256_52024_prev_spk.hex");

    ScriptVerifyError error =
        assertThrows(
            ScriptVerifyError.class,
            () ->
                ScriptVerify.verifyTransactionInput(
                    tx, 0, new ScriptVerify.VerifyInputOptions(prevSpk0, PREVOUT0_AMOUNT)));
    assertTrue(error.getMessage().contains("script verification failed"));
  }
}
