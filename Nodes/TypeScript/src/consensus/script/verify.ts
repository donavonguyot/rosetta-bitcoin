import {
  assertVerifyScript,
  isP2pkh,
  isP2sh,
  isP2tr,
  isP2wpkh,
  isP2wsh,
  p2pkhScriptCode,
  parsePushOnlyScriptSig,
  witnessProgramVersion,
} from "./interpreter.js";
import {
  TAPROOT_SIGHASH_DEFAULT,
  bip143Sighash,
  legacySighash,
  taprootSignatureHash,
  type TransactionSighashCache,
} from "./sighash.js";
import { hash160, sha256Digest } from "../hash.js";
import { verifyEcdsaWithSelectedBackend, verifySchnorrWithSelectedBackend } from "../cryptoBackend.js";
import type { Transaction } from "../../messages/transaction.js";

export class ScriptVerifyError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ScriptVerifyError";
  }
}

/** Spend-path verifier for Shared-supported templates. Unsupported shapes must throw (validation blocker). */
export function verifyTransactionInput(
  transaction: Transaction,
  inputIndex: number,
  options: {
    scriptPubKey: Buffer;
    amount: number;
    spentPrevouts?: readonly (readonly [number, Buffer])[];
    sighashCache?: TransactionSighashCache | undefined;
  },
): void {
  if (inputIndex >= transaction.inputs.length) {
    throw new ScriptVerifyError("input index out of range");
  }

  const txIn = transaction.inputs[inputIndex]!;
  const witness =
    transaction.witness.length > inputIndex ? transaction.witness[inputIndex]! : [];

  const witnessVersion = witnessProgramVersion(options.scriptPubKey);
  if (witnessVersion !== null && witnessVersion > 1) {
    throw new ScriptVerifyError(`unsupported witness program version ${witnessVersion}`);
  }

  const verifyOptions: {
    tx: Transaction;
    inputIndex: number;
    amount: number;
    witness: readonly Buffer[];
    spentPrevouts?: readonly (readonly [number, Buffer])[];
    sighashCache?: TransactionSighashCache | undefined;
  } = {
    tx: transaction,
    inputIndex,
    amount: options.amount,
    witness,
  };
  if (options.spentPrevouts !== undefined) {
    verifyOptions.spentPrevouts = options.spentPrevouts;
  }
  if (options.sighashCache !== undefined) {
    verifyOptions.sighashCache = options.sighashCache;
  }

  try {
    if (tryFastPathVerify(txIn.scriptSig, options.scriptPubKey, verifyOptions)) {
      return;
    }
    assertVerifyScript(txIn.scriptSig, options.scriptPubKey, verifyOptions);
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    throw new ScriptVerifyError(`input ${inputIndex}: ${detail}`);
  }
}

function tryFastPathVerify(
  scriptSig: Buffer,
  scriptPubKey: Buffer,
  options: {
    tx: Transaction;
    inputIndex: number;
    amount: number;
    witness: readonly Buffer[];
    spentPrevouts?: readonly (readonly [number, Buffer])[];
    sighashCache?: TransactionSighashCache | undefined;
  },
): boolean {
  if (isP2pkh(scriptPubKey)) {
    const pushes = parsePushOnlyScriptSig(scriptSig);
    if (pushes.length === 2) {
      verifyFastP2pkhPushes(pushes as [Buffer, Buffer], scriptPubKey, options);
      return true;
    }
    return false;
  }
  if (isP2wpkh(scriptPubKey)) {
    verifyFastP2wpkh(scriptSig, scriptPubKey, options);
    return true;
  }
  if (isP2sh(scriptPubKey)) {
    const pushes = parsePushOnlyScriptSig(scriptSig);
    if (pushes.length === 1 && isP2wpkh(pushes[0]!)) {
      if (!hash160(pushes[0]!).equals(scriptPubKey.subarray(2, 22))) {
        throw new Error("P2SH redeem script hash mismatch");
      }
      verifyFastP2wpkh(Buffer.alloc(0), pushes[0]!, options);
      return true;
    }
  }
  if (isP2tr(scriptPubKey) && isP2trKeyPathWitness(options.witness)) {
    verifyFastP2trKeyPath(scriptSig, scriptPubKey, options);
    return true;
  }
  if (isP2wsh(scriptPubKey) && canFastP2wsh(scriptSig, scriptPubKey, options.witness)) {
    verifyFastP2wsh(scriptSig, scriptPubKey, options);
    return true;
  }
  return false;
}

function verifyFastP2pkhPushes(
  pushes: [Buffer, Buffer],
  scriptPubKey: Buffer,
  options: { tx: Transaction; inputIndex: number; amount: number; witness: readonly Buffer[]; sighashCache?: TransactionSighashCache | undefined },
): void {
  if (options.witness.length > 0) throw new Error("P2PKH spend cannot have witness");
  const [signature, pubkey] = pushes;
  if (!hash160(pubkey).equals(scriptPubKey.subarray(3, 23))) throw new Error("P2PKH pubkey hash mismatch");
  verifyEcdsaSignature(signature, pubkey, legacyDigest(options, scriptPubKey, signature));
}

function verifyFastP2wpkh(
  scriptSig: Buffer,
  scriptPubKey: Buffer,
  options: { tx: Transaction; inputIndex: number; amount: number; witness: readonly Buffer[]; sighashCache?: TransactionSighashCache | undefined },
): void {
  if (scriptSig.length > 0) throw new Error("P2WPKH scriptSig must be empty");
  if (options.witness.length !== 2) throw new Error("P2WPKH witness must contain signature and pubkey");
  const [signature, pubkey] = options.witness as [Buffer, Buffer];
  const pubkeyHash = scriptPubKey.subarray(2);
  if (!hash160(pubkey).equals(pubkeyHash)) throw new Error("P2WPKH pubkey hash mismatch");
  const scriptCode = p2pkhScriptCode(pubkeyHash);
  verifyEcdsaSignature(signature, pubkey, witnessDigest(options, scriptCode, signature));
}

function verifyFastP2trKeyPath(
  scriptSig: Buffer,
  scriptPubKey: Buffer,
  options: {
    tx: Transaction;
    inputIndex: number;
    witness: readonly Buffer[];
    spentPrevouts?: readonly (readonly [number, Buffer])[];
    sighashCache?: TransactionSighashCache | undefined;
  },
): void {
  if (scriptSig.length > 0) throw new Error("P2TR scriptSig must be empty");
  if (options.spentPrevouts === undefined) throw new Error("P2TR key-path requires spent prevouts");
  const { signature, annex } = p2trKeyPathWitness(options.witness);
  if (signature.length !== 64 && signature.length !== 65) throw new Error("invalid Schnorr signature length");
  let hashType = TAPROOT_SIGHASH_DEFAULT;
  let sig64 = signature;
  if (signature.length === 65) {
    hashType = signature[64]!;
    if (hashType === TAPROOT_SIGHASH_DEFAULT) throw new Error("invalid tap hashtype byte");
    sig64 = signature.subarray(0, 64);
  }
  const msg = options.sighashCache?.taprootSignatureHash(options.inputIndex, { hashType, annex }) ??
    taprootSignatureHash(options.tx, options.inputIndex, options.spentPrevouts, { hashType, annex });
  if (verifySchnorrWithSelectedBackend(scriptPubKey.subarray(2), msg, sig64) !== "valid") {
    throw new Error("taproot key-path signature failed");
  }
}

function verifyFastP2wsh(
  scriptSig: Buffer,
  scriptPubKey: Buffer,
  options: { tx: Transaction; inputIndex: number; amount: number; witness: readonly Buffer[]; sighashCache?: TransactionSighashCache | undefined },
): void {
  if (scriptSig.length > 0) throw new Error("P2WSH scriptSig must be empty");
  const witnessScript = options.witness[options.witness.length - 1]!;
  if (!sha256Digest(witnessScript).equals(scriptPubKey.subarray(2))) throw new Error("P2WSH witness script hash mismatch");
  const checksigPubkey = parseSimpleChecksigScript(witnessScript);
  if (checksigPubkey !== null) {
    if (options.witness.length !== 2) throw new Error("P2WSH CHECKSIG witness must contain signature and witness script");
    verifyEcdsaSignature(options.witness[0]!, checksigPubkey, witnessDigest(options, witnessScript, options.witness[0]!));
    return;
  }
  const multisig = parseSimpleMultisigScript(witnessScript);
  if (multisig === null) throw new Error("unsupported fast P2WSH template");
  if (options.witness.length !== multisig.required + 2) throw new Error("P2WSH CHECKMULTISIG witness item count mismatch");
  const signatures = options.witness.slice(1, -1);
  let pubkeyIndex = 0;
  for (const signature of signatures) {
    let matched = false;
    while (pubkeyIndex < multisig.pubkeys.length) {
      const pubkey = multisig.pubkeys[pubkeyIndex]!;
      pubkeyIndex += 1;
      const digest = witnessDigest(options, witnessScript, signature);
      if (verifyEcdsaWithSelectedBackend(pubkey, digest, signature.subarray(0, -1)) === "valid") {
        matched = true;
        break;
      }
    }
    if (!matched) throw new Error("CHECKMULTISIG failed");
  }
}

function verifyEcdsaSignature(signature: Buffer, pubkey: Buffer, digest: Buffer): void {
  if (signature.length === 0) throw new Error("signature check failed");
  if (verifyEcdsaWithSelectedBackend(pubkey, digest, signature.subarray(0, -1)) !== "valid") {
    throw new Error("signature check failed");
  }
}

function legacyDigest(
  options: { tx: Transaction; inputIndex: number; sighashCache?: TransactionSighashCache | undefined },
  scriptCode: Buffer,
  signature: Buffer,
): Buffer {
  if (signature.length === 0) throw new Error("signature check failed");
  const sighashType = signature[signature.length - 1]!;
  return options.sighashCache?.legacySighash(options.inputIndex, scriptCode, sighashType) ??
    legacySighash(options.tx, options.inputIndex, scriptCode, sighashType);
}

function witnessDigest(
  options: { tx: Transaction; inputIndex: number; amount: number; sighashCache?: TransactionSighashCache | undefined },
  scriptCode: Buffer,
  signature: Buffer,
): Buffer {
  if (signature.length === 0) throw new Error("signature check failed");
  const sighashType = signature[signature.length - 1]!;
  return options.sighashCache?.bip143Sighash(options.inputIndex, scriptCode, options.amount, sighashType) ??
    bip143Sighash(options.tx, options.inputIndex, scriptCode, options.amount, sighashType);
}

function isP2trKeyPathWitness(witness: readonly Buffer[]): boolean {
  try {
    p2trKeyPathWitness(witness);
    return true;
  } catch {
    return false;
  }
}

function p2trKeyPathWitness(witness: readonly Buffer[]): { signature: Buffer; annex: Buffer | null } {
  const items = [...witness];
  let annex: Buffer | null = null;
  if (items.length >= 2 && items[items.length - 1]!.length > 0 && items[items.length - 1]![0] === 0x50) {
    annex = items.pop()!;
  }
  if (items.length !== 1) throw new Error("not a P2TR key-path witness");
  return { signature: items[0]!, annex };
}

function canFastP2wsh(scriptSig: Buffer, scriptPubKey: Buffer, witness: readonly Buffer[]): boolean {
  if (scriptSig.length > 0 || witness.length < 2) return false;
  const witnessScript = witness[witness.length - 1]!;
  if (!sha256Digest(witnessScript).equals(scriptPubKey.subarray(2))) return false;
  return parseSimpleChecksigScript(witnessScript) !== null || parseSimpleMultisigScript(witnessScript) !== null;
}

function parseSimpleChecksigScript(script: Buffer): Buffer | null {
  if (script.length < 2 || script[script.length - 1] !== 0xac) return null;
  const pubkeyLength = script[0]!;
  if ((pubkeyLength !== 33 && pubkeyLength !== 65) || script.length !== pubkeyLength + 2) return null;
  return script.subarray(1, 1 + pubkeyLength);
}

function parseSimpleMultisigScript(script: Buffer): { required: number; pubkeys: Buffer[] } | null {
  if (script.length < 4 || script[script.length - 1] !== 0xae) return null;
  const required = decodeOpN(script[0]!);
  if (required === null) return null;
  const total = decodeOpN(script[script.length - 2]!);
  if (total === null || required > total || total > 16) return null;
  const pubkeys: Buffer[] = [];
  let offset = 1;
  while (offset < script.length - 2) {
    const pubkeyLength = script[offset]!;
    if (pubkeyLength !== 33 && pubkeyLength !== 65) return null;
    const end = offset + 1 + pubkeyLength;
    if (end > script.length - 2) return null;
    pubkeys.push(script.subarray(offset + 1, end));
    offset = end;
  }
  if (pubkeys.length !== total) return null;
  return { required, pubkeys };
}

function decodeOpN(opcode: number): number | null {
  if (opcode >= 0x51 && opcode <= 0x60) return opcode - 0x50;
  return null;
}
