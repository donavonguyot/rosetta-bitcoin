import { createRequire } from "node:module";

import secp256k1 from "secp256k1";

import {
  liftXOnlyPubkey,
  taprootTweakPubkeyXonly,
  verifyDerSignature,
  verifySchnorrSignature,
} from "./secp256k1.js";
import {
  getNativeSecp256k1Provider,
  nativeSecp256k1LoadError,
  nativeSecp256k1ProviderAvailable,
} from "./nativeSecp256k1Provider.js";

export type CryptoBackendResult = "valid" | "consensus_invalid" | "malformed_input" | "backend_unavailable";
export type Secp256k1BackendName = "pure_ts" | "native";

export interface TaprootTweakBackendResult {
  result: CryptoBackendResult;
  parity: number;
  outputXonly: Buffer;
}

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
  return nativeSecp256k1ProviderAvailable();
}

export function selectedSecp256k1Backend(): Secp256k1BackendName {
  return process.env.SECP256K1_BACKEND === "pure_ts" ? "pure_ts" : "native";
}

export function secp256k1BackendInfo(): Record<string, unknown> {
  const selected = selectedSecp256k1Backend();
  const nativeAvailable = nativeSecp256k1Available();
  const nativeInfo = nativeAvailable ? getNativeSecp256k1Provider().backendInfo() : {};
  return {
    selected_backend: selected,
    native_available: nativeAvailable,
    native_package: nativeAvailable ? "libsecp256k1" : "unavailable",
    native_package_version: secp256k1Package.version ?? "unknown",
    native_load_error: nativeAvailable ? null : nativeSecp256k1LoadError(),
    ecdsa_backend: selected === "native" && nativeAvailable ? nativeInfo.ecdsa_backend : "pure_ts",
    schnorr_backend: selected === "native" && nativeAvailable ? nativeInfo.schnorr_backend : "pure_ts",
    taproot_tweak_backend: selected === "native" && nativeAvailable ? nativeInfo.taproot_tweak_backend : "pure_ts",
    crypto_context_mode: selected === "native" && nativeAvailable ? nativeInfo.crypto_context_mode : "pure_ts",
  };
}

export function ensureNativeSecp256k1Available(): void {
  if (selectedSecp256k1Backend() === "native" && !nativeSecp256k1Available()) {
    throw new Error(`SECP256K1_BACKEND=native but native libsecp256k1 addon is unavailable: ${nativeSecp256k1LoadError() ?? "unknown error"}`);
  }
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
    return getNativeSecp256k1Provider().verifyEcdsaDer(pubkey, messageHash, derSignature) ? "valid" : "consensus_invalid";
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
  if (selectedSecp256k1Backend() === "native") {
    if (!nativeSecp256k1Available()) {
      return "backend_unavailable";
    }
    return getNativeSecp256k1Provider().verifySchnorr(xonlyPubkey, messageHash, signature) ? "valid" : "consensus_invalid";
  }
  return verifySchnorrSignature(xonlyPubkey, messageHash, signature) ? "valid" : "consensus_invalid";
}

export function taprootTweakWithSelectedBackend(
  xonlyPubkey: Buffer,
  merkleRoot: Buffer,
  expectedOutputXonly: Buffer | null = null,
  expectedParity: number | null = null,
): TaprootTweakBackendResult {
  if (malformedIfBadLength(xonlyPubkey, 32) || (merkleRoot.length !== 0 && merkleRoot.length !== 32)) {
    return tweakResult("malformed_input");
  }
  try {
    if (selectedSecp256k1Backend() === "native") {
      if (!nativeSecp256k1Available()) {
        return tweakResult("backend_unavailable");
      }
      const tweaked = getNativeSecp256k1Provider().taprootTweakXonly(xonlyPubkey, merkleRoot);
      if (tweaked === null) return tweakResult("malformed_input");
      const [parity, outputXonly] = tweaked;
      if (expectedOutputXonly === null || expectedParity === null) {
        return tweakResult("valid", parity, outputXonly);
      }
      return tweakResult(
        outputXonly.equals(expectedOutputXonly) && parity === expectedParity ? "valid" : "consensus_invalid",
        parity,
        outputXonly,
      );
    }
    const [parity, outputXonly] = taprootTweakPubkeyXonly(xonlyPubkey, merkleRoot);
    if (expectedOutputXonly === null || expectedParity === null) {
      return tweakResult("valid", parity, outputXonly);
    }
    return tweakResult(
      outputXonly.equals(expectedOutputXonly) && parity === expectedParity ? "valid" : "consensus_invalid",
      parity,
      outputXonly,
    );
  } catch {
    return tweakResult("malformed_input");
  }
}

function tweakResult(result: CryptoBackendResult, parity = 0, outputXonly: Buffer = Buffer.alloc(0)): TaprootTweakBackendResult {
  return { result, parity, outputXonly };
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
    backend = secp256k1BackendInfo().schnorr_backend as string;
  } else {
    actual = taprootTweakWithSelectedBackend(
      bytes(vector.xonly_pubkey_hex),
      bytes(vector.merkle_root_hex),
      vector.expected_output_xonly_hex ? bytes(vector.expected_output_xonly_hex) : null,
      vector.expected_parity ?? null,
    ).result;
    backend = secp256k1BackendInfo().taproot_tweak_backend as string;
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
