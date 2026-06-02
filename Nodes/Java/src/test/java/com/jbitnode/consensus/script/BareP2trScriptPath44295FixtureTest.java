package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TransactionParser;
import com.jbitnode.testutil.FixtureLoader;
import com.jbitnode.util.Hex;
import org.junit.jupiter.api.Test;

/** Fixture anchor for testnet4 block 44295 P2TR script-path spend (BLOCKER_LEDGER). */
class BareP2trScriptPath44295FixtureTest {

  static final String TXID =
      "cb835ce1d726993515c27df94a358bf327b03323fb0e82c823c1faab31b28786";
  static final String PREV_TXID =
      "2c716236616e54b1edc897107edfadf806c3e7a6728438e14a5112f4672b0dbf";
  static final String PREV_SPK =
      "5120346d44aef23b267970d8c090d8fed28e2dcf772b609f566cdc56e108ff84118a";
  static final String INTERNAL_KEY =
      "6a4465638bd9c25d0b2e9da4985ee41c97e3e755e4d6ee95977fd6c8ed633a7a";

  @Test
  void fixtureDocumentsExpectedFields() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2tr_scriptpath_44295.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, 0);
    assertTrue(parsed.nextOffset() == payload.length);

    Transaction tx = parsed.transaction();
    assertEquals(1, tx.inputs().size());
    assertEquals(0, tx.inputs().getFirst().scriptSig().length);
    assertEquals(1, tx.witness().size());
    assertEquals(3, tx.witness().getFirst().size());

    assertArrayEquals(Hex.decode(PREV_SPK), FixtureLoader.readHex("/fixtures/tx_p2tr_scriptpath_44295_prev_spk.hex"));
    assertEquals(64, FixtureLoader.readHex("/fixtures/tx_p2tr_scriptpath_44295_witness_0.hex").length);
    assertEquals(199, FixtureLoader.readHex("/fixtures/tx_p2tr_scriptpath_44295_tapscript.hex").length);
    assertEquals(33, FixtureLoader.readHex("/fixtures/tx_p2tr_scriptpath_44295_control_block.hex").length);

    byte[] control = FixtureLoader.readHex("/fixtures/tx_p2tr_scriptpath_44295_control_block.hex");
    assertEquals((byte) 0xC0, control[0]);
    assertArrayEquals(Hex.decode(INTERNAL_KEY), java.util.Arrays.copyOfRange(control, 1, 33));

    byte[] tapscript = FixtureLoader.readHex("/fixtures/tx_p2tr_scriptpath_44295_tapscript.hex");
    assertEquals((byte) 0x20, tapscript[0]);
    assertArrayEquals(Hex.decode(INTERNAL_KEY), java.util.Arrays.copyOfRange(tapscript, 1, 33));
  }
}
