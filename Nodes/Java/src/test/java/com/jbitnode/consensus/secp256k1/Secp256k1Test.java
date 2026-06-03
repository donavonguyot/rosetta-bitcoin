package com.jbitnode.consensus.secp256k1;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.consensus.script.ScriptVerifyProfiler;
import com.jbitnode.util.Hex;
import com.jbitnode.wire.WireSerialize;
import java.math.BigInteger;
import java.util.HashMap;
import java.util.Map;
import org.junit.jupiter.api.Test;

class Secp256k1Test {

  @Test
  void signVerifyRoundtrip() {
    BigInteger privateKey = BigInteger.ONE;
    byte[] digest = WireSerialize.doubleSha256(Hex.decode("deadbeef"));
    byte[] signature = Secp256k1.signDer(privateKey, digest);
    byte[] pubkey = Secp256k1.testPubkeySec1(privateKey);
    assertTrue(Secp256k1.verifyDerSignature(pubkey, digest, signature));
  }

  @Test
  void verifyRejectsInvalidSignature() {
    BigInteger privateKey = BigInteger.ONE;
    byte[] digest = WireSerialize.doubleSha256(Hex.decode("01020304"));
    byte[] pubkey = Secp256k1.testPubkeySec1(privateKey);
    assertFalse(Secp256k1.verifyDerSignature(pubkey, digest, new byte[] {0x30, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x01}));
  }

  @Test
  void verifyRejectsWrongMessageLength() {
    org.junit.jupiter.api.Assertions.assertThrows(
        Secp256k1.Secp256k1Error.class,
        () -> Secp256k1.verifyDerSignature(new byte[33], new byte[31], new byte[8]));
  }

  @Test
  void schnorrSignVerifyRoundtrip() {
    BigInteger secret = BigInteger.valueOf(12345);
    byte[] message = WireSerialize.doubleSha256(Hex.decode("cafebabe"));
    byte[] signature = Secp256k1.signBip340Schnorr(secret, message);
    byte[] pubkeyXonly = java.util.Arrays.copyOfRange(Secp256k1.testPubkeySec1(secret), 1, 33);
    assertTrue(Secp256k1.verifySchnorrSignature(pubkeyXonly, message, signature));
  }

  @Test
  void schnorrVerifyRejectsInvalidSignature() {
    assertFalse(Secp256k1.verifySchnorrSignature(Hex.decode("11".repeat(32)), WireSerialize.doubleSha256(Hex.decode("01020304")), new byte[64]));
  }

  @Test
  void schnorrVerifyRejectsWrongLengths() {
    assertFalse(Secp256k1.verifySchnorrSignature(new byte[31], new byte[32], new byte[64]));
  }

  @Test
  void schnorrSignRejectsInvalidSecret() {
    org.junit.jupiter.api.Assertions.assertThrows(Secp256k1.Secp256k1Error.class, () -> Secp256k1.signBip340Schnorr(BigInteger.ZERO, new byte[32]));
  }

  @Test
  void taprootTweakHelpersRejectInvalidInternalKeyLength() {
    org.junit.jupiter.api.Assertions.assertThrows(Secp256k1.Secp256k1Error.class, () -> Secp256k1.taprootOutputKeyXonly(new byte[31], new byte[0]));
  }

  @Test
  void optimizedDerVerifierMatchesReference() {
    for (int index = 1; index <= 5; index++) {
      BigInteger privateKey = BigInteger.valueOf(index);
      byte[] digest = WireSerialize.doubleSha256(Hex.decode("0" + index + "deadbeef"));
      byte[] signature = Secp256k1.signDer(privateKey, digest);
      byte[] pubkey = Secp256k1.testPubkeySec1(privateKey);
      assertEquals(
          Secp256k1.verifyDerSignatureReference(pubkey, digest, signature),
          Secp256k1.verifyDerSignature(pubkey, digest, signature));
      assertEquals(
          Secp256k1.verifyDerSignatureReference(pubkey, WireSerialize.doubleSha256(Hex.decode("ff")), signature),
          Secp256k1.verifyDerSignature(pubkey, WireSerialize.doubleSha256(Hex.decode("ff")), signature));
    }
  }

  @Test
  void optimizedSchnorrVerifierMatchesReference() {
    for (int index = 1; index <= 5; index++) {
      BigInteger privateKey = BigInteger.valueOf(100 + index);
      byte[] message = WireSerialize.doubleSha256(Hex.decode("0" + index + "cafebabe"));
      byte[] signature = Secp256k1.signBip340Schnorr(privateKey, message);
      byte[] pubkeyXonly = java.util.Arrays.copyOfRange(Secp256k1.testPubkeySec1(privateKey), 1, 33);
      assertEquals(
          Secp256k1.verifySchnorrSignatureReference(pubkeyXonly, message, signature),
          Secp256k1.verifySchnorrSignature(pubkeyXonly, message, signature));
      byte[] badSignature = signature.clone();
      badSignature[0] ^= 1;
      assertEquals(
          Secp256k1.verifySchnorrSignatureReference(pubkeyXonly, message, badSignature),
          Secp256k1.verifySchnorrSignature(pubkeyXonly, message, badSignature));
    }
  }

  @Test
  void profilerRecordsCryptoSubstages() {
    BigInteger privateKey = BigInteger.valueOf(7);
    byte[] digest = WireSerialize.doubleSha256(Hex.decode("feedface"));
    byte[] signature = Secp256k1.signDer(privateKey, digest);
    byte[] pubkey = Secp256k1.testPubkeySec1(privateKey);
    Map<String, Long> timings = new HashMap<>();
    ScriptVerifyProfiler.withRecorder(
        (stage, elapsedNanos) -> timings.merge(stage, elapsedNanos, Long::sum),
        () -> assertTrue(Secp256k1.verifyDerSignature(pubkey, digest, signature)));
    assertTrue(timings.getOrDefault("script_ecdsa_verify", 0L) > 0);
    assertTrue(timings.getOrDefault("script_pubkey_decode_or_lift", 0L) > 0);
  }

  @Test
  void nativeBackendMatchesPureJavaForGeneratedCases() {
    assertTrue(Secp256k1.nativeBackendAvailable());
    Secp256k1.useBackendForTests(Secp256k1.Backend.NATIVE);
    try {
      for (int index = 1; index <= 5; index++) {
        BigInteger privateKey = BigInteger.valueOf(index + 400);
        byte[] digest = WireSerialize.doubleSha256(Hex.decode("0" + index + "f00d"));
        byte[] signature = Secp256k1.signDer(privateKey, digest);
        byte[] pubkey = Secp256k1.testPubkeySec1(privateKey);
        assertEquals(
            Secp256k1.verifyDerSignatureReference(pubkey, digest, signature),
            Secp256k1.verifyDerSignature(pubkey, digest, signature));
        BigInteger[] rs = parseDerSignatureForTest(signature);
        byte[] highSSignature = Secp256k1.encodeDerSignature(rs[0], Secp256k1.N.subtract(rs[1]));
        assertEquals(
            Secp256k1.verifyDerSignatureReference(pubkey, digest, highSSignature),
            Secp256k1.verifyDerSignature(pubkey, digest, highSSignature));

        byte[] message = WireSerialize.doubleSha256(Hex.decode("0" + index + "51"));
        byte[] schnorrSignature = Secp256k1.signBip340Schnorr(privateKey, message);
        byte[] xonly = java.util.Arrays.copyOfRange(pubkey, 1, 33);
        assertEquals(
            Secp256k1.verifySchnorrSignatureReference(xonly, message, schnorrSignature),
            Secp256k1.verifySchnorrSignature(xonly, message, schnorrSignature));
      }
    } finally {
      Secp256k1.useBackendForTests(Secp256k1.Backend.PURE_JAVA);
    }
  }

  private static BigInteger[] parseDerSignatureForTest(byte[] signature) {
    int rLen = signature[3] & 0xff;
    BigInteger r = new BigInteger(1, java.util.Arrays.copyOfRange(signature, 4, 4 + rLen));
    int offset = 4 + rLen;
    int sLen = signature[offset + 1] & 0xff;
    BigInteger s =
        new BigInteger(1, java.util.Arrays.copyOfRange(signature, offset + 2, offset + 2 + sLen));
    return new BigInteger[] {r, s};
  }
}
