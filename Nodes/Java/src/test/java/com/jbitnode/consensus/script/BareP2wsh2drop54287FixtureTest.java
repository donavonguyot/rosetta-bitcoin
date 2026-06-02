package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TransactionParser;
import com.jbitnode.testutil.FixtureLoader;
import com.jbitnode.util.Hex;
import org.junit.jupiter.api.Test;

/** Fixture anchor for testnet4 block 54287 P2WSH {@code OP_2DROP} witness spend (BLOCKER_LEDGER). */
class BareP2wsh2drop54287FixtureTest {

  static final String TXID =
      "9281b53ec58f80387161566838fb7bf54c2412bb7b59e150ae78ff5f5a413d0c";
  static final String PREV_SPK =
      "002098836c6761bf75dcbf74729b4a245c61cce68e89039e38ce2a389d3f23656038";
  static final String WITNESS_SCRIPT =
      "6da9140bfbcadae145d870428db173412d2d860b9acf5e87";

  @Test
  void fixtureDocumentsExpectedFields() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2wsh_2drop_54287.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, 0);
    assertTrue(parsed.nextOffset() == payload.length);

    Transaction tx = parsed.transaction();
    assertEquals(1, tx.inputs().size());
    assertEquals(0, tx.inputs().getFirst().scriptSig().length);
    assertEquals(1, tx.witness().size());
    assertEquals(4, tx.witness().getFirst().size());

    assertArrayEquals(
        Hex.decode(PREV_SPK), FixtureLoader.readHex("/fixtures/tx_p2wsh_2drop_54287_prev_spk.hex"));
    assertArrayEquals(
        Hex.decode(WITNESS_SCRIPT),
        FixtureLoader.readHex("/fixtures/tx_p2wsh_2drop_54287_witness_script.hex"));
    assertEquals((byte) OpCodes.OP_2DROP, FixtureLoader.readHex("/fixtures/tx_p2wsh_2drop_54287_witness_script.hex")[0]);
  }
}
