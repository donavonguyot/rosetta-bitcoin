package com.jbitnode.config;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import java.net.InetAddress;
import java.net.UnknownHostException;
import java.util.Arrays;
import java.util.List;
import org.junit.jupiter.api.Test;

class PeerConfigTest {

  @Test
  void parsesHostPortPairs() {
    assertEquals(
        "127.0.0.1",
        PeerConfig.parsePeers("127.0.0.1:48333,example.com", 48_333).getFirst().host());
    assertEquals(
        48_333,
        PeerConfig.parsePeers("127.0.0.1:48333,example.com", 48_333).get(1).port());
  }

  @Test
  void defaultsToLocalCore() {
    assertEquals("127.0.0.1", PeerConfig.parsePeers(null, 48_333).getFirst().host());
    assertEquals(48_333, PeerConfig.parsePeers("", 48_333).getFirst().port());
  }

  @Test
  void parseIntValueUsesDefault() {
    assertEquals(10, PeerConfig.parseIntValue(null, 10));
    assertEquals(5, PeerConfig.parseIntValue("5", 10));
  }

  @Test
  void parseBooleanUsesDefaultAndRecognizesValues() {
    assertEquals(true, PeerConfig.parseBoolean("true", false));
    assertEquals(false, PeerConfig.parseBoolean("0", true));
    assertEquals(true, PeerConfig.parseBoolean(null, true));
  }

  @Test
  void publicPeersAreRequired() {
    assertThrows(IllegalArgumentException.class, () -> PeerConfig.parsePublicPeers("", 48_333));
  }

  @Test
  void publicPeersRejectLocalReferenceAndLocalhost() {
    assertThrows(
        IllegalArgumentException.class,
        () -> PeerConfig.parsePublicPeers("bitcoin-core-testnet4:48333", 48_333, resolver("93.184.216.34")));
    assertThrows(
        IllegalArgumentException.class,
        () -> PeerConfig.parsePublicPeers("localhost:48333", 48_333));
    assertThrows(
        IllegalArgumentException.class,
        () -> PeerConfig.parsePublicPeers("127.0.0.1:48333", 48_333));
    assertThrows(
        IllegalArgumentException.class,
        () -> PeerConfig.parsePublicPeers("::1:48333", 48_333));
  }

  @Test
  void publicPeersRejectPrivateAndLinkLocalRanges() {
    for (String address : List.of("10.0.0.7", "172.16.0.7", "192.168.1.7", "169.254.0.7", "100.64.0.7")) {
      assertThrows(
          IllegalArgumentException.class,
          () -> PeerConfig.parsePublicPeers(address + ":48333", 48_333));
    }
  }

  @Test
  void publicPeersAcceptPublicHostnames() {
    List<PeerConfig.PeerEndpoint> peers =
        PeerConfig.parsePublicPeers("public.example", 48_333, resolver("93.184.216.34"));
    assertEquals("public.example", peers.getFirst().host());
    assertEquals(48_333, peers.getFirst().port());
  }

  @Test
  void publicRotationPeersRequireTwoDistinctPublicEndpoints() {
    assertThrows(
        IllegalArgumentException.class,
        () -> PeerConfig.parsePublicRotationPeers("public.example:48333", 48_333, resolver("93.184.216.34")));
    assertThrows(
        IllegalArgumentException.class,
        () ->
            PeerConfig.parsePublicRotationPeers(
                "public.example:48333,PUBLIC.example:48333", 48_333, resolver("93.184.216.34")));
    assertThrows(
        IllegalArgumentException.class,
        () ->
            PeerConfig.parsePublicRotationPeers(
                "bitcoin-core-testnet4:48333,public.example:48333", 48_333, resolver("93.184.216.34")));

    List<PeerConfig.PeerEndpoint> peers =
        PeerConfig.parsePublicRotationPeers(
            "first.example:48333,second.example:48333", 48_333, resolver("93.184.216.34"));
    assertEquals(2, peers.size());
  }

  private static PeerConfig.AddressResolver resolver(String... addresses) {
    return host -> {
      try {
        InetAddress[] resolved = new InetAddress[addresses.length];
        for (int index = 0; index < addresses.length; index += 1) {
          resolved[index] = InetAddress.getByName(addresses[index]);
        }
        return Arrays.asList(resolved);
      } catch (UnknownHostException error) {
        throw error;
      }
    };
  }
}
