package com.jbitnode.config;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.Map;
import org.junit.jupiter.api.Test;

class ScriptVerifySettingsTest {

  @Test
  void defaultsEnableParallelVerify() {
    ScriptVerifySettings settings = ScriptVerifySettings.defaults();
    assertTrue(settings.parallelEnabled());
    assertTrue(settings.maxThreads() >= 1);
    assertEquals(2, settings.minInputs());
  }

  @Test
  void sequentialOnlyDisablesParallelVerify() {
    ScriptVerifySettings settings = ScriptVerifySettings.sequentialOnly();
    assertFalse(settings.parallelEnabled());
  }

  @Test
  void fromEnvParsesParallelFlags() {
    ScriptVerifySettings settings =
        ScriptVerifySettings.fromEnv(
            Map.of(
                "PAR_SCRIPT_VERIFY", "0",
                "PAR_SCRIPT_THREADS", "4",
                "PAR_SCRIPT_MIN_INPUTS", "3"));
    assertFalse(settings.parallelEnabled());
    assertEquals(4, settings.maxThreads());
    assertEquals(3, settings.minInputs());
  }

  @Test
  void fromEnvUsesDefaultsForMissingValues() {
    ScriptVerifySettings settings = ScriptVerifySettings.fromEnv(Map.of());
    assertTrue(settings.parallelEnabled());
    assertEquals(2, settings.minInputs());
    assertTrue(settings.maxThreads() >= 1);
  }

  @Test
  void clampsInvalidThreadAndMinInputValues() {
    ScriptVerifySettings settings = new ScriptVerifySettings(true, 0, 0);
    assertEquals(1, settings.maxThreads());
    assertEquals(1, settings.minInputs());
  }
}
