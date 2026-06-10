package com.jbitnode.cli;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.util.List;
import org.junit.jupiter.api.Test;

class PublicPeerRotationProbeServiceTest {

  private static final ObjectMapper JSON = new ObjectMapper();

  @Test
  void requiresTwoDistinctPassingAttempts() {
    assertFalse(PublicPeerRotationProbeService.hasTwoDistinctPassingPeers(List.of(pass("one.example:48333"))));
    assertFalse(
        PublicPeerRotationProbeService.hasTwoDistinctPassingPeers(
            List.of(pass("one.example:48333"), pass("ONE.example:48333"))));
    assertTrue(
        PublicPeerRotationProbeService.hasTwoDistinctPassingPeers(
            List.of(pass("one.example:48333"), pass("two.example:48333"))));
  }

  @Test
  void blockedAttemptDoesNotCountAsHealthyPeer() {
    assertFalse(
        PublicPeerRotationProbeService.hasTwoDistinctPassingPeers(
            List.of(pass("one.example:48333"), blocked("two.example:48333"))));
  }

  @Test
  void failedAttemptDoesNotCountAsHealthyPeer() {
    ObjectNode failed = JSON.createObjectNode();
    failed.put("peer", "two.example:48333");
    failed.put("result", "fail");
    failed.putNull("current_blocker");
    assertFalse(
        PublicPeerRotationProbeService.hasTwoDistinctPassingPeers(
            List.of(pass("one.example:48333"), failed)));
  }

  private static ObjectNode pass(String peer) {
    ObjectNode attempt = JSON.createObjectNode();
    attempt.put("peer", peer);
    attempt.put("result", "pass");
    attempt.putNull("current_blocker");
    return attempt;
  }

  private static ObjectNode blocked(String peer) {
    ObjectNode attempt = pass(peer);
    attempt.put("current_blocker", "consensus blocker");
    return attempt;
  }
}
