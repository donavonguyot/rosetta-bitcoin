package com.jbitnode.cli;

/** CLI entry for `make java-node-sync-local-core`. */
public final class SyncLocalCore {

  private SyncLocalCore() {}

  public static void main(String[] args) {
    System.exit(SyncLocalCoreService.run(System.out));
  }
}
