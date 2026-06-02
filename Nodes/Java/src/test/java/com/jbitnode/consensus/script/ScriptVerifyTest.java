package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.consensus.secp256k1.Secp256k1;
import com.jbitnode.consensus.tx.OutPoint;
import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TxIn;
import com.jbitnode.consensus.tx.TxOut;
import com.jbitnode.testutil.ScriptTestHelpers;
import com.jbitnode.util.Hex;
import java.math.BigInteger;
import java.util.List;
import org.junit.jupiter.api.Test;

class ScriptVerifyTest {

  @Test
  void p2pkhSpendRoundtrip() {
    BigInteger privateKey = BigInteger.ONE;
    byte[] pubkey = Secp256k1.testPubkeySec1(privateKey);
    byte[] prevTxid = Hex.decode("aa".repeat(32));
    ScriptTestHelpers.SignedSpend spend =
        ScriptTestHelpers.makeSignedP2pkhSpend(privateKey, prevTxid, 0, 50_000, pubkey, 49_000);
    ScriptVerify.verifyTransactionInput(
        spend.transaction(),
        0,
        new ScriptVerify.VerifyInputOptions(spend.scriptPubKey(), 50_000));
  }

  @Test
  void p2pkSpendRoundtrip() {
    BigInteger privateKey = BigInteger.ONE;
    byte[] pubkey = Secp256k1.testPubkeySec1(privateKey);
    byte[] prevTxid = Hex.decode("bb".repeat(32));
    ScriptTestHelpers.SignedSpend spend =
        ScriptTestHelpers.makeSignedP2pkSpend(privateKey, prevTxid, 0, pubkey, 49_000);
    ScriptVerify.verifyTransactionInput(
        spend.transaction(),
        0,
        new ScriptVerify.VerifyInputOptions(spend.scriptPubKey(), 50_000));
  }

  @Test
  void p2wpkhSpendRoundtrip() {
    BigInteger privateKey = BigInteger.ONE;
    byte[] pubkey = Secp256k1.testPubkeySec1(privateKey);
    byte[] prevTxid = Hex.decode("dd".repeat(32));
    ScriptTestHelpers.SignedSpend spend =
        ScriptTestHelpers.makeSignedP2wpkhSpend(privateKey, prevTxid, 0, 50_000, pubkey, 49_000);
    ScriptVerify.verifyTransactionInput(
        spend.transaction(),
        0,
        new ScriptVerify.VerifyInputOptions(spend.scriptPubKey(), 50_000));
    assertEquals("P2WPKH", ScriptVerify.describeScriptPubKey(spend.scriptPubKey()));
  }

  @Test
  void p2shP2pkhSpendRoundtrip() {
    BigInteger privateKey = BigInteger.ONE;
    byte[] pubkey = Secp256k1.testPubkeySec1(privateKey);
    byte[] prevTxid = Hex.decode("ee".repeat(32));
    ScriptTestHelpers.SignedSpend spend =
        ScriptTestHelpers.makeSignedP2shP2pkhSpend(privateKey, prevTxid, 0, 50_000, pubkey, 49_000);
    ScriptVerify.verifyTransactionInput(
        spend.transaction(),
        0,
        new ScriptVerify.VerifyInputOptions(spend.scriptPubKey(), 50_000));
    assertEquals("P2SH", ScriptVerify.describeScriptPubKey(spend.scriptPubKey()));
  }

  @Test
  void p2shP2wpkhSpendRoundtrip() {
    BigInteger privateKey = BigInteger.ONE;
    byte[] pubkey = Secp256k1.testPubkeySec1(privateKey);
    byte[] prevTxid = Hex.decode("ef".repeat(32));
    ScriptTestHelpers.SignedSpend spend =
        ScriptTestHelpers.makeSignedP2shP2wpkhSpend(privateKey, prevTxid, 0, 50_000, pubkey, 49_000);
    ScriptVerify.verifyTransactionInput(
        spend.transaction(),
        0,
        new ScriptVerify.VerifyInputOptions(spend.scriptPubKey(), 50_000));
    assertEquals("P2SH", ScriptVerify.describeScriptPubKey(spend.scriptPubKey()));
  }

  @Test
  void rejectsP2shWithNonPushScriptSig() {
    byte[] redeemScript = ScriptTemplates.p2pkhScriptCode(ScriptHash.hash160(new byte[] {0x01}));
    byte[] scriptPubKey = ScriptTestHelpers.p2shScriptPubKey(ScriptHash.hash160(redeemScript));
    Transaction tx =
        new Transaction(
            1,
            List.of(new TxIn(new OutPoint(new byte[32], 0), new byte[] {(byte) 0xac}, 0xffff_ffffL)),
            List.of(new TxOut(1, new byte[] {0x51})),
            0,
            List.of());
    assertThrows(
        ScriptVerifyError.class,
        () ->
            ScriptVerify.verifyTransactionInput(
                tx, 0, new ScriptVerify.VerifyInputOptions(scriptPubKey, 1000)));
  }

  @Test
  void rejectsP2shWhenRedeemScriptMissingFromStack() {
    byte[] redeemScript = ScriptTestHelpers.p2wpkhScriptPubKey(ScriptHash.hash160(new byte[] {0x02}));
    byte[] scriptPubKey = ScriptTestHelpers.p2shScriptPubKey(ScriptHash.hash160(redeemScript));
    byte[] wrongRedeem = ScriptTestHelpers.p2wpkhScriptPubKey(ScriptHash.hash160(new byte[] {0x03}));
    Transaction tx =
        new Transaction(
            2,
            List.of(
                new TxIn(
                    new OutPoint(new byte[32], 0),
                    ScriptTestHelpers.pushData(wrongRedeem),
                    0xffff_ffffL)),
            List.of(new TxOut(1, new byte[] {0x51})),
            0,
            List.of(List.of(new byte[] {0x01}, new byte[] {0x02})));
    assertThrows(
        ScriptVerifyError.class,
        () ->
            ScriptVerify.verifyTransactionInput(
                tx, 0, new ScriptVerify.VerifyInputOptions(scriptPubKey, 1000)));
  }

  @Test
  void rejectsP2shP2wpkhWithWrongWitnessCount() {
    BigInteger privateKey = BigInteger.ONE;
    byte[] pubkey = Secp256k1.testPubkeySec1(privateKey);
    ScriptTestHelpers.SignedSpend spend =
        ScriptTestHelpers.makeSignedP2shP2wpkhSpend(
            privateKey, Hex.decode("fa".repeat(32)), 0, 50_000, pubkey, 49_000);
    Transaction broken =
        new Transaction(
            spend.transaction().version(),
            spend.transaction().inputs(),
            spend.transaction().outputs(),
            spend.transaction().lockTime(),
            List.of(List.of(pubkey)));
    assertThrows(
        ScriptVerifyError.class,
        () ->
            ScriptVerify.verifyTransactionInput(
                broken, 0, new ScriptVerify.VerifyInputOptions(spend.scriptPubKey(), 50_000)));
  }

  @Test
  void rejectsP2trWithoutSpentPrevouts() {
    byte[] p2tr = Hex.decode("5120" + "11".repeat(32));
    Transaction tx =
        new Transaction(
            1,
            List.of(new TxIn(new OutPoint(new byte[32], 0), new byte[0], 0xffff_ffffL)),
            List.of(new TxOut(1, new byte[] {0x51})),
            0,
            List.of(List.of(Hex.decode("ab".repeat(32)))));
    ScriptVerifyError error =
        assertThrows(
            ScriptVerifyError.class,
            () ->
                ScriptVerify.verifyTransactionInput(
                    tx, 0, new ScriptVerify.VerifyInputOptions(p2tr, 1000)));
    assertTrue(error.getMessage().contains("script verification failed"));
  }

  @Test
  void describeScriptPubKeyRecognizesTemplates() {
    BigInteger privateKey = BigInteger.ONE;
    byte[] pubkey = Secp256k1.testPubkeySec1(privateKey);
    assertEquals("P2PKH", ScriptVerify.describeScriptPubKey(ScriptTestHelpers.p2pkhScriptPubKey(ScriptHash.hash160(pubkey))));
    assertEquals("P2PK", ScriptVerify.describeScriptPubKey(ScriptTestHelpers.p2pkScriptPubKey(pubkey)));
    assertEquals("P2TR", ScriptVerify.describeScriptPubKey(Hex.decode("5120" + "11".repeat(32))));
    assertEquals("P2SH", ScriptVerify.describeScriptPubKey(ScriptTestHelpers.p2shScriptPubKey(ScriptHash.hash160(new byte[] {0x01, 0x02}))));
  }

  @Test
  void rejectsOutOfRangeInputIndex() {
    Transaction tx =
        new Transaction(
            1,
            List.of(new TxIn(new OutPoint(new byte[32], 0), new byte[0], 0xffff_ffffL)),
            List.of(new TxOut(1, new byte[] {0x51})),
            0,
            List.of());
    assertThrows(
        ScriptVerifyError.class,
        () ->
            ScriptVerify.verifyTransactionInput(
                tx, 1, new ScriptVerify.VerifyInputOptions(new byte[] {0x51}, 1)));
  }

  @Test
  void bareOpNCoversOpRangeAndRejectsInvalidTemplates() {
    assertTrue(ScriptTemplates.isBareOpN(new byte[] {(byte) OpCodes.OP_1}));
    assertTrue(ScriptTemplates.isBareOpN(new byte[] {(byte) OpCodes.OP_16}));
    assertTrue(ScriptTemplates.isBareOpN(new byte[] {(byte) OpCodes.OP_1NEGATE}));
    assertEquals("bare_op_n", ScriptVerify.describeScriptPubKey(new byte[] {(byte) OpCodes.OP_1NEGATE}));
    assertTrue(ScriptTemplates.isBareOpN(new byte[] {0x51}));
    assertTrue(!ScriptTemplates.isBareOpN(new byte[] {0x51, 0x00}));
    assertTrue(!ScriptTemplates.isBareOpN(new byte[] {(byte) OpCodes.OP_0}));
    assertTrue(!ScriptTemplates.isBareOpN(Hex.decode("5120" + "11".repeat(32))));
  }
}
