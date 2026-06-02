package com.jbitnode;

import static org.junit.jupiter.api.Assertions.assertFalse;

import org.junit.jupiter.api.Test;

class JbitnodeTest {

  @Test
  void versionIsPresent() {
    assertFalse(Jbitnode.VERSION.isBlank());
  }
}
