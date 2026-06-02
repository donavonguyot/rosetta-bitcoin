package com.jbitnode.config;

import java.util.Map;

/** Parallel script verification settings (Phase A: per-transaction input parallelism). */
public record ScriptVerifySettings(boolean parallelEnabled, int maxThreads, int minInputs) {

  public ScriptVerifySettings {
    maxThreads = Math.max(1, maxThreads);
    minInputs = Math.max(1, minInputs);
  }

  public static ScriptVerifySettings defaults() {
    return new ScriptVerifySettings(true, Runtime.getRuntime().availableProcessors(), 2);
  }

  public static ScriptVerifySettings sequentialOnly() {
    return new ScriptVerifySettings(false, 1, 2);
  }

  public static ScriptVerifySettings fromEnv() {
    return fromEnv(System.getenv());
  }

  public static ScriptVerifySettings fromEnv(Map<String, String> env) {
    boolean parallelEnabled = PeerConfig.parseBoolean(env.get("PAR_SCRIPT_VERIFY"), true);
    int maxThreads =
        PeerConfig.parseIntValue(
            env.get("PAR_SCRIPT_THREADS"), Runtime.getRuntime().availableProcessors());
    int minInputs = PeerConfig.parseIntValue(env.get("PAR_SCRIPT_MIN_INPUTS"), 2);
    return new ScriptVerifySettings(parallelEnabled, maxThreads, minInputs);
  }
}
