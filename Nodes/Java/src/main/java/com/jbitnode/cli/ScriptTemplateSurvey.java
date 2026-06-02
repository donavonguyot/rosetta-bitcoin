package com.jbitnode.cli;

/** CLI entry for `make java-node-survey-scripts`. */
public final class ScriptTemplateSurvey {

  private ScriptTemplateSurvey() {}

  public static void main(String[] args) {
    try {
      System.exit(ScriptTemplateSurveyService.run(args, System.out));
    } catch (Exception error) {
      System.err.println("jbitnode script-template-survey failed: " + error.getMessage());
      System.exit(error.getMessage() != null && error.getMessage().contains("not found") ? 2 : 1);
    }
  }
}
