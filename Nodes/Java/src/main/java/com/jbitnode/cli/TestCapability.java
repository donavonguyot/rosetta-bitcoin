package com.jbitnode.cli;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.SerializationFeature;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.jbitnode.consensus.secp256k1.Secp256k1;
import com.jbitnode.util.Hex;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/** Emits per-suite pass/fail outcomes consumed by the shared capability contract writer. */
public final class TestCapability {
  private static final ObjectMapper JSON = new ObjectMapper().enable(SerializationFeature.INDENT_OUTPUT);

  private TestCapability() {}

  public static void main(String[] args) throws Exception {
    int exit = run(args, System.getenv());
    if (exit != 0) {
      System.exit(exit);
    }
  }

  public static int run(String[] args, Map<String, String> env) throws Exception {
    String kind = argValue(args, "--kind", "");
    Path outcomePath = Path.of(argValue(args, "--outcome-path", ""));
    if (kind.isEmpty() || outcomePath.toString().isEmpty()) {
      throw new IllegalArgumentException("--kind and --outcome-path are required");
    }
    Secp256k1.ensureNativeRuntimeBackend(env);

    ArrayNode outcomes =
        switch (kind) {
          case "crypto-vectors" -> cryptoVectorOutcomes();
          case "block-connect-backend" -> blockConnectOutcomes(env);
          default -> throw new IllegalArgumentException("unknown kind: " + kind);
        };
    ObjectNode doc = JSON.createObjectNode();
    doc.put("port", "java");
    doc.put("backend", "libsecp256k1-acinq");
    doc.set("outcomes", outcomes);
    Files.createDirectories(outcomePath.toAbsolutePath().getParent());
    Files.writeString(outcomePath, JSON.writeValueAsString(doc) + System.lineSeparator(), StandardCharsets.UTF_8);
    System.out.println(outcomePath);
    return 0;
  }

  private static ArrayNode cryptoVectorOutcomes() throws Exception {
    Path root = repoRoot();
    Outcome bip =
        runBip340(root.resolve("Nodes/Shared/testing/fixtures/bip340/test-vectors.csv"));
    Outcome nativeVectors =
        runNativeVectors(root.resolve("Nodes/Shared/conformance/fixtures/native_crypto_v1_vectors.json"));
    ArrayNode outcomes = JSON.createArrayNode();
    outcomes.add(outcome("crypto_bip340_vectors", bip));
    outcomes.add(
        outcome(
            "crypto_libsecp256k1_equivalence",
            new Outcome(
                bip.passed + nativeVectors.passed,
                bip.total + nativeVectors.total,
                joinNotes(bip.notes, nativeVectors.notes))));
    return outcomes;
  }

  private static Outcome runBip340(Path path) throws Exception {
    int passed = 0;
    int total = 0;
    List<String> failures = new ArrayList<>();
    fr.acinq.secp256k1.Secp256k1 api = fr.acinq.secp256k1.Secp256k1.get();
    List<String> lines = Files.readAllLines(path, StandardCharsets.UTF_8);
    for (int i = 1; i < lines.size(); i++) {
      String[] fields = lines.get(i).split(",", -1);
      if (fields.length < 7) {
        throw new IllegalArgumentException("malformed BIP340 vector row " + i);
      }
      total += 1;
      boolean expected = "TRUE".equals(fields[6]);
      boolean actual;
      try {
        actual =
            api.verifySchnorr(
                Hex.decode(fields[5]),
                Hex.decode(fields[4]),
                Hex.decode(fields[2]));
      } catch (RuntimeException error) {
        actual = false;
      }
      if (actual == expected) {
        passed += 1;
      } else {
        failures.add(fields[0]);
      }
    }
    if (failures.isEmpty()) {
      return new Outcome(passed, total, "all BIP340 vectors matched expected verification result");
    }
    return new Outcome(passed, total, "mismatched BIP340 vector indexes: " + String.join(",", failures));
  }

  private static Outcome runNativeVectors(Path path) throws Exception {
    JsonNode root = JSON.readTree(Files.readString(path, StandardCharsets.UTF_8));
    int passed = 0;
    List<String> failures = new ArrayList<>();
    for (JsonNode vector : root.path("vectors")) {
      boolean ok = nativeVectorMatches(vector);
      if (ok) {
        passed += 1;
      } else {
        failures.add(vector.path("id").asText());
      }
    }
    int total = root.path("vectors").size();
    if (failures.isEmpty()) {
      return new Outcome(passed, total, "native crypto vectors " + passed + "/" + total);
    }
    return new Outcome(passed, total, "native vector failures: " + String.join(",", failures));
  }

  private static boolean nativeVectorMatches(JsonNode vector) {
    String expected = vector.path("expected").asText();
    return switch (vector.path("operation").asText()) {
      case "verify_ecdsa" ->
          verifyResult(
              expected,
              Secp256k1.verifyDerSignature(
                  Hex.decode(vector.path("pubkey_hex").asText()),
                  Hex.decode(vector.path("msg_hash_hex").asText()),
                  Hex.decode(vector.path("signature_hex").asText())));
      case "verify_schnorr" ->
          verifyResult(
              expected,
              Secp256k1.verifySchnorrSignature(
                  Hex.decode(vector.path("xonly_pubkey_hex").asText()),
                  Hex.decode(vector.path("msg_hash_hex").asText()),
                  Hex.decode(vector.path("signature_hex").asText())));
      case "taproot_tweak_xonly" -> taprootVectorMatches(vector, expected);
      default -> false;
    };
  }

  private static boolean taprootVectorMatches(JsonNode vector, String expected) {
    try {
      Secp256k1.TaprootTweakResult result =
          Secp256k1.taprootTweakPubkeyXonly(
              Hex.decode(vector.path("xonly_pubkey_hex").asText()),
              Hex.decode(vector.path("merkle_root_hex").asText()));
      boolean matches =
          result.parity() == vector.path("expected_parity").asInt()
              && Hex.encode(result.outputXonly())
                  .equals(vector.path("expected_output_xonly_hex").asText());
      return verifyResult(expected, matches);
    } catch (Secp256k1.Secp256k1Error error) {
      return !"valid".equals(expected);
    }
  }

  private static ArrayNode blockConnectOutcomes(Map<String, String> env) throws Exception {
    Path root = repoRoot();
    String[] fixtures = {
      "scripts.p2pkh_sighash_single_38010", "scripts.p2tr_scriptpath_44295"
    };
    int passed = 0;
    List<String> notes = new ArrayList<>();
    for (String fixture : fixtures) {
      Path temp = Files.createTempFile("jbitnode_" + fixture.replace('.', '_'), "_probe.json");
      try {
        int exit =
            ScriptCorpus.run(
                new String[] {
                  "--result-path",
                  temp.toString(),
                  "--fixture-id",
                  fixture,
                  "--manifest",
                  root.resolve("Nodes/Shared/conformance/fixtures/scripts/manifest.json").toString()
                },
                env);
        JsonNode doc = JSON.readTree(Files.readString(temp, StandardCharsets.UTF_8));
        if (exit == 0 && "passed".equals(doc.path("result").asText()) && doc.path("passed").asInt() == 1) {
          passed += 1;
        }
        notes.add(fixture + " result=" + doc.path("result").asText());
      } finally {
        Files.deleteIfExists(temp);
      }
    }
    ArrayNode outcomes = JSON.createArrayNode();
    outcomes.add(
        outcome(
            "block_connect_with_backend",
            new Outcome(passed, fixtures.length, String.join("; ", notes))));
    return outcomes;
  }

  private static ObjectNode outcome(String capability, Outcome result) {
    ObjectNode row = JSON.createObjectNode();
    row.put("capability", capability);
    row.put("status", result.passed == result.total ? "pass" : "fail");
    row.put("case_passed", result.passed);
    row.put("case_total", result.total);
    row.put("notes", result.notes);
    return row;
  }

  private static boolean verifyResult(String expected, boolean actual) {
    return ("valid".equals(expected) && actual) || (!"valid".equals(expected) && !actual);
  }

  private static String joinNotes(String first, String second) {
    if (first.isEmpty()) {
      return second;
    }
    if (second.isEmpty()) {
      return first;
    }
    return first + "; " + second;
  }

  private static String argValue(String[] args, String name, String fallback) {
    for (int i = 0; i < args.length - 1; i++) {
      if (name.equals(args[i])) {
        return args[i + 1];
      }
    }
    return fallback;
  }

  private static Path repoRoot() {
    Path cwd = Path.of("").toAbsolutePath();
    for (Path dir = cwd; dir != null; dir = dir.getParent()) {
      if (Files.exists(dir.resolve("Nodes/Shared")) && Files.exists(dir.resolve("Nodes/Java"))) {
        return dir;
      }
    }
    throw new IllegalStateException("could not locate repository root");
  }

  private record Outcome(int passed, int total, String notes) {}
}
