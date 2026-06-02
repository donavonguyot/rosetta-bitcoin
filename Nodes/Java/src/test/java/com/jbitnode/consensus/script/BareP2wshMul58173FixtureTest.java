package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TransactionParser;
import com.jbitnode.testutil.FixtureLoader;
import com.jbitnode.util.Hex;
import org.junit.jupiter.api.Test;

/** Fixture anchor for testnet4 block 58173 P2WSH OP_0NOTEQUAL witness spend (BLOCKER_LEDGER). */
class BareP2wshMul58173FixtureTest {

  static final String PREV_SPK =
      "0020bf25d8d9e80fb053af13bc24117ea4841e38483bdc87bf2058e474f33bc4d049";

  @Test
  void fixtureDocumentsExpectedFields() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2wsh_mul_58173.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, 0);
    assertTrue(parsed.nextOffset() == payload.length);

    Transaction tx = parsed.transaction();
    assertEquals(2, tx.version());
    assertEquals(3L, tx.inputs().getFirst().sequence());
    assertEquals(1, tx.witness().size());
    assertEquals(5, tx.witness().getFirst().size());

    assertArrayEquals(
        Hex.decode(PREV_SPK), FixtureLoader.readHex("/fixtures/tx_p2wsh_mul_58173_prev_spk.hex"));
    byte[] witnessScript = FixtureLoader.readHex("/fixtures/tx_p2wsh_mul_58173_witness_script.hex");
    assertEquals((byte) OpCodes.OP_0NOTEQUAL, witnessScript[73]);
    assertEquals((byte) OpCodes.OP_0NOTEQUAL, witnessScript[113]);
  }
}
