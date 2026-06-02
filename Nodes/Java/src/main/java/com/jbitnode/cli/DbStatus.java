package com.jbitnode.cli;

/** CLI entry for `make java-node-status`. */
public final class DbStatus {

  private DbStatus() {}

  public static void main(String[] args) {
    try {
      System.exit(DbStatusService.run(args, System.out));
    } catch (Exception e) {
      System.err.println("jbitnode-db failed: " + e.getMessage());
      System.exit(1);
    }
  }
}
