package com.jbitnode.cli;

/** CLI entry point for long-running JavaNode live tip maintenance. */
public final class LiveNode {

  private LiveNode() {}

  public static void main(String[] args) {
    System.exit(LiveNodeService.run(System.out, System.getenv()));
  }
}
