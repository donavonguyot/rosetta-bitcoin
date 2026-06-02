import {
  packInt32Le,
  readCompactSize,
  unpackInt32Le,
  unpackInt64Le,
  unpackUint32Le,
  writeCompactSize,
} from "../wire/serialize.js";

export const WITNESS_MARKER = Buffer.from([0x00, 0x01]);

export interface OutPoint {
  hash: Buffer;
  index: number;
}

export interface TxIn {
  previousOutput: OutPoint;
  scriptSig: Buffer;
  sequence: number;
}

export interface TxOut {
  value: number;
  scriptPubKey: Buffer;
}

export interface Transaction {
  version: number;
  inputs: TxIn[];
  outputs: TxOut[];
  lockTime: number;
  witness: Buffer[][];
}

export function outPointSerialize(outpoint: OutPoint): Buffer {
  return Buffer.concat([outpoint.hash, packInt32Le(outpoint.index)]);
}

export function txInSerialize(input: TxIn): Buffer {
  return Buffer.concat([
    outPointSerialize(input.previousOutput),
    writeCompactSize(input.scriptSig.length),
    input.scriptSig,
    packInt32Le(input.sequence),
  ]);
}

export function txOutSerialize(output: TxOut): Buffer {
  return Buffer.concat([
    (() => {
      const buf = Buffer.allocUnsafe(8);
      buf.writeBigInt64LE(BigInt(output.value), 0);
      return buf;
    })(),
    writeCompactSize(output.scriptPubKey.length),
    output.scriptPubKey,
  ]);
}

export function transactionIsCoinbase(tx: Transaction): boolean {
  return (
    tx.inputs.length === 1 &&
    tx.inputs[0]!.previousOutput.hash.equals(Buffer.alloc(32, 0)) &&
    tx.inputs[0]!.previousOutput.index === 0xffff_ffff
  );
}

export function transactionSerialize(tx: Transaction, options: { includeWitness?: boolean } = {}): Buffer {
  const parts: Buffer[] = [packInt32Le(tx.version)];
  const useWitness = Boolean(options.includeWitness && tx.witness.length > 0);
  if (useWitness) {
    parts.push(WITNESS_MARKER);
  }
  parts.push(writeCompactSize(tx.inputs.length));
  for (const input of tx.inputs) {
    parts.push(txInSerialize(input));
  }
  parts.push(writeCompactSize(tx.outputs.length));
  for (const output of tx.outputs) {
    parts.push(txOutSerialize(output));
  }
  if (useWitness) {
    for (const stack of tx.witness) {
      parts.push(writeCompactSize(stack.length));
      for (const item of stack) {
        parts.push(writeCompactSize(item.length));
        parts.push(item);
      }
    }
  }
  parts.push(packInt32Le(tx.lockTime));
  return Buffer.concat(parts);
}

export function transactionDeserialize(
  data: Buffer,
  offset = 0,
): [Transaction, number] {
  const start = offset;
  const [version, afterVersion] = unpackInt32Le(data, offset);
  offset = afterVersion;
  let witnessFlag = false;
  if (offset + 1 < data.length && data.subarray(offset, offset + 2).equals(WITNESS_MARKER)) {
    witnessFlag = true;
    offset += 2;
  }
  const [inputCount, afterInputCount] = readCompactSize(data, offset);
  offset = afterInputCount;
  const inputs: TxIn[] = [];
  for (let index = 0; index < inputCount; index += 1) {
    const prevHash = data.subarray(offset, offset + 32);
    offset += 32;
    const [inputIndex, afterInputIndex] = unpackUint32Le(data, offset);
    offset = afterInputIndex;
    const [scriptLen, afterScriptLen] = readCompactSize(data, offset);
    offset = afterScriptLen;
    const scriptSig = data.subarray(offset, offset + scriptLen);
    offset += scriptLen;
    const [sequence, afterSequence] = unpackInt32Le(data, offset);
    offset = afterSequence;
    inputs.push({
      previousOutput: { hash: prevHash, index: inputIndex },
      scriptSig,
      sequence,
    });
  }
  const [outputCount, afterOutputCount] = readCompactSize(data, offset);
  offset = afterOutputCount;
  const outputs: TxOut[] = [];
  for (let index = 0; index < outputCount; index += 1) {
    const [value, afterValue] = unpackInt64Le(data, offset);
    offset = afterValue;
    const [scriptLen, afterScriptLen] = readCompactSize(data, offset);
    offset = afterScriptLen;
    const scriptPubKey = data.subarray(offset, offset + scriptLen);
    offset += scriptLen;
    outputs.push({ value: Number(value), scriptPubKey });
  }
  const witness: Buffer[][] = [];
  if (witnessFlag) {
    for (let index = 0; index < inputCount; index += 1) {
      const [stackCount, afterStackCount] = readCompactSize(data, offset);
      offset = afterStackCount;
      const stack: Buffer[] = [];
      for (let stackIndex = 0; stackIndex < stackCount; stackIndex += 1) {
        const [itemLen, afterItemLen] = readCompactSize(data, offset);
        offset = afterItemLen;
        stack.push(data.subarray(offset, offset + itemLen));
        offset += itemLen;
      }
      witness.push(stack);
    }
  }
  const [lockTime, end] = unpackInt32Le(data, offset);
  if (end < start) {
    throw new Error("transaction deserialization underflow");
  }
  return [
    {
      version,
      inputs,
      outputs,
      lockTime,
      witness,
    },
    end,
  ];
}

export class TransactionMessageCodec {
  static readonly COMMAND = "tx";

  static serialize(transaction: Transaction): Buffer {
    return transactionSerialize(transaction, { includeWitness: true });
  }

  static deserialize(payload: Buffer): Transaction {
    const [transaction] = transactionDeserialize(payload, 0);
    return transaction;
  }
}
