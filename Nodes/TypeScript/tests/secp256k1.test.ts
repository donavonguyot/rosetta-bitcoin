import { describe, expect, it } from "vitest";

import {
  Gx,
  Gy,
  N,
  scalarMult,
  signBip340Schnorr,
  signDer,
  verifyDerSignature,
  verifySchnorrSignature,
} from "../src/consensus/secp256k1.js";

describe("secp256k1", () => {
  it("signs and verifies DER ECDSA signatures", () => {
    const privateKey = 1n;
    const point = scalarMult(privateKey, [Gx, Gy]);
    expect(point).not.toBeNull();
    const parity = point![1] % 2n === 0n ? 2 : 3;
    const pubkey = Buffer.concat([
      Buffer.from([parity]),
      Buffer.from(point![0].toString(16).padStart(64, "0"), "hex"),
    ]);
    const digest = Buffer.from("ab".repeat(32), "hex");
    const signature = signDer(privateKey, digest);
    expect(verifyDerSignature(pubkey, digest, signature)).toBe(true);
  });

  it("signs and verifies BIP340 Schnorr signatures", () => {
    const secret = 1234567n % N;
    const message = Buffer.from("cd".repeat(32), "hex");
    const signature = signBip340Schnorr(secret, message);
    expect(signature.length).toBe(64);

    const d0 = secret % N;
    let point = scalarMult(d0, [Gx, Gy]);
    expect(point).not.toBeNull();
    const d = point![1] % 2n === 0n ? d0 : N - d0;
    point = scalarMult(d, [Gx, Gy]);
    const pubkeyXonly = Buffer.from(point![0].toString(16).padStart(64, "0"), "hex");
    expect(verifySchnorrSignature(pubkeyXonly, message, signature)).toBe(true);
  });

  it("rejects invalid Schnorr signatures", () => {
    const pubkeyXonly = Buffer.alloc(32, 0x11);
    const message = Buffer.alloc(32, 0x22);
    const signature = Buffer.alloc(64, 0x33);
    expect(verifySchnorrSignature(pubkeyXonly, message, signature)).toBe(false);
  });
});
