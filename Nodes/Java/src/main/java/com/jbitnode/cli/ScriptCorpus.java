package com.jbitnode.cli;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.SerializationFeature;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.jbitnode.consensus.script.ScriptVerify;
import com.jbitnode.consensus.script.SighashCache;
import com.jbitnode.consensus.secp256k1.Secp256k1;
import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TransactionParser;
import com.jbitnode.util.Hex;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

public final class ScriptCorpus {
  private static final ObjectMapper JSON = new ObjectMapper().enable(SerializationFeature.INDENT_OUTPUT);

  private ScriptCorpus() {}

  public static void main(String[] args) throws Exception {
    int exit = run(args, System.getenv());
    if (exit != 0) {
      System.exit(exit);
    }
  }

  public static int run(String[] args, Map<String, String> env) throws Exception {
    Secp256k1.ensureNativeRuntimeBackend(env);
    Path root = repoRoot();
    Path manifest = Path.of(argValue(args, "--manifest", root.resolve("Nodes/Shared/conformance/fixtures/scripts/manifest.json").toString()));
    Path resultPath = Path.of(argValue(args, "--result-path", root.resolve("Nodes/Shared/conformance/results/java_script_corpus_" + java.time.LocalDate.now() + ".json").toString()));
    String runtimeSurface = argValue(args, "--runtime-surface", env.getOrDefault("RUNTIME_SURFACE", "host"));
    String fixtureId = argValue(args, "--fixture-id", "");

    JsonNode manifestDoc = JSON.readTree(Files.readString(manifest, StandardCharsets.UTF_8));
    ArrayNode results = JSON.createArrayNode();
    int passed = 0;
    int failed = 0;
    for (JsonNode fixture : manifestDoc.path("fixtures")) {
      if (!fixtureId.isEmpty() && !fixtureId.equals(text(fixture, "fixture_id"))) {
        continue;
      }
      ObjectNode row = runFixture(manifest, fixture);
      if ("passed".equals(row.path("result").asText())) {
        passed += 1;
      } else {
        failed += 1;
      }
      results.add(row);
    }

    ObjectNode verifier = JSON.createObjectNode();
    verifier.put("engine", "java_native");
    verifier.put("crypto_backend", Secp256k1.nativeBackendImplementation());
    verifier.put("source", "Nodes/Java/src/main/java/com/jbitnode/consensus/script");

    ObjectNode doc = JSON.createObjectNode();
    doc.put("schema", "port.script_corpus_result.v1");
    doc.put("implementation", "JavaNode");
    doc.put("port", "java");
    doc.put("category", "script_corpus");
    doc.put("runtime_surface", runtimeSurface);
    doc.put("native_crypto_backend", Secp256k1.nativeBackendImplementation());
    doc.put("captured_at", Instant.now().toString());
    doc.put("commit", gitCommit(root));
    doc.put("manifest", root.relativize(manifest).toString().replace('\\', '/'));
    doc.put("fixture_count", results.size());
    doc.put("passed", passed);
    doc.put("failed", failed);
    doc.put("result", failed == 0 ? "passed" : "failed");
    doc.set("verifier", verifier);
    doc.set("results", results);

    Files.createDirectories(resultPath.getParent());
    Files.writeString(resultPath, JSON.writeValueAsString(doc) + System.lineSeparator(), StandardCharsets.UTF_8);
    ObjectNode summary = JSON.createObjectNode();
    summary.put("fixture_count", results.size());
    summary.put("passed", passed);
    summary.put("failed", failed);
    summary.put("result", failed == 0 ? "passed" : "failed");
    summary.put("result_path", resultPath.toString());
    System.out.println(JSON.writeValueAsString(summary));
    return failed == 0 ? 0 : 1;
  }

  private static ObjectNode runFixture(Path manifest, JsonNode fixture) {
    ObjectNode row = JSON.createObjectNode();
    int inputIndex = fixture.path("input_index").asInt(0);
    row.put("fixture_id", text(fixture, "fixture_id"));
    row.put("height", fixture.path("height").asInt(-1));
    row.put("txid", text(fixture, "txid"));
    row.put("input_index", inputIndex);
    row.set("required_rules", fixture.path("required_rules").deepCopy());
    row.put("missing_rule", text(fixture, "missing_rule"));
    try {
      Transaction tx = readTransaction(manifest, fixture);
      List<ScriptVerify.SpentPrevout> prevouts = alignPrevouts(manifest, fixture, tx);
      if (inputIndex >= prevouts.size()) {
        throw new IllegalArgumentException("fixture input_index has no matching prevout");
      }
      ScriptVerify.SpentPrevout target = prevouts.get(inputIndex);
      ScriptVerify.verifyTransactionInput(
          tx,
          inputIndex,
          new ScriptVerify.VerifyInputOptions(
              target.scriptPubKey(),
              target.amount(),
              prevouts,
              SighashCache.forTransaction(tx, prevouts)));
      row.put("result", "passed");
      row.put("failure", "");
      row.put("failure_type", "");
      row.put("failure_stage", "");
    } catch (Exception error) {
      row.put("result", "failed");
      row.put("failure", error.getMessage() == null ? error.toString() : error.getMessage());
      row.put("failure_type", error.getClass().getSimpleName());
      row.put("failure_stage", failureStage(error.getMessage()));
    }
    return row;
  }

  private static Transaction readTransaction(Path manifest, JsonNode fixture) throws IOException {
    byte[] raw = Hex.decode(readHex(firstFile(manifest, fixture, "tx")));
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(raw, 0);
    if (parsed.nextOffset() != raw.length) {
      throw new IllegalArgumentException("transaction parser consumed " + parsed.nextOffset() + " of " + raw.length);
    }
    return parsed.transaction();
  }

  private static List<ScriptVerify.SpentPrevout> alignPrevouts(Path manifest, JsonNode fixture, Transaction tx) throws IOException {
    List<ScriptVerify.SpentPrevout> prevouts = readPrevouts(manifest, fixture);
    if (prevouts.size() == tx.inputs().size()) {
      return prevouts;
    }
    int inputIndex = fixture.path("input_index").asInt(0);
    ScriptVerify.SpentPrevout target = targetPrevout(manifest, fixture, prevouts.isEmpty() ? null : prevouts.getFirst());
    ArrayList<ScriptVerify.SpentPrevout> aligned = new ArrayList<>(prevouts);
    while (aligned.size() < tx.inputs().size()) {
      aligned.add(new ScriptVerify.SpentPrevout(0, new byte[0]));
    }
    aligned.set(inputIndex, target);
    return List.copyOf(aligned);
  }

  private static List<ScriptVerify.SpentPrevout> readPrevouts(Path manifest, JsonNode fixture) throws IOException {
    String prevoutsFile = optionalFile(manifest, fixture, "prevouts");
    if (!prevoutsFile.isEmpty()) {
      ArrayList<ScriptVerify.SpentPrevout> out = new ArrayList<>();
      for (JsonNode row : JSON.readTree(Files.readString(Path.of(prevoutsFile), StandardCharsets.UTF_8))) {
        long amount = firstLong(row, "amount", "amount_sats", "value");
        String spk = firstText(row, "spk", "script_pubkey", "scriptPubKey");
        out.add(new ScriptVerify.SpentPrevout(amount, Hex.decode(spk)));
      }
      return List.copyOf(out);
    }
    return List.of(targetPrevout(manifest, fixture, null));
  }

  private static ScriptVerify.SpentPrevout targetPrevout(Path manifest, JsonNode fixture, ScriptVerify.SpentPrevout fallback) throws IOException {
    long amount = fixture.path("prev_amount_sats").asLong(Long.MIN_VALUE);
    String spk = text(fixture, "spent_script_pubkey");
    String prevSpkFile = optionalFile(manifest, fixture, "prev_spk");
    if (!prevSpkFile.isEmpty()) {
      spk = readHex(prevSpkFile);
    }
    if (amount != Long.MIN_VALUE && !spk.isEmpty()) {
      return new ScriptVerify.SpentPrevout(amount, Hex.decode(spk));
    }
    if (fallback != null) {
      return fallback;
    }
    throw new IllegalArgumentException("fixture has no usable prevout data: " + text(fixture, "fixture_id"));
  }

  private static String firstFile(Path manifest, JsonNode fixture, String category) {
    String file = optionalFile(manifest, fixture, category);
    if (file.isEmpty()) {
      throw new IllegalArgumentException("fixture has no " + category + " file: " + text(fixture, "fixture_id"));
    }
    return file;
  }

  private static String optionalFile(Path manifest, JsonNode fixture, String category) {
    JsonNode values = fixture.path("files").path(category);
    if (!values.isArray() || values.isEmpty()) {
      return "";
    }
    return manifest.getParent().resolve(values.get(0).asText()).toString();
  }

  private static String readHex(String path) throws IOException {
    return Files.readString(Path.of(path), StandardCharsets.US_ASCII).trim();
  }

  private static String text(JsonNode node, String field) {
    JsonNode value = node.path(field);
    return value.isMissingNode() || value.isNull() ? "" : value.asText();
  }

  private static String firstText(JsonNode node, String... fields) {
    for (String field : fields) {
      String value = text(node, field);
      if (!value.isEmpty()) {
        return value;
      }
    }
    throw new IllegalArgumentException("missing text field");
  }

  private static long firstLong(JsonNode node, String... fields) {
    for (String field : fields) {
      JsonNode value = node.path(field);
      if (!value.isMissingNode() && !value.isNull()) {
        return value.asLong();
      }
    }
    throw new IllegalArgumentException("missing amount field");
  }

  private static String argValue(String[] args, String name, String fallback) {
    for (int i = 0; i + 1 < args.length; i++) {
      if (name.equals(args[i])) {
        return args[i + 1];
      }
    }
    return fallback;
  }

  private static Path repoRoot() {
    Path dir = Path.of("").toAbsolutePath();
    while (dir != null) {
      if (Files.isDirectory(dir.resolve("Nodes/Shared")) && Files.isDirectory(dir.resolve("Nodes/Java"))) {
        return dir;
      }
      dir = dir.getParent();
    }
    throw new IllegalStateException("could not locate RB workspace root");
  }

  private static String gitCommit(Path root) {
    try {
      Process process = new ProcessBuilder("git", "rev-parse", "--short=12", "HEAD").directory(root.toFile()).start();
      return new String(process.getInputStream().readAllBytes(), StandardCharsets.UTF_8).trim();
    } catch (Exception ignored) {
      return "";
    }
  }

  private static String failureStage(String message) {
    String text = message == null ? "" : message.toLowerCase(java.util.Locale.ROOT);
    if (text.contains("taproot") || text.contains("tapscript")) return "taproot";
    if (text.contains("sighash")) return "sighash";
    if (text.contains("opcode") || text.contains("op_")) return "opcode";
    if (text.contains("stack")) return "stack";
    if (text.contains("template") || text.contains("scriptpubkey")) return "template";
    if (text.contains("signature") || text.contains("secp256k1") || text.contains("schnorr")) return "crypto";
    return "unknown";
  }
}
