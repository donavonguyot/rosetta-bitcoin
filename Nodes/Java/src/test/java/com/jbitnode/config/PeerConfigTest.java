package com.jbitnode.config;

import static org.junit.jupiter.api.Assertions.assertEquals;

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
}
