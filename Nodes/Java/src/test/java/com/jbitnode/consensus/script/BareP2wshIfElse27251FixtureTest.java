package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TransactionParser;
import com.jbitnode.testutil.FixtureLoader;
import org.junit.jupiter.api.Test;

/**
 * Fixture anchor for testnet4 block 27251 P2WSH OP_IF/OP_ELSE spend (BLOCKER_LEDGER).
 *
 * <p>Tx {@code a66a655defd3f3abef44ea0ba71dd9939b4b81f894a04fc18160c9ca5e78b0a0}, three
 * inputs spend the same P2WSH program with branch selector {@code 0x01} (IF path).
 * Script verification regression: {@link P2wshIfElse27251RegressionTest}.
 */
class BareP2wshIfElse27251FixtureTest {

  static final String TXID =
      "a66a655defd3f3abef44ea0ba71dd9939b4b81f894a04fc18160c9ca5e78b0a0";
  static final long P2WSH_AMOUNT_INPUT0 = 10_000L;

  @Test
  void fixtureDocumentsExpectedFields() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2wsh_ifelse_27251.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, 0);
    assertTrue(parsed.nextOffset() == payload.length);

    Transaction tx = parsed.transaction();
    assertEquals(3, tx.inputs().size());
    assertEquals(3, tx.outputs().size());
    assertEquals(3, tx.witness().size());

    for (var stack : tx.witness()) {
      assertEquals(3, stack.size());
    }

    byte[] p2wshSpk = FixtureLoader.readHex("/fixtures/tx_p2wsh_ifelse_27251_prev_spk.hex");
    assertEquals(34, p2wshSpk.length);
    assertEquals(0x00, p2wshSpk[0] & 0xFF);
    assertEquals(0x20, p2wshSpk[1] & 0xFF);

    assertEquals(71, FixtureLoader.readHex("/fixtures/tx_p2wsh_ifelse_27251_witness_input0_0.hex").length);
    assertEquals(0x01, FixtureLoader.readHex("/fixtures/tx_p2wsh_ifelse_27251_witness_input0_1.hex")[0] & 0xFF);
    assertEquals(
        143, FixtureLoader.readHex("/fixtures/tx_p2wsh_ifelse_27251_witness_script.hex").length);
    assertEquals(0x63, FixtureLoader.readHex("/fixtures/tx_p2wsh_ifelse_27251_witness_script.hex")[0] & 0xFF);
  }
}
