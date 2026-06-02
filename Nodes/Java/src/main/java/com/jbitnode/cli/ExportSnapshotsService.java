package com.jbitnode.cli;

import java.io.PrintStream;
import java.util.Map;

/** Snapshot export moved behind native status JSON plus Project scripts. */
public final class ExportSnapshotsService {

  private ExportSnapshotsService() {}

  public static int run(String[] args, PrintStream out) {
    out.println("export_snapshots status=unsupported reason=native_storage_snapshot_export_not_implemented");
    return 2;
  }
}
