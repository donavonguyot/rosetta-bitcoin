package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TransactionParser;
import com.jbitnode.testutil.FixtureLoader;
import org.junit.jupiter.api.Test;

/**
 * Fixture anchor for testnet4 block 27840 bare 2-of-3 multisig spend (BLOCKER_LEDGER).
 *
 * <p>Tx {@code f2b2a965cac99c85f71f8705454793183e93a47b558c485dec92c1101bdacf55}, input 0
 * spends prevout tx {@code 65d9e14560f3a2e854fd835cf525640812f1f6fd133655dd6be5db263371f421}
 * vout 0 (477645 sats, bare OP_2 + 3 pubkeys + OP_3 OP_CHECKMULTISIG).
 */
class BareMultisig27840FixtureTest {

  static final String TXID =
      "f2b2a965cac99c85f71f8705454793183e93a47b558c485dec92c1101bdacf55";
  static final long PREVOUT_AMOUNT = 477_645L;

  @Test
  void fixtureDocumentsExpectedFields() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_bare_multisig_27840.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, 0);
    assertTrue(parsed.nextOffset() == payload.length);

    Transaction tx = parsed.transaction();
    assertEquals(1, tx.inputs().size());
    assertEquals(1, tx.outputs().size());
    assertTrue(tx.witness().isEmpty() || tx.witness().getFirst().isEmpty());

    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_bare_multisig_27840_prev_spk.hex");
    assertEquals(201, prevSpk.length);
    assertEquals(0x52, prevSpk[0] & 0xff);
    assertEquals(0x53, prevSpk[prevSpk.length - 2] & 0xff);
    assertEquals(OpCodes.OP_CHECKMULTISIG, prevSpk[prevSpk.length - 1] & 0xff);
    assertTrue(ScriptTemplates.isBareMultisig(prevSpk));

    byte[] scriptSig = FixtureLoader.readHex("/fixtures/tx_bare_multisig_27840_scriptsig.hex");
    assertEquals(scriptSig.length, tx.inputs().getFirst().scriptSig().length);
    assertEquals(0, FixtureLoader.readBytes("/fixtures/tx_bare_multisig_27840_scriptsig_dummy.hex").length);
    assertEquals(72, FixtureLoader.readHex("/fixtures/tx_bare_multisig_27840_scriptsig_sig1.hex").length);
    assertEquals(72, FixtureLoader.readHex("/fixtures/tx_bare_multisig_27840_scriptsig_sig2.hex").length);
    assertEquals(147, scriptSig.length);
  }
}
