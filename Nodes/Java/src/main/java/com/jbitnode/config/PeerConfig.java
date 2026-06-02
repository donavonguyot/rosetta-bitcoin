package com.jbitnode.config;

import java.util.ArrayList;
import java.util.List;

/** Parses PEERS environment variable (host:port pairs). */
public final class PeerConfig {

  private PeerConfig() {}

  public record PeerEndpoint(String host, int port) {}

  public static List<PeerEndpoint> parsePeers(String raw, int defaultPort) {
    if (raw == null || raw.isBlank()) {
      return List.of(new PeerEndpoint("127.0.0.1", defaultPort));
    }
    List<PeerEndpoint> peers = new ArrayList<>();
    for (String part : raw.split(",")) {
      String trimmed = part.trim();
      if (trimmed.isEmpty()) {
        continue;
      }
      int colon = trimmed.lastIndexOf(':');
      if (colon > 0) {
        peers.add(
            new PeerEndpoint(
                trimmed.substring(0, colon), Integer.parseInt(trimmed.substring(colon + 1))));
      } else {
        peers.add(new PeerEndpoint(trimmed, defaultPort));
      }
    }
    return peers.isEmpty() ? List.of(new PeerEndpoint("127.0.0.1", defaultPort)) : peers;
  }

  public static int parseIntEnvVar(String name, int defaultValue) {
    return parseIntValue(System.getenv(name), defaultValue);
  }

  public static int parseIntValue(String raw, int defaultValue) {
    if (raw == null || raw.isBlank()) {
      return defaultValue;
    }
    return Integer.parseInt(raw);
  }

  public static boolean parseBoolean(String raw, boolean defaultValue) {
    if (raw == null || raw.isBlank()) {
      return defaultValue;
    }
    return switch (raw.trim().toLowerCase()) {
      case "1", "true", "yes", "on" -> true;
      case "0", "false", "no", "off" -> false;
      default -> defaultValue;
    };
  }
}
