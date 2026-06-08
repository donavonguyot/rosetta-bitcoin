import { createHash } from "node:crypto";

import {
  outPointSerialize,
  transactionSerialize,
  txInSerialize,
  txOutSerialize,
  type Transaction,
} from "../../messages/transaction.js";
import {
  doubleSha256,
  packInt32Le,
  readCompactSize,
  unpackInt32Le,
  writeCompactSize,
} from "../../wire/serialize.js";

export const TAPROOT_SIGHASH_DEFAULT = 0;
export const TAPROOT_SIGHASH_ALL = 1;
export const TAPROOT_SIGHASH_NONE = 2;
export const TAPROOT_SIGHASH_SINGLE = 3;

const ZERO_HASH = Buffer.alloc(32, 0);

export function bitcoinTaggedHash(tag: string, msg: Buffer): Buffer {
  const tagDigest = createHash("sha256").update(tag, "utf8").digest();
  return createHash("sha256").update(Buffer.concat([tagDigest, tagDigest, msg])).digest();
}

/** Legacy pre-segwit sighash; consensus byte-shape must match Shared script fixtures. */
export function legacySighash(
  transaction: Transaction,
  inputIndex: number,
  scriptCode: Buffer,
  sighashType = 1,
): Buffer {
  return new TransactionSighashCache(transaction).legacySighash(inputIndex, scriptCode, sighashType);
}

export class TransactionSighashCache {
  private readonly digestCache = new Map<string, Buffer>();
  private readonly sharedCache = new Map<string, Buffer>();

  constructor(
    readonly transaction: Transaction,
    readonly spentPrevouts: readonly (readonly [number, Buffer])[] = [],
  ) {}

  legacySighash(inputIndex: number, scriptCode: Buffer, sighashType = 1): Buffer {
    const key = `legacy:${inputIndex}:${sighashType}:${scriptCode.toString("hex")}`;
    return this.cachedDigest(key, () => legacySighashUncached(this.transaction, inputIndex, scriptCode, sighashType));
  }

  bip143Sighash(inputIndex: number, scriptCode: Buffer, amount: number, sighashType = 1): Buffer {
    const key = `bip143:${inputIndex}:${amount}:${sighashType}:${scriptCode.toString("hex")}`;
    return this.cachedDigest(key, () => this.bip143SighashUncached(inputIndex, scriptCode, amount, sighashType));
  }

  taprootSignatureHash(
    inputIndex: number,
    options: {
      hashType: number;
      annex?: Buffer | null;
      extFlag?: number;
      tapleafHash?: Buffer | null;
      tapscriptCodeseparatorPos?: number;
    },
  ): Buffer {
    const hashType = options.hashType;
    const annex = options.annex ?? null;
    const extFlag = options.extFlag ?? 0;
    const tapleafHashValue = options.tapleafHash ?? null;
    const tapscriptCodeseparatorPos = options.tapscriptCodeseparatorPos ?? 0xffffffff;
    const key = [
      "taproot",
      inputIndex,
      hashType,
      extFlag,
      annex?.toString("hex") ?? "",
      tapleafHashValue?.toString("hex") ?? "",
      tapscriptCodeseparatorPos,
    ].join(":");
    return this.cachedDigest(key, () =>
      this.taprootSignatureHashUncached(inputIndex, {
        hashType,
        annex,
        extFlag,
        tapleafHash: tapleafHashValue,
        tapscriptCodeseparatorPos,
      }),
    );
  }

  private cachedDigest(key: string, build: () => Buffer): Buffer {
    const cached = this.digestCache.get(key);
    if (cached !== undefined) return cached;
    const digest = build();
    this.digestCache.set(key, digest);
    return digest;
  }

  private sharedHash(key: string, build: () => Buffer): Buffer {
    const cached = this.sharedCache.get(key);
    if (cached !== undefined) return cached;
    const digest = build();
    this.sharedCache.set(key, digest);
    return digest;
  }

  private bip143SighashUncached(
    inputIndex: number,
    scriptCode: Buffer,
    amount: number,
    sighashType = 1,
  ): Buffer {
    const transaction = this.transaction;
    if (inputIndex >= transaction.inputs.length) {
      throw new Error("input_index out of range");
    }

    const anyoneCanPay = (sighashType & 0x80) !== 0;
    const baseType = sighashType & 0x1f;

    let hashPrevouts: Buffer = ZERO_HASH;
    if (!anyoneCanPay) {
      hashPrevouts = this.sharedHash("bip143:prevouts", () => {
        const prevouts = Buffer.concat(
          transaction.inputs.map((input) => outPointSerialize(input.previousOutput)),
        );
        return doubleSha256(prevouts);
      });
    }

    let hashSequence: Buffer = ZERO_HASH;
    if (!anyoneCanPay && baseType !== 2 && baseType !== 3) {
      hashSequence = this.sharedHash("bip143:sequence", () => {
        const sequences = Buffer.concat(transaction.inputs.map((input) => packInt32Le(input.sequence)));
        return doubleSha256(sequences);
      });
    }

    let hashOutputs: Buffer = ZERO_HASH;
    if (baseType === 3) {
      if (inputIndex < transaction.outputs.length) {
        hashOutputs = this.sharedHash(`bip143:outputs:single:${inputIndex}`, () =>
          doubleSha256(txOutSerialize(transaction.outputs[inputIndex]!)),
        );
      }
    } else if (baseType !== 2) {
      hashOutputs = this.sharedHash("bip143:outputs:all", () => {
        const outputs = Buffer.concat(transaction.outputs.map((output) => txOutSerialize(output)));
        return doubleSha256(outputs);
      });
    }

    const txIn = transaction.inputs[inputIndex]!;
    const amountBuf = Buffer.allocUnsafe(8);
    amountBuf.writeBigInt64LE(BigInt(amount), 0);
    const payload = Buffer.concat([
      packInt32Le(transaction.version),
      hashPrevouts,
      hashSequence,
      outPointSerialize(txIn.previousOutput),
      writeCompactSize(scriptCode.length),
      scriptCode,
      amountBuf,
      packInt32Le(txIn.sequence),
      hashOutputs,
      packInt32Le(transaction.lockTime),
      packInt32Le(sighashType),
    ]);
    return doubleSha256(payload);
  }

  private taprootSignatureHashUncached(
    inputIndex: number,
    options: {
      hashType: number;
      annex?: Buffer | null;
      extFlag?: number;
      tapleafHash?: Buffer | null;
      tapscriptCodeseparatorPos?: number;
    },
  ): Buffer {
    const transaction = this.transaction;
    const spentPrevouts = this.spentPrevouts;
    const hashType = options.hashType;
    const annex = options.annex ?? null;
    const extFlag = options.extFlag ?? 0;
    const tapleafHashValue = options.tapleafHash ?? null;
    const tapscriptCodeseparatorPos = options.tapscriptCodeseparatorPos ?? 0xffffffff;

    if (spentPrevouts.length !== transaction.inputs.length) {
      throw new Error("spent_prevouts length mismatch");
    }
    if (!taprootAllowedHashtypes(hashType)) {
      throw new Error("unsupported taproot sighash type");
    }
    const annexPresent = annex !== null;
    if (extFlag !== 0 && extFlag !== 1) {
      throw new Error("invalid taproot ext_flag");
    }
    if (extFlag === 1 && (tapleafHashValue === null || tapleafHashValue.length !== 32)) {
      throw new Error("tapscript sighash requires 32-byte tapleaf_hash");
    }

    const epoch = Buffer.from([0]);
    const outputMode =
      hashType === TAPROOT_SIGHASH_DEFAULT ? TAPROOT_SIGHASH_ALL : hashType & 0x03;
    const anyoneCanPay = (hashType & 0x80) !== 0;

    const bodyParts: Buffer[] = [Buffer.from([hashType])];
    bodyParts.push(packInt32Le(transaction.version));
    bodyParts.push(packInt32Le(transaction.lockTime));

    if (!anyoneCanPay) {
      bodyParts.push(this.sharedHash("taproot:prevouts", () => {
        const prevBlob = Buffer.concat(
          transaction.inputs.map((input) => outPointSerialize(input.previousOutput)),
        );
        return sha256Concat([prevBlob]);
      }));
      bodyParts.push(this.sharedHash("taproot:amounts", () => {
        const amountsBlob = Buffer.concat(
          spentPrevouts.map(([amount]) => {
            const buf = Buffer.allocUnsafe(8);
            buf.writeBigInt64LE(BigInt(amount), 0);
            return buf;
          }),
        );
        return sha256Concat([amountsBlob]);
      }));
      bodyParts.push(this.sharedHash("taproot:scripts", () => {
        const scriptBlob = Buffer.concat(
          spentPrevouts.map(([, scriptPubKey]) =>
            Buffer.concat([writeCompactSize(scriptPubKey.length), scriptPubKey]),
          ),
        );
        return sha256Concat([scriptBlob]);
      }));
      bodyParts.push(this.sharedHash("taproot:sequences", () => {
        const sequencesBlob = Buffer.concat(
          transaction.inputs.map((input) => packInt32Le(input.sequence)),
        );
        return sha256Concat([sequencesBlob]);
      }));
    } else if (inputIndex >= transaction.inputs.length) {
      throw new Error("input_index out of range");
    }

    if (outputMode === TAPROOT_SIGHASH_ALL) {
      bodyParts.push(this.sharedHash("taproot:outputs:all", () => {
        const outsBlob = Buffer.concat(transaction.outputs.map((output) => txOutSerialize(output)));
        return sha256Concat([outsBlob]);
      }));
    } else if (outputMode === TAPROOT_SIGHASH_SINGLE) {
      if (inputIndex >= transaction.outputs.length) {
        throw new Error("SIGHASH_SINGLE without matching output");
      }
    }

    const spendType = (extFlag << 1) + (annexPresent ? 1 : 0);
    bodyParts.push(Buffer.from([spendType]));

    if (anyoneCanPay) {
      const txIn = transaction.inputs[inputIndex]!;
      const [amount, scriptPubKey] = spentPrevouts[inputIndex]!;
      bodyParts.push(outPointSerialize(txIn.previousOutput));
      bodyParts.push(txOutSerialize({ value: amount, scriptPubKey }));
      bodyParts.push(packInt32Le(txIn.sequence));
    } else {
      bodyParts.push(packInt32Le(inputIndex));
    }

    if (annexPresent) {
      bodyParts.push(taprootAnnexDigest(annex ?? Buffer.alloc(0)));
    }

    if (outputMode === TAPROOT_SIGHASH_SINGLE) {
      bodyParts.push(this.sharedHash(`taproot:outputs:single:${inputIndex}`, () =>
        createHash("sha256").update(txOutSerialize(transaction.outputs[inputIndex]!)).digest(),
      ));
    }

    if (extFlag === 1) {
      bodyParts.push(tapleafHashValue!);
      bodyParts.push(Buffer.from([0]));
      bodyParts.push(packInt32Le(tapscriptCodeseparatorPos & 0xffffffff));
    }

    const sigmsg = Buffer.concat([epoch, Buffer.concat(bodyParts)]);
    return bitcoinTaggedHash("TapSighash", sigmsg);
  }
}

function legacySighashUncached(
  transaction: Transaction,
  inputIndex: number,
  scriptCode: Buffer,
  sighashType = 1,
): Buffer {
  if (inputIndex >= transaction.inputs.length) {
    throw new Error("input_index out of range");
  }

  const baseType = sighashType & 0x1f;
  const anyoneCanPay = (sighashType & 0x80) !== 0;

  if (baseType === 3 && inputIndex >= transaction.outputs.length) {
    return Buffer.concat([Buffer.from([0x01]), Buffer.alloc(31, 0)]);
  }

  const inputs = anyoneCanPay ? [transaction.inputs[inputIndex]!] : transaction.inputs;
  const parts: Buffer[] = [packInt32Le(transaction.version)];
  parts.push(writeCompactSize(inputs.length));

  for (let index = 0; index < inputs.length; index += 1) {
    const sourceIndex = anyoneCanPay ? inputIndex : index;
    parts.push(outPointSerialize(inputs[index]!.previousOutput));
    if (sourceIndex === inputIndex) {
      parts.push(writeCompactSize(scriptCode.length));
      parts.push(scriptCode);
    } else {
      parts.push(Buffer.from([0x00]));
    }
    if (baseType === 1 || sourceIndex === inputIndex) {
      parts.push(packInt32Le(transaction.inputs[sourceIndex]!.sequence));
    } else {
      parts.push(Buffer.alloc(4));
    }
  }

  if (baseType === 2) {
    parts.push(writeCompactSize(0));
  } else if (baseType === 3) {
    parts.push(writeCompactSize(inputIndex + 1));
    for (let index = 0; index < inputIndex; index += 1) {
      parts.push(txOutSerialize({ value: -1, scriptPubKey: Buffer.alloc(0) }));
    }
    parts.push(txOutSerialize(transaction.outputs[inputIndex]!));
  } else {
    parts.push(writeCompactSize(transaction.outputs.length));
    for (const output of transaction.outputs) {
      parts.push(txOutSerialize(output));
    }
  }

  parts.push(packInt32Le(transaction.lockTime));
  parts.push(packInt32Le(sighashType));
  return doubleSha256(Buffer.concat(parts));
}

export function bip143Sighash(
  transaction: Transaction,
  inputIndex: number,
  scriptCode: Buffer,
  amount: number,
  sighashType = 1,
): Buffer {
  return new TransactionSighashCache(transaction).bip143Sighash(inputIndex, scriptCode, amount, sighashType);
}

export function tapleafHash(leafVersion: number, tapscriptBytes: Buffer): Buffer {
  const msg = Buffer.concat([
    Buffer.from([leafVersion & 0xff]),
    writeCompactSize(tapscriptBytes.length),
    tapscriptBytes,
  ]);
  return bitcoinTaggedHash("TapLeaf", msg);
}

export function tapbranchHash(left: Buffer, right: Buffer): Buffer {
  const pair = Buffer.compare(left, right) < 0 ? Buffer.concat([left, right]) : Buffer.concat([right, left]);
  return bitcoinTaggedHash("TapBranch", pair);
}

export function taprootTweakPubkeyHash(internalPubkeyXonly: Buffer, merkleRoot: Buffer): Buffer {
  return bitcoinTaggedHash("TapTweak", Buffer.concat([internalPubkeyXonly, merkleRoot]));
}

export function taprootMerkleRootFromBranch(branchNodes: readonly Buffer[], leafHash: Buffer): Buffer {
  let k = leafHash;
  for (const sibling of branchNodes) {
    k = tapbranchHash(k, sibling);
  }
  return k;
}

function taprootAllowedHashtypes(hashType: number): boolean {
  return hashType <= 0x03 || (hashType >= 0x81 && hashType <= 0x83);
}

function taprootAnnexDigest(annex: Buffer): Buffer {
  return createHash("sha256").update(Buffer.concat([writeCompactSize(annex.length), annex])).digest();
}

function sha256Concat(parts: readonly Buffer[]): Buffer {
  return createHash("sha256").update(Buffer.concat(parts)).digest();
}

export function taprootSignatureHash(
  transaction: Transaction,
  inputIndex: number,
  spentPrevouts: readonly (readonly [number, Buffer])[],
  options: {
    hashType: number;
    annex?: Buffer | null;
    extFlag?: number;
    tapleafHash?: Buffer | null;
    tapscriptCodeseparatorPos?: number;
  },
): Buffer {
  return new TransactionSighashCache(transaction, spentPrevouts).taprootSignatureHash(inputIndex, options);
}

export function serializedWitnessStackBytes(stack: readonly Buffer[]): Buffer {
  const parts: Buffer[] = [writeCompactSize(stack.length)];
  for (const item of stack) {
    parts.push(writeCompactSize(item.length));
    parts.push(item);
  }
  return Buffer.concat(parts);
}

export function readPush(data: Buffer, offset: number): [Buffer, number] {
  const opcode = data[offset]!;
  offset += 1;
  if (opcode === 0x00) return [Buffer.alloc(0), offset];
  if (opcode >= 0x51 && opcode <= 0x60) {
    return [Buffer.from([opcode - 0x51 + 1]), offset];
  }
  if (opcode === 0x4f) return [Buffer.from([0x81]), offset];
  if (opcode >= 1 && opcode <= 75) {
    return [data.subarray(offset, offset + opcode), offset + opcode];
  }
  if (opcode === 0x4c) {
    const size = data.readUInt8(offset);
    offset += 1;
    return [data.subarray(offset, offset + size), offset + size];
  }
  if (opcode === 0x4d) {
    const size = data.readUInt16LE(offset);
    offset += 2;
    return [data.subarray(offset, offset + size), offset + size];
  }
  if (opcode === 0x4e) {
    const size = data.readUInt32LE(offset);
    offset += 4;
    return [data.subarray(offset, offset + size), offset + size];
  }
  throw new Error(`unsupported push opcode 0x${opcode.toString(16)}`);
}
