package com.jbitnode.cli;

/** CLI entry for `make java-node-export-snapshots`. */
public final class ExportSnapshots {

  private ExportSnapshots() {}

  public static void main(String[] args) {
    try {
      System.exit(ExportSnapshotsService.run(args, System.out));
    } catch (Exception e) {
      System.err.println("jbitnode export-snapshots failed: " + e.getMessage());
      System.exit(1);
    }
  }
}
