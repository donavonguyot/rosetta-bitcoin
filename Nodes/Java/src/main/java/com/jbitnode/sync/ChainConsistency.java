package com.jbitnode.sync;

import com.jbitnode.db.ProjectTracker;
import java.sql.SQLException;

/** Pre-flight checks before block connect/download (detect unsafe partial state). */
public final class ChainConsistency {

  private ChainConsistency() {}

  public static void verifyOrThrow(ProjectTracker tracker, String chain)
      throws SQLException, ChainInconsistentException {
    int validated = tracker.getValidatedHeight(chain);
    if (validated < 1) {
      return;
    }
    int maxStored = tracker.maxStoredBlockHeight(chain);
    if (validated > maxStored) {
      throw new ChainInconsistentException(
          "validated_height "
              + validated
              + " exceeds max stored block "
              + maxStored
              + "; stop all sync processes and rebuild DATA_DIR (see README § recovery)");
    }
    if (!tracker.hasBlock(chain, validated)) {
      throw new ChainInconsistentException(
          "validated_height "
              + validated
              + " has no stored block row; stop all sync processes and rebuild DATA_DIR (see README § recovery)");
    }
    int gapsBelowTip = tracker.countBlockStorageGaps(chain, validated);
    if (gapsBelowTip > 0) {
      throw new ChainInconsistentException(
          "block storage has "
              + gapsBelowTip
              + " gap(s) at or below validated_height "
              + validated
              + "; stop all sync processes and rebuild DATA_DIR (see README § recovery)");
    }
  }

  public static String blockStorageGapMessage(int expectedHeight, int nextMissingHeight) {
    return "block storage gap: expected connect height "
        + expectedHeight
        + " but next missing stored block is "
        + nextMissingHeight
        + " (stop parallel sync writers and verify DATA_DIR; see README § recovery)";
  }
}
