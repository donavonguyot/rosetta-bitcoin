package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TransactionParser;
import com.jbitnode.testutil.FixtureLoader;
import com.jbitnode.util.Hex;
import org.junit.jupiter.api.Test;

/** Fixture anchor for testnet4 block 52024 P2TR tapscript OP_SHA256 spend (BLOCKER_LEDGER). */
class BareP2trTapscriptSha25652024FixtureTest {

  static final String TXID =
      "d57def620b54b9f2f31ca5c4356be2e79c15be29233151186c6944b65bbd663d";
  static final String PREV_SPK =
      "51208633e66a528c86ba924ac2cbe60eb53e793fead9e0df3e10982c886f102d4b64";
  static final String EXPECTED_HASH =
      "c5a0a210f3c15267e016a380d87aab38c8e8a1df9bb3a152db12df0ebf9f7d8a";

  @Test
  void fixtureDocumentsExpectedFields() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_sha256_52024.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, 0);
    assertTrue(parsed.nextOffset() == payload.length);

    Transaction tx = parsed.transaction();
    assertEquals(2, tx.inputs().size());
    assertEquals(0, tx.inputs().getFirst().scriptSig().length);
    assertEquals(2, tx.witness().size());
    assertEquals(4, tx.witness().getFirst().size());

    assertArrayEquals(
        Hex.decode(PREV_SPK), FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_sha256_52024_prev_spk.hex"));
    assertEquals(65, FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_sha256_52024_witness_0.hex").length);
    assertEquals(32, FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_sha256_52024_witness_1.hex").length);
    assertEquals(69, FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_sha256_52024_tapscript.hex").length);
    assertEquals(65, FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_sha256_52024_control_block.hex").length);

    byte[] tapscript = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_sha256_52024_tapscript.hex");
    assertEquals((byte) OpCodes.OP_SHA256, tapscript[0]);
    assertArrayEquals(Hex.decode(EXPECTED_HASH), java.util.Arrays.copyOfRange(tapscript, 2, 34));

    byte[] control = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_sha256_52024_control_block.hex");
    assertEquals((byte) 0xC0, control[0]);
  }
}
