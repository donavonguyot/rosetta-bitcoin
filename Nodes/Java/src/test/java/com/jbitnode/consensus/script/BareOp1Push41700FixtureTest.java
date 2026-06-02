package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TransactionParser;
import com.jbitnode.testutil.FixtureLoader;
import com.jbitnode.util.Hex;
import org.junit.jupiter.api.Test;

/** Fixture anchor for testnet4 block 41700 bare OP_1 + push spend. */
class BareOp1Push41700FixtureTest {

  static final String TXID =
      "4a89d5d1568b5cbcb4118559cb65d2357657d361a41cd96b14e74ed3d065975c";
  static final String PREV_TXID =
      "cedcdf44fba328c4da7077cac914b490a1af40acecf74ca666af6b0313c8e613";

  @Test
  void fixtureDocumentsExpectedFields() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_bare_op1_push_41700.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, 0);
    assertTrue(parsed.nextOffset() == payload.length);

    Transaction tx = parsed.transaction();
    assertEquals(1, tx.inputs().size());
    assertEquals(0, tx.inputs().getFirst().scriptSig().length);
    assertTrue(tx.witness().isEmpty() || tx.witness().getFirst().isEmpty());

    byte[] bareSpk = FixtureLoader.readHex("/fixtures/tx_bare_op1_push_41700_prev_spk.hex");
    assertArrayEquals(Hex.decode("51024e73"), bareSpk);
    assertTrue(ScriptTemplates.isBareOpN(bareSpk));
    assertEquals(0, FixtureLoader.readHex("/fixtures/tx_bare_op1_push_41700_scriptsig.hex").length);
  }
}
