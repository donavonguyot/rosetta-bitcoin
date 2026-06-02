package com.jbitnode.cli;

/** CLI entry for clean chainstate rebuilds. */
public final class ChainstateRebuild {

  private ChainstateRebuild() {}

  public static void main(String[] args) {
    System.exit(ChainstateRebuildService.run(System.out));
  }
}
