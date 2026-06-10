package com.jbitnode.cli;

/** CLI entry point for the bounded outbound public-peer rotation probe. */
public final class PublicPeerRotationProbe {

  private PublicPeerRotationProbe() {}

  public static void main(String[] args) {
    System.exit(PublicPeerRotationProbeService.run(System.out, System.getenv()));
  }
}
