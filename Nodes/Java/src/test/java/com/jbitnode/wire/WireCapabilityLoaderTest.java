package com.jbitnode.wire;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.io.IOException;
import org.junit.jupiter.api.Test;

class WireCapabilityLoaderTest {

  @Test
  void loadsScoutRegistry() throws Exception {
    var caps = WireCapabilityLoader.loadDefaults();
    assertEquals(53, caps.size());
    assertTrue(caps.stream().anyMatch(c -> c.id().equals("frame.build")));
    assertTrue(caps.stream().anyMatch(c -> c.checkpoint().equals("cp6_serving")));
  }

  @Test
  void loadFromStreamThrowsWhenMissing() {
    org.junit.jupiter.api.Assertions.assertThrows(
        IOException.class, () -> WireCapabilityLoader.loadFromStream(null));
  }

  @Test
  void recordsRequiredAndImplementedFlags() throws Exception {
    var caps = WireCapabilityLoader.loadDefaults();
    WireCapability inbound =
        caps.stream().filter(c -> c.id().equals("transport.inbound")).findFirst().orElseThrow();
    assertFalse(inbound.required());
    assertFalse(inbound.implemented());
    WireCapability versionSend =
        caps.stream().filter(c -> c.id().equals("handshake.version.send")).findFirst().orElseThrow();
    assertTrue(versionSend.required());
    assertTrue(versionSend.implemented());
  }
}
