package com.jbitnode.testutil;

import com.jbitnode.util.Hex;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;

/** Loads hex/text fixtures from {@code src/test/resources/fixtures}. */
public final class FixtureLoader {

  private FixtureLoader() {}

  public static byte[] readHex(String resourcePath) {
    return Hex.decode(readText(resourcePath).replaceAll("\\s+", ""));
  }

  public static String readText(String resourcePath) {
    try (InputStream in = FixtureLoader.class.getResourceAsStream(resourcePath)) {
      if (in == null) {
        throw new IllegalArgumentException("Missing fixture resource: " + resourcePath);
      }
      return new String(in.readAllBytes(), StandardCharsets.UTF_8).trim();
    } catch (IOException e) {
      throw new IllegalStateException("Cannot read fixture " + resourcePath, e);
    }
  }

  public static byte[] readBytes(String resourcePath) {
    try (InputStream in = FixtureLoader.class.getResourceAsStream(resourcePath)) {
      if (in == null) {
        throw new IllegalArgumentException("Missing fixture resource: " + resourcePath);
      }
      return in.readAllBytes();
    } catch (IOException e) {
      throw new IllegalStateException("Cannot read fixture " + resourcePath, e);
    }
  }
}
