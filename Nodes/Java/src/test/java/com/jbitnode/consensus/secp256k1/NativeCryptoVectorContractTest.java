package com.jbitnode.consensus.secp256k1;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.jbitnode.util.Hex;
import java.nio.file.Files;
import java.nio.file.Path;
import org.junit.jupiter.api.Test;

class NativeCryptoVectorContractTest {

  @Test
  void sharedNativeCryptoVectorsRunAgainstAllJavaBackends() throws Exception {
    JsonNode root =
        new ObjectMapper()
            .readTree(
                Files.readString(
                    Path.of(
                        "..",
                        "NodeCore",
                        "conformance",
                        "fixtures",
                        "native_crypto_v1_vectors.json")));
    assertEquals(1, root.get("version").asInt());
    assertEquals("libsecp256k1", root.get("target_backend").asText());
    assertEquals("active", root.get("status").asText());
    assertTrue(root.get("vectors").size() >= 7);
    assertTrue(Secp256k1.nativeBackendAvailable());

    for (Secp256k1.Backend backend :
        new Secp256k1.Backend[] {
          Secp256k1.Backend.PURE_JAVA, Secp256k1.Backend.NATIVE
        }) {
      Secp256k1.useBackendForTests(backend);
      try {
        for (JsonNode vector : root.get("vectors")) {
          assertVector(vector);
        }
      } finally {
        Secp256k1.useBackendForTests(Secp256k1.Backend.PURE_JAVA);
      }
    }
  }

  private static void assertVector(JsonNode vector) {
    String operation = vector.path("operation").asText();
    String expected = vector.path("expected").asText();
    switch (operation) {
      case "verify_ecdsa" -> {
        boolean verified =
            Secp256k1.verifyDerSignature(
                Hex.decode(vector.path("pubkey_hex").asText()),
                Hex.decode(vector.path("msg_hash_hex").asText()),
                Hex.decode(vector.path("signature_hex").asText()));
        assertVerificationResult(expected, verified);
      }
      case "verify_schnorr" -> {
        boolean verified =
            Secp256k1.verifySchnorrSignature(
                Hex.decode(vector.path("xonly_pubkey_hex").asText()),
                Hex.decode(vector.path("msg_hash_hex").asText()),
                Hex.decode(vector.path("signature_hex").asText()));
        assertVerificationResult(expected, verified);
      }
      case "taproot_tweak_xonly" -> assertTaprootVector(vector, expected);
      default -> throw new AssertionError("unknown native crypto vector operation: " + operation);
    }
  }

  private static void assertVerificationResult(String expected, boolean verified) {
    if ("valid".equals(expected)) {
      assertTrue(verified);
    } else {
      assertFalse(verified);
    }
  }

  private static void assertTaprootVector(JsonNode vector, String expected) {
    try {
      Secp256k1.TaprootTweakResult result =
          Secp256k1.taprootTweakPubkeyXonly(
              Hex.decode(vector.path("xonly_pubkey_hex").asText()),
              Hex.decode(vector.path("merkle_root_hex").asText()));
      if ("valid".equals(expected)) {
        assertEquals(vector.path("expected_parity").asInt(), result.parity());
        assertEquals(vector.path("expected_output_xonly_hex").asText(), Hex.encode(result.outputXonly()));
      } else {
        throw new AssertionError("taproot vector should not be valid: " + vector.path("id").asText());
      }
    } catch (Secp256k1.Secp256k1Error error) {
      if ("valid".equals(expected)) {
        throw error;
      }
    }
  }
}
