package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TransactionParser;
import com.jbitnode.testutil.FixtureLoader;
import com.jbitnode.util.Hex;
import org.junit.jupiter.api.Test;

/** Fixture anchor for testnet4 block 46599 P2TR script-path spend (BLOCKER_LEDGER). */
class BareP2trScriptPath46599FixtureTest {

  static final String TXID =
      "d16704313ed3cd64f082c92b40d72ccf5ede213f739c3f217caf59f1ca6c962f";
  static final String PREV_SPK =
      "5120a23f913d1fc28f07abbcc72218ed00e0d149287b9e86187e54b0c6340ce584b3";
  static final String INTERNAL_KEY =
      "bafdef4404480c84301404bbf6dab8bdb609276b04604d0b593471387e8a4f6b";

  @Test
  void fixtureDocumentsExpectedFields() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2tr_scriptpath_46599.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, 0);
    assertTrue(parsed.nextOffset() == payload.length);

    Transaction tx = parsed.transaction();
    assertEquals(1, tx.inputs().size());
    assertEquals(0, tx.inputs().getFirst().scriptSig().length);
    assertEquals(1, tx.witness().size());
    assertEquals(3, tx.witness().getFirst().size());

    assertArrayEquals(
        Hex.decode(PREV_SPK),
        FixtureLoader.readHex("/fixtures/tx_p2tr_scriptpath_46599_prev_spk.hex"));
    assertEquals(64, FixtureLoader.readHex("/fixtures/tx_p2tr_scriptpath_46599_witness_0.hex").length);
    assertEquals(199, FixtureLoader.readHex("/fixtures/tx_p2tr_scriptpath_46599_tapscript.hex").length);
    assertEquals(33, FixtureLoader.readHex("/fixtures/tx_p2tr_scriptpath_46599_control_block.hex").length);

    byte[] control = FixtureLoader.readHex("/fixtures/tx_p2tr_scriptpath_46599_control_block.hex");
    assertEquals((byte) 0xC0, control[0]);
    assertArrayEquals(Hex.decode(INTERNAL_KEY), java.util.Arrays.copyOfRange(control, 1, 33));

    byte[] tapscript = FixtureLoader.readHex("/fixtures/tx_p2tr_scriptpath_46599_tapscript.hex");
    assertEquals((byte) 0x20, tapscript[0]);
    assertArrayEquals(Hex.decode(INTERNAL_KEY), java.util.Arrays.copyOfRange(tapscript, 1, 33));
  }
}
