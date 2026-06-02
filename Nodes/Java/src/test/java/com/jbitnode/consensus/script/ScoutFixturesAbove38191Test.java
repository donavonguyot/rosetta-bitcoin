package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertTrue;

import org.junit.jupiter.api.Test;

/**
 * Documents Python scout boundary above live blocker @38191.
 *
 * <p>Grep of {@code PythonNode/tests/test_script.py} (2026-05-25): no
 * {@code test_real_testnet4_block38*} or {@code test_real_testnet4_block39*} with
 * height &gt; 38191. Highest scout: block 38010
 * ({@code test_real_testnet4_block38010_p2pkh_sighash_single_sequence_accepted}).
 */
class ScoutFixturesAbove38191Test {

  static final int LIVE_BLOCKER_HEIGHT = 38191;
  static final int HIGHEST_PYTHON_SCOUT_HEIGHT = 38010;

  @Test
  void noPythonScoutFixturesExistAbove38191() {
    assertTrue(
        HIGHEST_PYTHON_SCOUT_HEIGHT < LIVE_BLOCKER_HEIGHT,
        "Python scout ends at 38010; live P2SH blocker is @38191 with no scout fixture yet");
  }
}
