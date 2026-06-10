package com.jbitnode.config;

import java.net.Inet4Address;
import java.net.Inet6Address;
import java.net.InetAddress;
import java.net.UnknownHostException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Locale;

/** Parses PEERS environment variable (host:port pairs). */
public final class PeerConfig {

  private PeerConfig() {}

  public record PeerEndpoint(String host, int port) {}

  @FunctionalInterface
  interface AddressResolver {
    List<InetAddress> resolve(String host) throws UnknownHostException;
  }

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

  public static List<PeerEndpoint> parsePublicPeers(String raw, int defaultPort) {
    return parsePublicPeers(raw, defaultPort, host -> Arrays.asList(InetAddress.getAllByName(host)));
  }

  public static List<PeerEndpoint> parsePublicRotationPeers(String raw, int defaultPort) {
    return parsePublicRotationPeers(
        raw, defaultPort, host -> Arrays.asList(InetAddress.getAllByName(host)));
  }

  static List<PeerEndpoint> parsePublicPeers(String raw, int defaultPort, AddressResolver resolver) {
    if (raw == null || raw.isBlank()) {
      throw new IllegalArgumentException("PUBLIC_PEERS is required for external public-peer probes");
    }
    List<PeerEndpoint> peers = parsePeers(raw, defaultPort);
    for (PeerEndpoint peer : peers) {
      validatePublicEndpoint(peer, resolver);
    }
    return peers;
  }

  static List<PeerEndpoint> parsePublicRotationPeers(
      String raw, int defaultPort, AddressResolver resolver) {
    List<PeerEndpoint> peers = parsePublicPeers(raw, defaultPort, resolver);
    List<String> distinct = new ArrayList<>();
    for (PeerEndpoint peer : peers) {
      String key = peer.host().trim().toLowerCase(Locale.ROOT) + ":" + peer.port();
      if (!distinct.contains(key)) {
        distinct.add(key);
      }
    }
    if (distinct.size() < 2) {
      throw new IllegalArgumentException(
          "PUBLIC_PEERS must contain at least two distinct public peers for rotation probes");
    }
    return peers;
  }

  static void validatePublicEndpoint(PeerEndpoint peer, AddressResolver resolver) {
    String host = peer.host().trim();
    String normalized = host.toLowerCase(Locale.ROOT);
    if (isKnownLocalServiceName(normalized)) {
      throw new IllegalArgumentException("PUBLIC_PEERS must not target local service name: " + host);
    }
    List<InetAddress> addresses;
    try {
      addresses = resolver.resolve(host);
    } catch (UnknownHostException error) {
      throw new IllegalArgumentException("PUBLIC_PEERS host does not resolve: " + host, error);
    }
    if (addresses.isEmpty()) {
      throw new IllegalArgumentException("PUBLIC_PEERS host has no resolved addresses: " + host);
    }
    for (InetAddress address : addresses) {
      if (!isPublicRoutable(address)) {
        throw new IllegalArgumentException(
            "PUBLIC_PEERS must resolve only to public routable addresses: "
                + host
                + " -> "
                + address.getHostAddress());
      }
    }
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

  private static boolean isKnownLocalServiceName(String normalizedHost) {
    return normalizedHost.equals("localhost")
        || normalizedHost.equals("host.docker.internal")
        || normalizedHost.equals("bitcoin-core-testnet4")
        || normalizedHost.equals("rosetta-bitcoin-core-testnet4")
        || normalizedHost.equals("jbitnode-bitcoin-core-testnet4")
        || normalizedHost.startsWith("bitcoin-core-testnet4.")
        || normalizedHost.startsWith("rosetta-bitcoin-core-testnet4.");
  }

  private static boolean isPublicRoutable(InetAddress address) {
    if (address.isAnyLocalAddress()
        || address.isLoopbackAddress()
        || address.isLinkLocalAddress()
        || address.isSiteLocalAddress()
        || address.isMulticastAddress()) {
      return false;
    }
    if (address instanceof Inet4Address) {
      byte[] bytes = address.getAddress();
      int first = bytes[0] & 0xff;
      int second = bytes[1] & 0xff;
      if (first == 100 && second >= 64 && second <= 127) {
        return false;
      }
      return first != 0 && first < 224;
    }
    if (address instanceof Inet6Address) {
      byte[] bytes = address.getAddress();
      int first = bytes[0] & 0xff;
      return (first & 0xfe) != 0xfc;
    }
    return false;
  }
}
