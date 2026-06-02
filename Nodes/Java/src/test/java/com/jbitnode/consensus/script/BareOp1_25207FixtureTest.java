package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TransactionParser;
import com.jbitnode.testutil.FixtureLoader;
import org.junit.jupiter.api.Test;

/**
 * Fixture anchor for testnet4 block 25207 bare OP_1 spend (BLOCKER_LEDGER).
 *
 * <p>Tx {@code 23bf6f595cc12dde71239de913ea9a30fb60ef20a3a54246701a2dff16227f43},
 * input 1 spends prevout tx {@code 056aad3e…} vout 1 (1 sat, scriptPubKey {@code 51}).
 * Script verification regression lands separately in {@link ScriptVerify}.
 */
class BareOp1_25207FixtureTest {

  static final String TXID =
      "23bf6f595cc12dde71239de913ea9a30fb60ef20a3a54246701a2dff16227f43";
  static final long BARE_OP1_AMOUNT = 1L;

  @Test
  void fixtureDocumentsExpectedFields() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_op1_25207.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, 0);
    assertTrue(parsed.nextOffset() == payload.length);

    Transaction tx = parsed.transaction();
    assertEquals(6, tx.inputs().size());
    assertEquals(1, tx.outputs().size());
    assertEquals(6, tx.witness().size());
    assertEquals(1, tx.witness().getFirst().size());
    assertTrue(tx.witness().get(1).isEmpty());

    assertEquals(0, tx.inputs().get(1).scriptSig().length);
    assertEquals(0, FixtureLoader.readHex("/fixtures/tx_op1_25207_scriptsig_input1.hex").length);

    byte[] bareSpk = FixtureLoader.readHex("/fixtures/tx_op1_25207_prev_spk_input1.hex");
    assertEquals(1, bareSpk.length);
    assertEquals(0x51, bareSpk[0] & 0xFF);

    assertEquals(64, FixtureLoader.readHex("/fixtures/tx_op1_25207_witness_input0.hex").length);
  }
}
