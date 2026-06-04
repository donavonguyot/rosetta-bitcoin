import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

import {
  evaluateNativeCryptoVector,
  nativeSecp256k1Available,
  secp256k1BackendInfo,
  type NativeCryptoVector,
} from "../src/consensus/cryptoBackend.js";

interface NativeCryptoFixture {
  vectors: NativeCryptoVector[];
}

function loadFixture(): NativeCryptoFixture {
  const path = join(
    import.meta.dirname,
    "..",
    "..",
    "Shared",
    "conformance",
    "fixtures",
    "native_crypto_v1_vectors.json",
  );
  return JSON.parse(readFileSync(path, "utf8")) as NativeCryptoFixture;
}

describe("native crypto vector contract", () => {
  it("reports backend metadata", () => {
    const info = secp256k1BackendInfo();
    expect(info.selected_backend).toBe("native");
    expect(info.native_package).toBe("libsecp256k1");
    expect(typeof info.native_package_version).toBe("string");
    expect(info.ecdsa_backend).toBe("native_libsecp256k1");
    expect(info.schnorr_backend).toBe("native_libsecp256k1");
    expect(info.taproot_tweak_backend).toBe("native_libsecp256k1");
    expect(nativeSecp256k1Available()).toBe(true);
  });

  it("matches Shared native_crypto_v1 vectors", () => {
    const outcomes = loadFixture().vectors.map(evaluateNativeCryptoVector);
    expect(outcomes).toEqual(
      outcomes.map((outcome) => ({
        ...outcome,
        passed: true,
      })),
    );
  });
});
