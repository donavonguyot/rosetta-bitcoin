import { hash160, sha256Digest } from "../../src/consensus/hash.js";
import { transactionTxid } from "../../src/consensus/merkle.js";
import { p2pkhScriptCode } from "../../src/consensus/script/interpreter.js";
import { bip143Sighash, legacySighash } from "../../src/consensus/script/sighash.js";
import {
  OP_CHECKLOCKTIMEVERIFY,
  OP_CHECKMULTISIG,
  OP_CHECKSEQUENCEVERIFY,
  OP_CHECKSIG,
  OP_DUP,
  OP_EQUAL,
  OP_EQUALVERIFY,
  OP_HASH160,
} from "../../src/consensus/script/opcodes.js";
import { Gx, Gy, scalarMult, signDer } from "../../src/consensus/secp256k1.js";
import type { NativeNodeState } from "../../src/runtime/nodeState.js";
import { TESTNET4 } from "../../src/chain/params.js";
import type { Transaction } from "../../src/messages/transaction.js";

export function pushData(data: Buffer): Buffer {
  if (data.length < 0x4c) {
    return Buffer.concat([Buffer.from([data.length]), data]);
  }
  return Buffer.concat([Buffer.from([0x4c, data.length]), data]);
}

function opN(value: number): number {
  if (value >= 1 && value <= 16) return 0x50 + value;
  throw new Error(`OP_n out of range: ${value}`);
}

export function pushScriptNum(value: number): Buffer {
  if (value === 0) return Buffer.from([0x00]);
  if (value >= 1 && value <= 16) return Buffer.from([opN(value)]);
  let byteLen = 0;
  let remaining = value;
  while (remaining > 0) {
    byteLen += 1;
    remaining = Math.floor(remaining / 256);
  }
  const encoded = Buffer.allocUnsafe(byteLen);
  encoded.writeUIntLE(value, 0, byteLen);
  return pushData(encoded);
}

export function p2shScriptPubKey(scriptHash160: Buffer): Buffer {
  return Buffer.concat([
    Buffer.from([OP_HASH160, 0x14]),
    scriptHash160,
    Buffer.from([OP_EQUAL]),
  ]);
}

export function cltvRedeemScript(locktimeValue: number, pubkey: Buffer): Buffer {
  return Buffer.concat([
    pushScriptNum(locktimeValue),
    Buffer.from([OP_CHECKLOCKTIMEVERIFY, 0x75]),
    pushData(pubkey),
    Buffer.from([OP_CHECKSIG]),
  ]);
}

export function csvRedeemScript(sequenceValue: number, pubkey: Buffer): Buffer {
  return Buffer.concat([
    pushScriptNum(sequenceValue),
    Buffer.from([OP_CHECKSEQUENCEVERIFY, 0x75]),
    pushData(pubkey),
    Buffer.from([OP_CHECKSIG]),
  ]);
}

export function multisigRedeemScript(required: number, pubkeys: readonly Buffer[]): Buffer {
  const parts: Buffer[] = [Buffer.from([opN(required)])];
  for (const pubkey of pubkeys) {
    parts.push(pushData(pubkey));
  }
  parts.push(Buffer.from([opN(pubkeys.length), OP_CHECKMULTISIG]));
  return Buffer.concat(parts);
}

export function p2pkhScriptPubKey(pubkeyHash: Buffer): Buffer {
  return Buffer.concat([
    Buffer.from([OP_DUP, OP_HASH160, 0x14]),
    pubkeyHash,
    Buffer.from([OP_EQUALVERIFY, OP_CHECKSIG]),
  ]);
}

export function p2pkScriptPubKey(pubkey: Buffer): Buffer {
  return Buffer.concat([pushData(pubkey), Buffer.from([OP_CHECKSIG])]);
}

export function testPubkeySec1(privateKey = 1n): Buffer {
  const point = scalarMult(privateKey, [Gx, Gy]);
  if (point === null) {
    throw new Error("invalid private key");
  }
  return Buffer.concat([Buffer.from([0x02 + Number(point[1] % 2n)]), Buffer.from(point[0].toString(16).padStart(64, "0"), "hex")]);
}

export function fundP2pkhUtxo(
  tracker: NativeNodeState,
  prevout: Buffer,
  pubkey: Buffer,
  value: number,
): void {
  tracker.addUtxo(TESTNET4.name, prevout, 0, {
    height: 12,
    value,
    scriptPubKey: p2pkhScriptPubKey(hash160(pubkey)),
    coinbase: false,
  });
}

export function fundUtxo(tracker: NativeNodeState, prevout: Buffer, value: number): void {
  tracker.addUtxo(TESTNET4.name, prevout, 0, {
    height: 12,
    value,
    scriptPubKey: Buffer.from([0x51]),
    coinbase: false,
  });
}

export function makeSignedP2pkSpend(options: {
  privateKey: bigint;
  prevTxid: Buffer;
  prevVout?: number;
  prevAmount: number;
  pubkey: Buffer;
  outputValue: number;
}): [Transaction, Buffer] {
  const scriptPubKey = p2pkScriptPubKey(options.pubkey);
  const unsigned: Transaction = {
    version: 1,
    inputs: [
      {
        previousOutput: { hash: options.prevTxid, index: options.prevVout ?? 0 },
        scriptSig: Buffer.alloc(0),
        sequence: 0xffff_ffff,
      },
    ],
    outputs: [{ value: options.outputValue, scriptPubKey: Buffer.from([0x51]) }],
    lockTime: 0,
    witness: [],
  };
  const sighash = legacySighash(unsigned, 0, scriptPubKey, 1);
  const signature = Buffer.concat([signDer(options.privateKey, sighash), Buffer.from([1])]);
  const scriptSig = pushData(signature);
  const signed: Transaction = {
    version: unsigned.version,
    inputs: [
      {
        previousOutput: unsigned.inputs[0]!.previousOutput,
        scriptSig,
        sequence: unsigned.inputs[0]!.sequence,
      },
    ],
    outputs: unsigned.outputs,
    lockTime: unsigned.lockTime,
    witness: [],
  };
  return [signed, scriptPubKey];
}

export function makeSignedP2pkhSpend(options: {
  privateKey: bigint;
  prevTxid: Buffer;
  prevVout?: number;
  prevAmount: number;
  pubkey: Buffer;
  outputValue: number;
  outputScriptPubKey?: Buffer;
}): [Transaction, Buffer] {
  const scriptPubKey = p2pkhScriptPubKey(hash160(options.pubkey));
  const outputScriptPubKey = options.outputScriptPubKey ?? Buffer.from([0x51]);
  const unsigned: Transaction = {
    version: 1,
    inputs: [
      {
        previousOutput: { hash: options.prevTxid, index: options.prevVout ?? 0 },
        scriptSig: Buffer.alloc(0),
        sequence: 0xffff_ffff,
      },
    ],
    outputs: [{ value: options.outputValue, scriptPubKey: outputScriptPubKey }],
    lockTime: 0,
    witness: [],
  };
  const sighash = legacySighash(unsigned, 0, scriptPubKey, 1);
  const signature = Buffer.concat([signDer(options.privateKey, sighash), Buffer.from([1])]);
  const scriptSig = Buffer.concat([pushData(signature), pushData(options.pubkey)]);
  const signed: Transaction = {
    version: unsigned.version,
    inputs: [
      {
        previousOutput: unsigned.inputs[0]!.previousOutput,
        scriptSig,
        sequence: unsigned.inputs[0]!.sequence,
      },
    ],
    outputs: unsigned.outputs,
    lockTime: unsigned.lockTime,
    witness: [],
  };
  return [signed, scriptPubKey];
}

export function signedP2pkhRoundtrip(
  privateKey: bigint,
  prevTxid: Buffer,
  inputValue: number,
  outputValue: number,
): Transaction {
  const pubkey = testPubkeySec1(privateKey);
  const [signed] = makeSignedP2pkhSpend({
    privateKey,
    prevTxid,
    prevAmount: inputValue,
    pubkey,
    outputValue,
  });
  return signed;
}

export function spendPrev(prevout: Buffer, outputValue: number): Transaction {
  return {
    version: 2,
    inputs: [
      {
        previousOutput: { hash: prevout, index: 0 },
        scriptSig: Buffer.alloc(0),
        sequence: 0xffff_ffff,
      },
    ],
    outputs: [{ value: outputValue, scriptPubKey: Buffer.from([0x51]) }],
    lockTime: 0,
    witness: [],
  };
}

export function sampleTx(prev?: Buffer): Transaction {
  const hash = prev ?? Buffer.alloc(32, 0xab);
  return {
    version: 2,
    inputs: [
      {
        previousOutput: { hash, index: 0 },
        scriptSig: Buffer.alloc(0),
        sequence: 0xffff_ffff,
      },
    ],
    outputs: [{ value: 1234, scriptPubKey: Buffer.from([0x51]) }],
    lockTime: 0,
    witness: [],
  };
}

export function signedParentChildChain(options: {
  prevCoin: Buffer;
  coinAmt: number;
  parentToChildValue: number;
  childRemainderValue: number;
  privateKey: bigint;
  pubkey: Buffer;
}): [Transaction, Transaction] {
  const redeem = p2pkhScriptPubKey(hash160(options.pubkey));
  const [parentSigned] = makeSignedP2pkhSpend({
    privateKey: options.privateKey,
    prevTxid: options.prevCoin,
    prevAmount: options.coinAmt,
    pubkey: options.pubkey,
    outputValue: options.parentToChildValue,
    outputScriptPubKey: redeem,
  });
  const parentId = transactionTxid(parentSigned);
  const [childSigned] = makeSignedP2pkhSpend({
    privateKey: options.privateKey,
    prevTxid: parentId,
    prevAmount: options.parentToChildValue,
    pubkey: options.pubkey,
    outputValue: options.childRemainderValue,
  });
  return [parentSigned, childSigned];
}

export function makeSignedP2wpkhSpend(options: {
  privateKey: bigint;
  prevTxid: Buffer;
  prevVout?: number;
  prevAmount: number;
  pubkey: Buffer;
  outputValue: number;
}): [Transaction, Buffer] {
  const pubkeyHash = hash160(options.pubkey);
  const scriptPubKey = Buffer.concat([Buffer.from([0x00, 0x14]), pubkeyHash]);
  const scriptCode = p2pkhScriptCode(pubkeyHash);
  const unsigned: Transaction = {
    version: 1,
    inputs: [
      {
        previousOutput: { hash: options.prevTxid, index: options.prevVout ?? 0 },
        scriptSig: Buffer.alloc(0),
        sequence: 0xffff_ffff,
      },
    ],
    outputs: [{ value: options.outputValue, scriptPubKey: Buffer.from([0x51]) }],
    lockTime: 0,
    witness: [],
  };
  const sighash = bip143Sighash(unsigned, 0, scriptCode, options.prevAmount, 1);
  const signature = Buffer.concat([signDer(options.privateKey, sighash), Buffer.from([1])]);
  const signed: Transaction = {
    version: unsigned.version,
    inputs: unsigned.inputs,
    outputs: unsigned.outputs,
    lockTime: unsigned.lockTime,
    witness: [[signature, options.pubkey]],
  };
  return [signed, scriptPubKey];
}

export function makeSignedP2shP2pkhSpend(options: {
  privateKey: bigint;
  prevTxid: Buffer;
  prevVout?: number;
  prevAmount: number;
  pubkey: Buffer;
  outputValue: number;
}): [Transaction, Buffer] {
  const redeemScript = p2pkhScriptPubKey(hash160(options.pubkey));
  const scriptPubKey = p2shScriptPubKey(hash160(redeemScript));
  const unsigned: Transaction = {
    version: 1,
    inputs: [
      {
        previousOutput: { hash: options.prevTxid, index: options.prevVout ?? 0 },
        scriptSig: Buffer.alloc(0),
        sequence: 0xffff_ffff,
      },
    ],
    outputs: [{ value: options.outputValue, scriptPubKey: Buffer.from([0x51]) }],
    lockTime: 0,
    witness: [],
  };
  const sighash = legacySighash(unsigned, 0, redeemScript, 1);
  const signature = Buffer.concat([signDer(options.privateKey, sighash), Buffer.from([1])]);
  const scriptSig = Buffer.concat([
    pushData(signature),
    pushData(options.pubkey),
    pushData(redeemScript),
  ]);
  const signed: Transaction = {
    version: unsigned.version,
    inputs: [
      {
        previousOutput: unsigned.inputs[0]!.previousOutput,
        scriptSig,
        sequence: unsigned.inputs[0]!.sequence,
      },
    ],
    outputs: unsigned.outputs,
    lockTime: unsigned.lockTime,
    witness: [],
  };
  return [signed, scriptPubKey];
}

export function makeSignedP2wshP2pkhSpend(options: {
  privateKey: bigint;
  prevTxid: Buffer;
  prevVout?: number;
  prevAmount: number;
  pubkey: Buffer;
  outputValue: number;
}): [Transaction, Buffer] {
  const witnessScript = p2pkhScriptPubKey(hash160(options.pubkey));
  const scriptPubKey = Buffer.concat([Buffer.from([0x00, 0x20]), sha256Digest(witnessScript)]);
  const unsigned: Transaction = {
    version: 1,
    inputs: [
      {
        previousOutput: { hash: options.prevTxid, index: options.prevVout ?? 0 },
        scriptSig: Buffer.alloc(0),
        sequence: 0xffff_ffff,
      },
    ],
    outputs: [{ value: options.outputValue, scriptPubKey: Buffer.from([0x51]) }],
    lockTime: 0,
    witness: [],
  };
  const sighash = bip143Sighash(unsigned, 0, witnessScript, options.prevAmount, 1);
  const signature = Buffer.concat([signDer(options.privateKey, sighash), Buffer.from([1])]);
  const signed: Transaction = {
    version: unsigned.version,
    inputs: unsigned.inputs,
    outputs: unsigned.outputs,
    lockTime: unsigned.lockTime,
    witness: [[signature, options.pubkey, witnessScript]],
  };
  return [signed, scriptPubKey];
}

export function makeSignedP2shMultisigSpend(options: {
  privateKeys: readonly bigint[];
  pubkeys: readonly Buffer[];
  required: number;
  prevTxid: Buffer;
  prevVout?: number;
  prevAmount: number;
  outputValue: number;
}): [Transaction, Buffer] {
  const redeemScript = multisigRedeemScript(options.required, options.pubkeys);
  const scriptPubKey = p2shScriptPubKey(hash160(redeemScript));
  const unsigned: Transaction = {
    version: 1,
    inputs: [
      {
        previousOutput: { hash: options.prevTxid, index: options.prevVout ?? 0 },
        scriptSig: Buffer.alloc(0),
        sequence: 0xffff_ffff,
      },
    ],
    outputs: [{ value: options.outputValue, scriptPubKey: Buffer.from([0x51]) }],
    lockTime: 0,
    witness: [],
  };
  const signatures = options.privateKeys.slice(0, options.required).map((privateKey) => {
    const sighash = legacySighash(unsigned, 0, redeemScript, 1);
    return Buffer.concat([signDer(privateKey, sighash), Buffer.from([1])]);
  });
  const scriptSig = Buffer.concat([
    Buffer.from([0x00]),
    ...signatures.map((signature) => pushData(signature)),
    pushData(redeemScript),
  ]);
  const signed: Transaction = {
    version: unsigned.version,
    inputs: [
      {
        previousOutput: unsigned.inputs[0]!.previousOutput,
        scriptSig,
        sequence: unsigned.inputs[0]!.sequence,
      },
    ],
    outputs: unsigned.outputs,
    lockTime: unsigned.lockTime,
    witness: [],
  };
  return [signed, scriptPubKey];
}

export function makeSignedP2wshMultisigSpend(options: {
  privateKeys: readonly bigint[];
  pubkeys: readonly Buffer[];
  required: number;
  prevTxid: Buffer;
  prevVout?: number;
  prevAmount: number;
  outputValue: number;
}): [Transaction, Buffer] {
  const witnessScript = multisigRedeemScript(options.required, options.pubkeys);
  const scriptPubKey = Buffer.concat([Buffer.from([0x00, 0x20]), sha256Digest(witnessScript)]);
  const unsigned: Transaction = {
    version: 1,
    inputs: [
      {
        previousOutput: { hash: options.prevTxid, index: options.prevVout ?? 0 },
        scriptSig: Buffer.alloc(0),
        sequence: 0xffff_ffff,
      },
    ],
    outputs: [{ value: options.outputValue, scriptPubKey: Buffer.from([0x51]) }],
    lockTime: 0,
    witness: [],
  };
  const signatures = options.privateKeys.slice(0, options.required).map((privateKey) => {
    const sighash = bip143Sighash(unsigned, 0, witnessScript, options.prevAmount, 1);
    return Buffer.concat([signDer(privateKey, sighash), Buffer.from([1])]);
  });
  const signed: Transaction = {
    version: unsigned.version,
    inputs: unsigned.inputs,
    outputs: unsigned.outputs,
    lockTime: unsigned.lockTime,
    witness: [[Buffer.alloc(0), ...signatures, witnessScript]],
  };
  return [signed, scriptPubKey];
}

export function makeSignedP2shCltvSpend(options: {
  privateKey: bigint;
  pubkey: Buffer;
  locktimeValue: number;
  txLockTime: number;
  inputSequence: number;
  prevTxid: Buffer;
  prevVout?: number;
  prevAmount: number;
  outputValue: number;
}): [Transaction, Buffer] {
  const redeemScript = cltvRedeemScript(options.locktimeValue, options.pubkey);
  const scriptPubKey = p2shScriptPubKey(hash160(redeemScript));
  const unsigned: Transaction = {
    version: 2,
    inputs: [
      {
        previousOutput: { hash: options.prevTxid, index: options.prevVout ?? 0 },
        scriptSig: Buffer.alloc(0),
        sequence: options.inputSequence,
      },
    ],
    outputs: [{ value: options.outputValue, scriptPubKey: Buffer.from([0x51]) }],
    lockTime: options.txLockTime,
    witness: [],
  };
  const sighash = legacySighash(unsigned, 0, redeemScript, 1);
  const signature = Buffer.concat([signDer(options.privateKey, sighash), Buffer.from([1])]);
  const scriptSig = Buffer.concat([pushData(signature), pushData(redeemScript)]);
  const signed: Transaction = {
    version: unsigned.version,
    inputs: [
      {
        previousOutput: unsigned.inputs[0]!.previousOutput,
        scriptSig,
        sequence: unsigned.inputs[0]!.sequence,
      },
    ],
    outputs: unsigned.outputs,
    lockTime: unsigned.lockTime,
    witness: [],
  };
  return [signed, scriptPubKey];
}

export function makeSignedP2wshCltvSpend(options: {
  privateKey: bigint;
  pubkey: Buffer;
  locktimeValue: number;
  txLockTime: number;
  inputSequence: number;
  prevTxid: Buffer;
  prevVout?: number;
  prevAmount: number;
  outputValue: number;
}): [Transaction, Buffer] {
  const witnessScript = cltvRedeemScript(options.locktimeValue, options.pubkey);
  const scriptPubKey = Buffer.concat([Buffer.from([0x00, 0x20]), sha256Digest(witnessScript)]);
  const unsigned: Transaction = {
    version: 2,
    inputs: [
      {
        previousOutput: { hash: options.prevTxid, index: options.prevVout ?? 0 },
        scriptSig: Buffer.alloc(0),
        sequence: options.inputSequence,
      },
    ],
    outputs: [{ value: options.outputValue, scriptPubKey: Buffer.from([0x51]) }],
    lockTime: options.txLockTime,
    witness: [],
  };
  const sighash = bip143Sighash(unsigned, 0, witnessScript, options.prevAmount, 1);
  const signature = Buffer.concat([signDer(options.privateKey, sighash), Buffer.from([1])]);
  const signed: Transaction = {
    version: unsigned.version,
    inputs: unsigned.inputs,
    outputs: unsigned.outputs,
    lockTime: unsigned.lockTime,
    witness: [[signature, witnessScript]],
  };
  return [signed, scriptPubKey];
}

export function makeSignedP2shCsvSpend(options: {
  privateKey: bigint;
  pubkey: Buffer;
  csvOperand: number;
  inputSequence: number;
  prevTxid: Buffer;
  prevVout?: number;
  prevAmount: number;
  outputValue: number;
}): [Transaction, Buffer] {
  const redeemScript = csvRedeemScript(options.csvOperand, options.pubkey);
  const scriptPubKey = p2shScriptPubKey(hash160(redeemScript));
  const unsigned: Transaction = {
    version: 2,
    inputs: [
      {
        previousOutput: { hash: options.prevTxid, index: options.prevVout ?? 0 },
        scriptSig: Buffer.alloc(0),
        sequence: options.inputSequence,
      },
    ],
    outputs: [{ value: options.outputValue, scriptPubKey: Buffer.from([0x51]) }],
    lockTime: 0,
    witness: [],
  };
  const sighash = legacySighash(unsigned, 0, redeemScript, 1);
  const signature = Buffer.concat([signDer(options.privateKey, sighash), Buffer.from([1])]);
  const scriptSig = Buffer.concat([pushData(signature), pushData(redeemScript)]);
  const signed: Transaction = {
    version: unsigned.version,
    inputs: [
      {
        previousOutput: unsigned.inputs[0]!.previousOutput,
        scriptSig,
        sequence: unsigned.inputs[0]!.sequence,
      },
    ],
    outputs: unsigned.outputs,
    lockTime: unsigned.lockTime,
    witness: [],
  };
  return [signed, scriptPubKey];
}

export function makeSignedP2wshCsvSpend(options: {
  privateKey: bigint;
  pubkey: Buffer;
  csvOperand: number;
  inputSequence: number;
  prevTxid: Buffer;
  prevVout?: number;
  prevAmount: number;
  outputValue: number;
}): [Transaction, Buffer] {
  const witnessScript = csvRedeemScript(options.csvOperand, options.pubkey);
  const scriptPubKey = Buffer.concat([Buffer.from([0x00, 0x20]), sha256Digest(witnessScript)]);
  const unsigned: Transaction = {
    version: 2,
    inputs: [
      {
        previousOutput: { hash: options.prevTxid, index: options.prevVout ?? 0 },
        scriptSig: Buffer.alloc(0),
        sequence: options.inputSequence,
      },
    ],
    outputs: [{ value: options.outputValue, scriptPubKey: Buffer.from([0x51]) }],
    lockTime: 0,
    witness: [],
  };
  const sighash = bip143Sighash(unsigned, 0, witnessScript, options.prevAmount, 1);
  const signature = Buffer.concat([signDer(options.privateKey, sighash), Buffer.from([1])]);
  const signed: Transaction = {
    version: unsigned.version,
    inputs: unsigned.inputs,
    outputs: unsigned.outputs,
    lockTime: unsigned.lockTime,
    witness: [[signature, witnessScript]],
  };
  return [signed, scriptPubKey];
}
