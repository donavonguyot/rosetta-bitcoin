package com.jbitnode.cli;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.io.IOException;
import java.io.PrintStream;

/** Script template survey will be reintroduced against native storage. */
public final class ScriptTemplateSurveyService {

  private static final ObjectMapper MAPPER = new ObjectMapper();

  private ScriptTemplateSurveyService() {}

  public record SurveyOptions(java.nio.file.Path dbPath, String chain, int scanBlocks, java.nio.file.Path blocksDir, boolean help) {}

  public static SurveyOptions parseArgs(String[] args) {
    return new SurveyOptions(null, "testnet4", 0, null, false);
  }

  public static ObjectNode survey(SurveyOptions options) {
    ObjectNode root = MAPPER.createObjectNode();
    root.put("status", "unsupported");
    root.put("reason", "native_storage_survey_not_implemented");
    return root;
  }

  public static int run(String[] args, PrintStream out) throws IOException {
    out.println(MAPPER.writerWithDefaultPrettyPrinter().writeValueAsString(survey(parseArgs(args))));
    return 2;
  }
}
