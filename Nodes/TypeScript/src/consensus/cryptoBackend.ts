import { createRequire } from "node:module";

import secp256k1 from "secp256k1";

import {
  liftXOnlyPubkey,
  taprootTweakPubkeyXonly,
  verifyDerSignature,
  verifySchnorrSignature,
} from "./secp256k1.js";

export type CryptoBackendResult = "valid" | "consensus_invalid" | "malformed_input" | "backend_unavailable";
export type Secp256k1BackendName = "pure_ts" | "native";

export interface NativeCryptoVector {
  id: string;
  operation: "verify_ecdsa" | "verify_schnorr" | "taproot_tweak_xonly";
  expected: CryptoBackendResult;
  pubkey_hex?: string;
  xonly_pubkey_hex?: string;
  msg_hash_hex?: string;
  signature_hex?: string;
  merkle_root_hex?: string;
  expected_output_xonly_hex?: string;
  expected_parity?: number;
}

export interface NativeCryptoVectorOutcome {
  id: string;
  operation: string;
  expected: CryptoBackendResult;
  actual: CryptoBackendResult;
  backend: string;
  passed: boolean;
}

const require = createRequire(import.meta.url);
const secp256k1Package = require("secp256k1/package.json") as { version?: string };

function bytes(hex: string | undefined): Buffer {
  return Buffer.from(hex ?? "", "hex");
}

function malformedIfBadLength(buffer: Buffer, length: number): boolean {
  return buffer.length !== length;
}

export function nativeSecp256k1Available(): boolean {
  try {
    require("secp256k1/bindings");
    return true;
  } catch {
    return false;
  }
}

export function selectedSecp256k1Backend(): Secp256k1BackendName {
  return process.env.SECP256K1_BACKEND === "pure_ts" ? "pure_ts" : "native";
}

export function secp256k1BackendInfo(): Record<string, unknown> {
  const selected = selectedSecp256k1Backend();
  return {
    selected_backend: selected,
    native_available: nativeSecp256k1Available(),
    native_package: "secp256k1",
    native_package_version: secp256k1Package.version ?? "unknown",
    ecdsa_backend: selected === "native" && nativeSecp256k1Available() ? "native_libsecp256k1" : "pure_ts",
    schnorr_backend: "pure_ts_fallback",
    taproot_tweak_backend: "pure_ts_fallback",
  };
}

export function verifyEcdsaWithSelectedBackend(
  pubkey: Buffer,
  messageHash: Buffer,
  derSignature: Buffer,
): CryptoBackendResult {
  if (malformedIfBadLength(messageHash, 32) || pubkey.length === 0 || derSignature.length === 0) {
    return "malformed_input";
  }
  if (selectedSecp256k1Backend() !== "native") {
    try {
      return verifyDerSignature(pubkey, messageHash, derSignature) ? "valid" : "consensus_invalid";
    } catch {
      return "malformed_input";
    }
  }
  if (!nativeSecp256k1Available()) {
    return "backend_unavailable";
  }
  try {
    if (!secp256k1.publicKeyVerify(pubkey)) {
      return "malformed_input";
    }
    const compact = secp256k1.signatureNormalize(secp256k1.signatureImport(derSignature));
    return secp256k1.ecdsaVerify(compact, messageHash, pubkey) ? "valid" : "consensus_invalid";
  } catch {
    return "malformed_input";
  }
}

export function verifySchnorrWithSelectedBackend(
  xonlyPubkey: Buffer,
  messageHash: Buffer,
  signature: Buffer,
): CryptoBackendResult {
  if (
    malformedIfBadLength(xonlyPubkey, 32) ||
    malformedIfBadLength(messageHash, 32) ||
    malformedIfBadLength(signature, 64)
  ) {
    return "malformed_input";
  }
  const lifted = liftXOnlyPubkey(BigInt(`0x${xonlyPubkey.toString("hex")}`));
  if (lifted === null) {
    return "malformed_input";
  }
  return verifySchnorrSignature(xonlyPubkey, messageHash, signature) ? "valid" : "consensus_invalid";
}

export function taprootTweakWithSelectedBackend(
  xonlyPubkey: Buffer,
  merkleRoot: Buffer,
  expectedOutputXonly: Buffer | null = null,
  expectedParity: number | null = null,
): CryptoBackendResult {
  if (malformedIfBadLength(xonlyPubkey, 32) || (merkleRoot.length !== 0 && merkleRoot.length !== 32)) {
    return "malformed_input";
  }
  try {
    const [parity, outputXonly] = taprootTweakPubkeyXonly(xonlyPubkey, merkleRoot);
    if (expectedOutputXonly === null || expectedParity === null) {
      return "valid";
    }
    return outputXonly.equals(expectedOutputXonly) && parity === expectedParity ? "valid" : "consensus_invalid";
  } catch {
    return "malformed_input";
  }
}

export function evaluateNativeCryptoVector(vector: NativeCryptoVector): NativeCryptoVectorOutcome {
  let actual: CryptoBackendResult;
  let backend: string;
  if (vector.operation === "verify_ecdsa") {
    actual = verifyEcdsaWithSelectedBackend(
      bytes(vector.pubkey_hex),
      bytes(vector.msg_hash_hex),
      bytes(vector.signature_hex),
    );
    backend = secp256k1BackendInfo().ecdsa_backend as string;
  } else if (vector.operation === "verify_schnorr") {
    actual = verifySchnorrWithSelectedBackend(
      bytes(vector.xonly_pubkey_hex),
      bytes(vector.msg_hash_hex),
      bytes(vector.signature_hex),
    );
    backend = "pure_ts_fallback";
  } else {
    actual = taprootTweakWithSelectedBackend(
      bytes(vector.xonly_pubkey_hex),
      bytes(vector.merkle_root_hex),
      vector.expected_output_xonly_hex ? bytes(vector.expected_output_xonly_hex) : null,
      vector.expected_parity ?? null,
    );
    backend = "pure_ts_fallback";
  }
  return {
    id: vector.id,
    operation: vector.operation,
    expected: vector.expected,
    actual,
    backend,
    passed: actual === vector.expected,
  };
}
