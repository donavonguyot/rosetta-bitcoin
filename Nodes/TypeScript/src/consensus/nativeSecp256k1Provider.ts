import { createHash } from "node:crypto";
import { createRequire } from "node:module";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

interface NativeSecp256k1Addon {
  verifyEcdsaDer(pubkey: Buffer, messageHash: Buffer, derSignature: Buffer): boolean;
  verifySchnorr(xonlyPubkey: Buffer, messageHash: Buffer, signature: Buffer): boolean;
  taprootTweakXonly(internalXonly: Buffer, tweak: Buffer): { parity: number; outputXonly: Buffer } | null;
  closeContext(): null;
}

export interface NativeSecp256k1Provider {
  verifyEcdsaDer(pubkey: Buffer, messageHash: Buffer, derSignature: Buffer): boolean;
  verifySchnorr(xonlyPubkey: Buffer, messageHash: Buffer, signature: Buffer): boolean;
  taprootTweakXonly(internalXonly: Buffer, merkleRoot: Buffer): [parity: number, outputXonly: Buffer] | null;
  backendInfo(): Record<string, unknown>;
  close(): void;
}

const require = createRequire(import.meta.url);

let loadAttempted = false;
let loadedAddon: NativeSecp256k1Addon | null = null;
let loadFailure: Error | null = null;

export function nativeSecp256k1ProviderAvailable(): boolean {
  return loadNativeAddon() !== null;
}

export function nativeSecp256k1LoadError(): string | null {
  loadNativeAddon();
  return loadFailure?.message ?? null;
}

export function getNativeSecp256k1Provider(): NativeSecp256k1Provider {
  const addon = loadNativeAddon();
  if (addon === null) {
    throw new Error(`native libsecp256k1 addon unavailable${loadFailure ? `: ${loadFailure.message}` : ""}`);
  }
  return new LibSecp256k1Provider(addon);
}

class LibSecp256k1Provider implements NativeSecp256k1Provider {
  private readonly verificationCache = new VerificationResultCache(100_000);

  constructor(private readonly addon: NativeSecp256k1Addon) {}

  verifyEcdsaDer(pubkey: Buffer, messageHash: Buffer, derSignature: Buffer): boolean {
    return this.verificationCache.getOrCompute("e", pubkey, messageHash, derSignature, () =>
      this.addon.verifyEcdsaDer(pubkey, messageHash, derSignature),
    );
  }

  verifySchnorr(xonlyPubkey: Buffer, messageHash: Buffer, signature: Buffer): boolean {
    return this.verificationCache.getOrCompute("s", xonlyPubkey, messageHash, signature, () =>
      this.addon.verifySchnorr(xonlyPubkey, messageHash, signature),
    );
  }

  taprootTweakXonly(internalXonly: Buffer, merkleRoot: Buffer): [parity: number, outputXonly: Buffer] | null {
    const tweak = tapTweakHash(internalXonly, merkleRoot);
    const result = this.addon.taprootTweakXonly(internalXonly, tweak);
    return result === null ? null : [result.parity, Buffer.from(result.outputXonly)];
  }

  backendInfo(): Record<string, unknown> {
    return {
      native_package: "libsecp256k1",
      crypto_context_mode: "libsecp256k1/reused_context_per_worker",
      ecdsa_backend: "native_libsecp256k1",
      schnorr_backend: "native_libsecp256k1",
      taproot_tweak_backend: "native_libsecp256k1",
    };
  }

  close(): void {
    this.addon.closeContext();
  }
}

class VerificationResultCache {
  private readonly entries = new Map<string, boolean>();

  constructor(private readonly maxEntries: number) {}

  getOrCompute(kind: string, pubkey: Buffer, messageHash: Buffer, signature: Buffer, compute: () => boolean): boolean {
    const key = binaryKey(kind, pubkey, messageHash, signature);
    const cached = this.entries.get(key);
    if (cached !== undefined) return cached;
    const result = compute();
    if (this.entries.size >= this.maxEntries) {
      const first = this.entries.keys().next().value as string | undefined;
      if (first !== undefined) this.entries.delete(first);
    }
    this.entries.set(key, result);
    return result;
  }
}

function loadNativeAddon(): NativeSecp256k1Addon | null {
  if (loadAttempted) return loadedAddon;
  loadAttempted = true;
  try {
    const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
    loadedAddon = require("node-gyp-build")(packageRoot) as NativeSecp256k1Addon;
  } catch (error) {
    loadFailure = error instanceof Error ? error : new Error(String(error));
    loadedAddon = null;
  }
  return loadedAddon;
}

function tapTweakHash(internalXonly: Buffer, merkleRoot: Buffer): Buffer {
  const tagDigest = createHash("sha256").update("TapTweak", "utf8").digest();
  return createHash("sha256")
    .update(tagDigest)
    .update(tagDigest)
    .update(internalXonly)
    .update(merkleRoot)
    .digest();
}

function binaryKey(kind: string, pubkey: Buffer, messageHash: Buffer, signature: Buffer): string {
  return Buffer.concat([
    Buffer.from(kind, "ascii"),
    Buffer.from([pubkey.length]),
    pubkey,
    messageHash,
    Buffer.from([signature.length]),
    signature,
  ]).toString("latin1");
}
