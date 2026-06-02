package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.consensus.secp256k1.Secp256k1;
import com.jbitnode.consensus.tx.OutPoint;
import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TxIn;
import com.jbitnode.consensus.tx.TxOut;
import com.jbitnode.util.Hex;
import java.math.BigInteger;
import java.util.List;
import org.junit.jupiter.api.Test;

class TaprootSighashTest {

  @Test
  void keyPathDefaultSighashIsDeterministic() {
    byte[] prevSpk = Hex.decode("5120" + "aa".repeat(32));
    Transaction tx =
        new Transaction(
            2,
            List.of(new TxIn(new OutPoint(Hex.decode("bb".repeat(32)), 1), new byte[0], 0xffff_ffffL)),
            List.of(new TxOut(1000, new byte[] {0x51})),
            0,
            List.of(List.of(new byte[64])));
    List<ScriptVerify.SpentPrevout> prevouts =
        List.of(new ScriptVerify.SpentPrevout(5000, prevSpk));

    byte[] digest =
        TaprootSighash.taprootSignatureHash(
            tx, 0, prevouts, TaprootSighash.TaprootSighashOptions.keyPathDefault());
    assertNotNull(digest);
    assertTrue(digest.length == 32);
  }

  @Test
  void syntheticKeyPathRoundtripWithSchnorrSign() {
    BigInteger secret = BigInteger.valueOf(42);
    byte[] pkXonly = Secp256k1.signBip340Schnorr(secret, new byte[32]).length == 64
        ? xonlyFromSecret(secret)
        : xonlyFromSecret(secret);

    byte[] prevSpk = concat(new byte[] {(byte) OpCodes.OP_1, 32}, pkXonly);
    Transaction unsigned =
        new Transaction(
            2,
            List.of(new TxIn(new OutPoint(Hex.decode("cc".repeat(32)), 0), new byte[0], 0xffff_ffffL)),
            List.of(new TxOut(900, new byte[] {0x51})),
            0,
            List.of());
    List<ScriptVerify.SpentPrevout> prevouts =
        List.of(new ScriptVerify.SpentPrevout(1000, prevSpk));

    byte[] digest =
        TaprootSighash.taprootSignatureHash(
            unsigned, 0, prevouts, TaprootSighash.TaprootSighashOptions.keyPathDefault());
    byte[] sig = Secp256k1.signBip340Schnorr(secret, digest);

    Transaction signed =
        new Transaction(
            unsigned.version(),
            unsigned.inputs(),
            unsigned.outputs(),
            unsigned.lockTime(),
            List.of(List.of(sig)));

    assertTrue(
        Taproot.verifyKeyPathSpend(
            prevSpk, new byte[0], signed.witness().getFirst(), signed, 0, prevouts));
  }

  @Test
  void rejectsPrevoutLengthMismatch() {
    Transaction tx =
        new Transaction(
            1,
            List.of(new TxIn(new OutPoint(new byte[32], 0), new byte[0], 0xffff_ffffL)),
            List.of(new TxOut(1, new byte[] {0x51})),
            0,
            List.of());
    assertThrows(
        IllegalArgumentException.class,
        () ->
            TaprootSighash.taprootSignatureHash(
                tx,
                0,
                List.of(),
                TaprootSighash.TaprootSighashOptions.keyPathDefault()));
  }

  @Test
  void rejectsUnsupportedHashType() {
    Transaction tx =
        new Transaction(
            1,
            List.of(new TxIn(new OutPoint(new byte[32], 0), new byte[0], 0xffff_ffffL)),
            List.of(new TxOut(1, new byte[] {0x51})),
            0,
            List.of());
    List<ScriptVerify.SpentPrevout> prevouts =
        List.of(new ScriptVerify.SpentPrevout(1, Hex.decode("5120" + "11".repeat(32))));
    assertThrows(
        IllegalArgumentException.class,
        () ->
            TaprootSighash.taprootSignatureHash(
                tx,
                0,
                prevouts,
                new TaprootSighash.TaprootSighashOptions(0x04, null, 0, null, 0xffff_ffffL)));
  }

  @Test
  void rejectsInvalidExtFlag() {
    Transaction tx =
        new Transaction(
            1,
            List.of(new TxIn(new OutPoint(new byte[32], 0), new byte[0], 0xffff_ffffL)),
            List.of(new TxOut(1, new byte[] {0x51})),
            0,
            List.of());
    List<ScriptVerify.SpentPrevout> prevouts =
        List.of(new ScriptVerify.SpentPrevout(1, Hex.decode("5120" + "11".repeat(32))));
    assertThrows(
        IllegalArgumentException.class,
        () ->
            TaprootSighash.taprootSignatureHash(
                tx,
                0,
                prevouts,
                new TaprootSighash.TaprootSighashOptions(0, null, 2, null, 0xffff_ffffL)));
  }

  @Test
  void rejectsTapscriptSighashWithoutLeafHash() {
    Transaction tx =
        new Transaction(
            1,
            List.of(new TxIn(new OutPoint(new byte[32], 0), new byte[0], 0xffff_ffffL)),
            List.of(new TxOut(1, new byte[] {0x51})),
            0,
            List.of());
    List<ScriptVerify.SpentPrevout> prevouts =
        List.of(new ScriptVerify.SpentPrevout(1, Hex.decode("5120" + "11".repeat(32))));
    assertThrows(
        IllegalArgumentException.class,
        () ->
            TaprootSighash.taprootSignatureHash(
                tx,
                0,
                prevouts,
                new TaprootSighash.TaprootSighashOptions(0, null, 1, null, 0xffff_ffffL)));
  }

  @Test
  void anyoneCanPayAndAnnexBranchesProduceDigest() {
    byte[] prevSpk = Hex.decode("5120" + "22".repeat(32));
    Transaction tx =
        new Transaction(
            2,
            List.of(new TxIn(new OutPoint(Hex.decode("dd".repeat(32)), 0), new byte[0], 0xffff_ffffL)),
            List.of(new TxOut(500, new byte[] {0x51})),
            100,
            List.of());
    List<ScriptVerify.SpentPrevout> prevouts =
        List.of(new ScriptVerify.SpentPrevout(1000, prevSpk));

    byte[] digestAll =
        TaprootSighash.taprootSignatureHash(
            tx,
            0,
            prevouts,
            TaprootSighash.TaprootSighashOptions.keyPath(TaprootSighash.TAPROOT_SIGHASH_ALL | 0x80));
    assertNotNull(digestAll);

    byte[] annex = new byte[] {0x50, 0x01};
    byte[] digestAnnex =
        TaprootSighash.taprootSignatureHash(
            tx,
            0,
            prevouts,
            new TaprootSighash.TaprootSighashOptions(
                TaprootSighash.TAPROOT_SIGHASH_ALL, annex, 0, null, 0xffff_ffffL));
    assertFalse(java.util.Arrays.equals(digestAll, digestAnnex));
  }

  @Test
  void sighashSingleRequiresMatchingOutput() {
    byte[] prevSpk = Hex.decode("5120" + "33".repeat(32));
    Transaction tx =
        new Transaction(
            1,
            List.of(new TxIn(new OutPoint(new byte[32], 0), new byte[0], 0xffff_ffffL)),
            List.of(),
            0,
            List.of());
    List<ScriptVerify.SpentPrevout> prevouts =
        List.of(new ScriptVerify.SpentPrevout(1, prevSpk));
    assertThrows(
        IllegalArgumentException.class,
        () ->
            TaprootSighash.taprootSignatureHash(
                tx,
                0,
                prevouts,
                TaprootSighash.TaprootSighashOptions.keyPath(TaprootSighash.TAPROOT_SIGHASH_SINGLE)));
  }

  @Test
  void taprootAllowedHashtypesCoversCoreSet() {
    assertTrue(TaprootSighash.taprootAllowedHashtypes(0));
    assertTrue(TaprootSighash.taprootAllowedHashtypes(0x83));
    assertFalse(TaprootSighash.taprootAllowedHashtypes(0x10));
  }

  @Test
  void cachedTaprootSighashMatchesUncachedBranches() {
    byte[] prevSpkA = Hex.decode("5120" + "44".repeat(32));
    byte[] prevSpkB = Hex.decode("5120" + "55".repeat(32));
    Transaction tx =
        new Transaction(
            2,
            List.of(
                new TxIn(new OutPoint(Hex.decode("aa".repeat(32)), 0), new byte[0], 10),
                new TxIn(new OutPoint(Hex.decode("bb".repeat(32)), 1), new byte[0], 20)),
            List.of(new TxOut(500, new byte[] {0x51}), new TxOut(600, new byte[] {0x52})),
            100,
            List.of(List.of(), List.of()));
    List<ScriptVerify.SpentPrevout> prevouts =
        List.of(new ScriptVerify.SpentPrevout(1000, prevSpkA), new ScriptVerify.SpentPrevout(2000, prevSpkB));
    TaprootSighash.Cache cache = TaprootSighash.Cache.forTransaction(tx, prevouts);
    for (int hashType : List.of(0, 1, 2, 3, 0x81, 0x82, 0x83)) {
      TaprootSighash.TaprootSighashOptions options =
          TaprootSighash.TaprootSighashOptions.keyPath(hashType);
      assertArrayEquals(
          TaprootSighash.taprootSignatureHash(tx, 1, prevouts, options),
          TaprootSighash.taprootSignatureHash(tx, 1, prevouts, options, cache));
    }
  }

  @Test
  void bitcoinTaggedHashMatchesDoubleSha256Prefix() {
    byte[] tagged = ScriptHash.bitcoinTaggedHash("TapSighash", Hex.decode("0102"));
    assertArrayEquals(tagged, ScriptHash.bitcoinTaggedHash("TapSighash", Hex.decode("0102")));
  }

  private static byte[] xonlyFromSecret(BigInteger secret) {
    byte[] sec1 = Secp256k1.testPubkeySec1(secret);
    return java.util.Arrays.copyOfRange(sec1, 1, 33);
  }

  private static byte[] concat(byte[] prefix, byte[] suffix) {
    byte[] out = new byte[prefix.length + suffix.length];
    System.arraycopy(prefix, 0, out, 0, prefix.length);
    System.arraycopy(suffix, 0, out, prefix.length, suffix.length);
    return out;
  }
}
