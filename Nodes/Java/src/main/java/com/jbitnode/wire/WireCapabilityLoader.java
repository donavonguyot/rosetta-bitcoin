package com.jbitnode.wire;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.IOException;
import java.io.InputStream;
import java.util.List;

/** Loads the scout wire capability registry from classpath JSON. */
public final class WireCapabilityLoader {

  private static final ObjectMapper MAPPER = new ObjectMapper();
  private static final TypeReference<List<WireCapability>> LIST_TYPE = new TypeReference<>() {};

  private WireCapabilityLoader() {}

  public static List<WireCapability> loadDefaults() throws IOException {
    try (InputStream in =
        WireCapabilityLoader.class.getResourceAsStream("/wire/capabilities.json")) {
      return loadFromStream(in);
    }
  }

  static List<WireCapability> loadFromStream(InputStream in) throws IOException {
    if (in == null) {
      throw new IOException("Missing classpath resource /wire/capabilities.json");
    }
    return MAPPER.readValue(in, LIST_TYPE);
  }
}
