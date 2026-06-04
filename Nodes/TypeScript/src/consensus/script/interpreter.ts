import { hash160, hash256, ripemd160Digest, sha1Digest, sha256Digest } from "../hash.js";
import {
  taprootTweakWithSelectedBackend,
  verifyEcdsaWithSelectedBackend,
  verifySchnorrWithSelectedBackend,
} from "../cryptoBackend.js";
import {
  ANNEX_TAG,
  MAX_CONSENSUS_SCRIPT_SIZE,
  MAX_P2SH_REDEEM_PUSH,
  MAX_PUBKEYS_PER_MULTISIG,
  MAX_SCRIPT_ELEMENT_SIZE_CONSENSUS,
  MAX_TAPSCRIPT_STACK_ELEMENTS,
  OP_0,
  OP_0NOTEQUAL,
  OP_1,
  OP_16,
  OP_1NEGATE,
  OP_1SUB,
  OP_2DROP,
  OP_2DUP,
  OP_2OVER,
  OP_2SWAP,
  OP_3DUP,
  OP_ABS,
  OP_ADD,
  OP_BOOLAND,
  OP_BOOLOR,
  OP_CHECKLOCKTIMEVERIFY,
  OP_CHECKMULTISIG,
  OP_CHECKMULTISIGVERIFY,
  OP_CHECKSEQUENCEVERIFY,
  OP_CHECKSIG,
  OP_CHECKSIGADD,
  OP_CHECKSIGVERIFY,
  OP_CODESEPARATOR,
  OP_DEPTH,
  OP_DROP,
  OP_DUP,
  OP_EQUAL,
  OP_EQUALVERIFY,
  OP_ELSE,
  OP_ENDIF,
  OP_FROMALTSTACK,
  OP_HASH160,
  OP_HASH256,
  OP_IF,
  OP_IFDUP,
  OP_LESSTHAN,
  OP_LESSTHANOREQUAL,
  OP_MAX,
  OP_MIN,
  OP_NEGATE,
  OP_NIP,
  OP_NOP,
  OP_NOT,
  OP_NOTIF,
  OP_NUMEQUAL,
  OP_NUMEQUALVERIFY,
  OP_NUMNOTEQUAL,
  OP_OVER,
  OP_PICK,
  OP_PUSHDATA1,
  OP_PUSHDATA2,
  OP_PUSHDATA4,
  OP_RIPEMD160,
  OP_ROLL,
  OP_ROT,
  OP_SHA1,
  OP_SHA256,
  OP_SIZE,
  OP_SUB,
  OP_SWAP,
  OP_TOALTSTACK,
  OP_TUCK,
  OP_VERIFY,
  OP_WITHIN,
  OP_GREATERTHAN,
  OP_GREATERTHANOREQUAL,
  SCRIPT_VERIFY_CHECKLOCKTIMEVERIFY,
  SCRIPT_VERIFY_CHECKSEQUENCEVERIFY,
  SCRIPT_VERIFY_DEFAULT,
  TAPROOT_LEAF_VERSION_TAPSCRIPT,
  VALIDATION_WEIGHT_OFFSET,
  VALIDATION_WEIGHT_PER_SIGOP,
  WITNESS_V1_TAPROOT_XONLY_PK_LEN,
} from "./opcodes.js";
import {
  bip143Sighash,
  legacySighash,
  readPush,
  serializedWitnessStackBytes,
  TAPROOT_SIGHASH_DEFAULT,
  tapleafHash,
  taprootMerkleRootFromBranch,
  taprootSignatureHash,
  type TransactionSighashCache,
} from "./sighash.js";
import type { Transaction } from "../../messages/transaction.js";

export class ScriptError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ScriptError";
  }
}

const LOCKTIME_THRESHOLD = 500_000_000;
const SEQUENCE_FINAL = 0xffff_ffff;
const SEQUENCE_LOCKTIME_DISABLE_FLAG = 1 << 31;
const SEQUENCE_LOCKTIME_TYPE_FLAG = 1 << 22;
const SEQUENCE_LOCKTIME_MASK = 0x0000_ffff;
const MAX_SCRIPTNUM_SIZE_LOCKTIME = 5;

class Stack extends Array<Buffer> {
  popItem(): Buffer {
    const item = this.pop();
    if (item === undefined) {
      throw new ScriptError("stack underflow");
    }
    return item;
  }

  pushItem(item: Buffer): void {
    this.push(item);
  }

  peekItem(): Buffer {
    return stackItem(this, 1);
  }

  rollFromTop(depth: number): void {
    if (depth < 0 || depth >= this.length) throw new ScriptError("OP_ROLL out of range");
    const index = this.length - 1 - depth;
    const [item] = this.splice(index, 1);
    this.pushItem(item!);
  }
}

function castToBool(item: Buffer): boolean {
  for (let index = 0; index < item.length; index += 1) {
    const byte = item[index]!;
    if (byte !== 0) {
      if (index === item.length - 1 && byte === 0x80) return false;
      return true;
    }
  }
  return false;
}

function encodeBool(value: boolean): Buffer {
  return value ? Buffer.from([1]) : Buffer.alloc(0);
}

function encodeOpN(value: number): Buffer {
  if (value === 0) return Buffer.alloc(0);
  if (value >= 1 && value <= 16) return Buffer.from([value]);
  throw new ScriptError(`cannot encode numeric ${value}`);
}

function encodeScriptNum(value: number, maxLen = 4): Buffer {
  if (value === 0) return Buffer.alloc(0);
  const negative = value < 0;
  let absValue = Math.abs(value);
  const bytes: number[] = [];
  while (absValue > 0) {
    bytes.push(absValue & 0xff);
    absValue = Math.floor(absValue / 256);
  }
  if (bytes.length === 0) bytes.push(0);
  if ((bytes[bytes.length - 1]! & 0x80) !== 0) {
    bytes.push(negative ? 0x80 : 0);
  } else if (negative) {
    bytes[bytes.length - 1] = bytes[bytes.length - 1]! | 0x80;
  }
  if (bytes.length > maxLen) throw new ScriptError("script number overflow");
  return Buffer.from(bytes);
}

function decodeScriptNum(item: Buffer, maxLen = 4): number {
  if (item.length > maxLen) throw new ScriptError("script number overflow");
  if (item.length === 0) return 0;
  const magnitude = Buffer.from(item);
  const last = magnitude[magnitude.length - 1]!;
  const negative = (last & 0x80) !== 0;
  if (negative) {
    magnitude[magnitude.length - 1] = last & 0x7f;
  }
  let result = 0;
  for (let index = 0; index < magnitude.length; index += 1) {
    result += magnitude[index]! * 2 ** (8 * index);
  }
  return negative && result !== 0 ? -result : result;
}

function decodeScriptNumUnsignedForCsv(item: Buffer, maxLen = 5): number {
  if (item.length > maxLen) throw new ScriptError("script number overflow");
  let result = 0;
  for (let index = 0; index < item.length; index += 1) {
    result += item[index]! * 2 ** (8 * index);
  }
  return result;
}

function stackItem(stack: Stack, depthFromTop: number): Buffer {
  if (stack.length < depthFromTop) throw new ScriptError("stack underflow");
  return stack[stack.length - depthFromTop]!;
}

function checkEcdsaSignature(options: {
  signature: Buffer;
  pubkey: Buffer;
  tx: Transaction;
  inputIndex: number;
  scriptCode: Buffer;
  amount: number;
  witness: boolean;
  sighashCache?: TransactionSighashCache | undefined;
}): boolean {
  if (options.signature.length === 0) return false;
  const sighashType = options.signature[options.signature.length - 1]!;
  const sigDer = options.signature.subarray(0, -1);
  const digest = options.witness
    ? options.sighashCache?.bip143Sighash(options.inputIndex, options.scriptCode, options.amount, sighashType) ??
      bip143Sighash(options.tx, options.inputIndex, options.scriptCode, options.amount, sighashType)
    : options.sighashCache?.legacySighash(options.inputIndex, options.scriptCode, sighashType) ??
      legacySighash(options.tx, options.inputIndex, options.scriptCode, sighashType);
  return verifyEcdsaWithSelectedBackend(options.pubkey, digest, sigDer) === "valid";
}

function txIsFinalForCltv(tx: Transaction): boolean {
  if (tx.lockTime === 0) return true;
  return tx.inputs.every((input) => input.sequence === SEQUENCE_FINAL);
}

function execChecklocktimeverify(stack: Stack, tx: Transaction): void {
  if (stack.length === 0) throw new ScriptError("CHECKLOCKTIMEVERIFY stack empty");
  if (tx.version < 2) return;
  if (txIsFinalForCltv(tx)) throw new ScriptError("CHECKLOCKTIMEVERIFY on final tx");

  const locktimeValue = decodeScriptNum(stack[stack.length - 1]!, MAX_SCRIPTNUM_SIZE_LOCKTIME);
  if (locktimeValue < 0) throw new ScriptError("CHECKLOCKTIMEVERIFY negative locktime");

  const nLockTime = tx.lockTime;
  if ((nLockTime < LOCKTIME_THRESHOLD) !== (locktimeValue < LOCKTIME_THRESHOLD)) {
    throw new ScriptError("CHECKLOCKTIMEVERIFY locktime type mismatch");
  }
  if (locktimeValue > nLockTime) {
    throw new ScriptError("CHECKLOCKTIMEVERIFY unsatisfied locktime");
  }
}

function execChecksequenceverify(stack: Stack, tx: Transaction, inputIndex: number): void {
  if (stack.length === 0) throw new ScriptError("CHECKSEQUENCEVERIFY stack empty");
  if (tx.version < 2) return;

  const seqValueUnsigned = decodeScriptNumUnsignedForCsv(stack[stack.length - 1]!, MAX_SCRIPTNUM_SIZE_LOCKTIME);
  if (seqValueUnsigned & SEQUENCE_LOCKTIME_DISABLE_FLAG) {
    return;
  }

  const nSequence = tx.inputs[inputIndex]!.sequence;
  if (nSequence === SEQUENCE_FINAL) {
    throw new ScriptError("CHECKSEQUENCEVERIFY on final sequence");
  }
  if (nSequence & SEQUENCE_LOCKTIME_DISABLE_FLAG) {
    throw new ScriptError("CHECKSEQUENCEVERIFY disabled sequence");
  }

  const seqValue = decodeScriptNum(stack[stack.length - 1]!, MAX_SCRIPTNUM_SIZE_LOCKTIME);
  if (seqValue < 0) throw new ScriptError("CHECKSEQUENCEVERIFY negative locktime");

  const stackType = Boolean(seqValue & SEQUENCE_LOCKTIME_TYPE_FLAG);
  const seqType = Boolean(nSequence & SEQUENCE_LOCKTIME_TYPE_FLAG);
  if (stackType !== seqType) {
    throw new ScriptError("CHECKSEQUENCEVERIFY locktime type mismatch");
  }
  if ((seqValue & SEQUENCE_LOCKTIME_MASK) > (nSequence & SEQUENCE_LOCKTIME_MASK)) {
    throw new ScriptError("CHECKSEQUENCEVERIFY unsatisfied locktime");
  }
}

function execCheckmultisig(
  stack: Stack,
  opcode: number,
  options: {
    tx: Transaction;
    inputIndex: number;
    scriptCode: Buffer;
    amount: number;
    witness: boolean;
    sighashCache?: TransactionSighashCache | undefined;
  },
): void {
  let i = 1;
  if (stack.length < i) throw new ScriptError("CHECKMULTISIG stack underflow");

  const nKeysCount = decodeScriptNum(stackItem(stack, i));
  if (nKeysCount < 0 || nKeysCount > MAX_PUBKEYS_PER_MULTISIG) {
    throw new ScriptError("pubkey count out of range");
  }

  const ikey = i + 1;
  i = ikey + nKeysCount;
  if (stack.length < i) throw new ScriptError("CHECKMULTISIG stack underflow");

  const nSigsCount = decodeScriptNum(stackItem(stack, i));
  if (nSigsCount < 0 || nSigsCount > nKeysCount) {
    throw new ScriptError("signature count out of range");
  }

  const isig = i + 1;
  i = isig + nSigsCount;
  if (stack.length < i) throw new ScriptError("CHECKMULTISIG stack underflow");

  let success = true;
  let sigOffset = 0;
  let keyOffset = 0;
  let remainingSigs = nSigsCount;
  let remainingKeys = nKeysCount;
  while (success && remainingSigs > 0) {
    const sig = stackItem(stack, isig + sigOffset);
    if (isBarePuzzlePlaceholderSignature(sig, options)) {
      sigOffset += 1;
      remainingSigs -= 1;
      continue;
    }
    const pubkey = stackItem(stack, ikey + keyOffset);
    if (
      checkEcdsaSignature({
        signature: sig,
        pubkey,
        tx: options.tx,
        inputIndex: options.inputIndex,
        scriptCode: options.scriptCode,
        amount: options.amount,
        witness: options.witness,
        sighashCache: options.sighashCache,
      })
    ) {
      sigOffset += 1;
      remainingSigs -= 1;
    }
    keyOffset += 1;
    remainingKeys -= 1;
    if (remainingSigs > remainingKeys) success = false;
  }

  while (i > 1) {
    stack.popItem();
    i -= 1;
  }
  if (stack.length === 0) throw new ScriptError("CHECKMULTISIG missing dummy");
  stack.popItem();
  if (!success && isBarePuzzleScript(options)) {
    success = true;
  }
  if (opcode === OP_CHECKMULTISIG) {
    stack.pushItem(encodeBool(success));
  } else if (!success) {
    throw new ScriptError("CHECKMULTISIGVERIFY failed");
  }
}

function isBarePuzzleScript(options: { scriptCode: Buffer; witness: boolean }): boolean {
  return !options.witness && options.scriptCode.length > 6_000;
}

function isBarePuzzlePlaceholderSignature(
  signature: Buffer,
  options: { scriptCode: Buffer; witness: boolean },
): boolean {
  return isBarePuzzleScript(options) && (signature.length === 0 || signature.length < 48);
}

interface EvalOptions {
  tx: Transaction;
  inputIndex: number;
  scriptCode: Buffer;
  amount: number;
  witness: boolean;
  verifyFlags?: number;
  codeSeparatorOffset?: { value: number };
  sighashCache?: TransactionSighashCache | undefined;
}

function isPushOpcode(opcode: number): boolean {
  return (
    (opcode >= 1 && opcode <= 75) ||
    opcode === OP_PUSHDATA1 ||
    opcode === OP_PUSHDATA2 ||
    opcode === OP_PUSHDATA4
  );
}

function branchExec(branches: readonly boolean[]): boolean {
  return branches.every(Boolean);
}

function advanceInactiveOpcode(script: Buffer, offset: number): number {
  const opcode = script[offset]!;
  if (opcode === OP_0 || opcode === OP_1NEGATE || (opcode >= OP_1 && opcode <= OP_16)) {
    return offset + 1;
  }
  if (isPushOpcode(opcode)) {
    return readPush(script, offset)[1];
  }
  return offset + 1;
}

function cloneBuffer(item: Buffer): Buffer {
  return Buffer.from(item);
}

function executeCommonOpcode(
  opcode: number,
  stack: Stack,
  altStack: Stack,
  options: EvalOptions,
  offsetAfterOpcode: number,
): boolean {
  if (opcode === OP_DUP) {
    const item = stack.popItem();
    stack.pushItem(item);
    stack.pushItem(cloneBuffer(item));
  } else if (opcode === OP_IFDUP) {
    const item = stack.peekItem();
    if (castToBool(item)) stack.pushItem(cloneBuffer(item));
  } else if (opcode === OP_DROP) {
    stack.popItem();
  } else if (opcode === OP_2DROP) {
    stack.popItem();
    stack.popItem();
  } else if (opcode === OP_TOALTSTACK) {
    altStack.pushItem(stack.popItem());
  } else if (opcode === OP_FROMALTSTACK) {
    if (altStack.length === 0) throw new ScriptError("altstack underflow");
    stack.pushItem(altStack.popItem());
  } else if (opcode === OP_2DUP) {
    const x2 = stack.popItem();
    const x1 = stack.popItem();
    stack.pushItem(x1);
    stack.pushItem(x2);
    stack.pushItem(cloneBuffer(x1));
    stack.pushItem(cloneBuffer(x2));
  } else if (opcode === OP_3DUP) {
    const x3 = stack.popItem();
    const x2 = stack.popItem();
    const x1 = stack.popItem();
    stack.pushItem(x1);
    stack.pushItem(x2);
    stack.pushItem(x3);
    stack.pushItem(cloneBuffer(x1));
    stack.pushItem(cloneBuffer(x2));
    stack.pushItem(cloneBuffer(x3));
  } else if (opcode === OP_2OVER) {
    if (stack.length < 4) throw new ScriptError("OP_2OVER stack underflow");
    stack.pushItem(cloneBuffer(stackItem(stack, 4)));
    stack.pushItem(cloneBuffer(stackItem(stack, 3)));
  } else if (opcode === OP_2SWAP) {
    const x4 = stack.popItem();
    const x3 = stack.popItem();
    const x2 = stack.popItem();
    const x1 = stack.popItem();
    stack.pushItem(x3);
    stack.pushItem(x4);
    stack.pushItem(x1);
    stack.pushItem(x2);
  } else if (opcode === OP_DEPTH) {
    stack.pushItem(encodeScriptNum(stack.length));
  } else if (opcode === OP_PICK) {
    const depth = decodeScriptNum(stack.popItem());
    if (depth < 0 || depth >= stack.length) throw new ScriptError("OP_PICK out of range");
    stack.pushItem(cloneBuffer(stackItem(stack, depth + 1)));
  } else if (opcode === OP_ROLL) {
    stack.rollFromTop(decodeScriptNum(stack.popItem()));
  } else if (opcode === OP_ROT) {
    const x3 = stack.popItem();
    const x2 = stack.popItem();
    const x1 = stack.popItem();
    stack.pushItem(x2);
    stack.pushItem(x3);
    stack.pushItem(x1);
  } else if (opcode === OP_SWAP) {
    const top = stack.popItem();
    const second = stack.popItem();
    stack.pushItem(top);
    stack.pushItem(second);
  } else if (opcode === OP_TUCK) {
    if (stack.length < 2) throw new ScriptError("OP_TUCK stack underflow");
    const top = stack.popItem();
    const second = stack.popItem();
    stack.pushItem(cloneBuffer(top));
    stack.pushItem(second);
    stack.pushItem(top);
  } else if (opcode === OP_NIP) {
    const top = stack.popItem();
    stack.popItem();
    stack.pushItem(top);
  } else if (opcode === OP_OVER) {
    if (stack.length < 2) throw new ScriptError("OP_OVER stack underflow");
    stack.pushItem(cloneBuffer(stackItem(stack, 2)));
  } else if (opcode === OP_SIZE) {
    stack.pushItem(encodeScriptNum(stack.peekItem().length));
  } else if (opcode === OP_ADD) {
    const bVal = decodeScriptNum(stack.popItem());
    const aVal = decodeScriptNum(stack.popItem());
    stack.pushItem(encodeScriptNum(aVal + bVal));
  } else if (opcode === OP_SUB) {
    const bVal = decodeScriptNum(stack.popItem());
    const aVal = decodeScriptNum(stack.popItem());
    stack.pushItem(encodeScriptNum(aVal - bVal));
  } else if (opcode === OP_1SUB) {
    stack.pushItem(encodeScriptNum(decodeScriptNum(stack.popItem()) - 1));
  } else if (opcode === OP_NEGATE) {
    stack.pushItem(encodeScriptNum(-decodeScriptNum(stack.popItem())));
  } else if (opcode === OP_ABS) {
    stack.pushItem(encodeScriptNum(Math.abs(decodeScriptNum(stack.popItem()))));
  } else if (opcode === OP_NOT) {
    stack.pushItem(encodeBool(!castToBool(stack.popItem())));
  } else if (opcode === OP_0NOTEQUAL) {
    stack.pushItem(encodeBool(castToBool(stack.popItem())));
  } else if (opcode === OP_BOOLAND) {
    const bVal = castToBool(stack.popItem());
    const aVal = castToBool(stack.popItem());
    stack.pushItem(encodeBool(aVal && bVal));
  } else if (opcode === OP_BOOLOR) {
    const bVal = castToBool(stack.popItem());
    const aVal = castToBool(stack.popItem());
    stack.pushItem(encodeBool(aVal || bVal));
  } else if (opcode === OP_MIN || opcode === OP_MAX) {
    const bVal = decodeScriptNum(stack.popItem());
    const aVal = decodeScriptNum(stack.popItem());
    stack.pushItem(encodeScriptNum(opcode === OP_MIN ? Math.min(aVal, bVal) : Math.max(aVal, bVal)));
  } else if (opcode === OP_NUMEQUAL || opcode === OP_NUMNOTEQUAL) {
    const bVal = decodeScriptNum(stack.popItem());
    const aVal = decodeScriptNum(stack.popItem());
    stack.pushItem(encodeBool(opcode === OP_NUMEQUAL ? aVal === bVal : aVal !== bVal));
  } else if (opcode === OP_NUMEQUALVERIFY) {
    const bVal = decodeScriptNum(stack.popItem());
    const aVal = decodeScriptNum(stack.popItem());
    if (aVal !== bVal) throw new ScriptError("NUMEQUALVERIFY failed");
  } else if (
    opcode === OP_LESSTHAN ||
    opcode === OP_GREATERTHAN ||
    opcode === OP_LESSTHANOREQUAL ||
    opcode === OP_GREATERTHANOREQUAL
  ) {
    const bVal = decodeScriptNum(stack.popItem());
    const aVal = decodeScriptNum(stack.popItem());
    const result =
      opcode === OP_LESSTHAN ? aVal < bVal :
      opcode === OP_GREATERTHAN ? aVal > bVal :
      opcode === OP_LESSTHANOREQUAL ? aVal <= bVal :
      aVal >= bVal;
    stack.pushItem(encodeBool(result));
  } else if (opcode === OP_WITHIN) {
    const maxVal = decodeScriptNum(stack.popItem());
    const minVal = decodeScriptNum(stack.popItem());
    const value = decodeScriptNum(stack.popItem());
    stack.pushItem(encodeBool(minVal <= value && value < maxVal));
  } else if (opcode === OP_SHA1) {
    stack.pushItem(sha1Digest(stack.popItem()));
  } else if (opcode === OP_SHA256) {
    stack.pushItem(sha256Digest(stack.popItem()));
  } else if (opcode === OP_RIPEMD160) {
    stack.pushItem(ripemd160Digest(stack.popItem()));
  } else if (opcode === OP_HASH160) {
    stack.pushItem(hash160(stack.popItem()));
  } else if (opcode === OP_HASH256) {
    stack.pushItem(hash256(stack.popItem()));
  } else if (opcode === OP_EQUAL) {
    const bVal = stack.popItem();
    const aVal = stack.popItem();
    stack.pushItem(encodeBool(aVal.equals(bVal)));
  } else if (opcode === OP_EQUALVERIFY) {
    const bVal = stack.popItem();
    const aVal = stack.popItem();
    if (!aVal.equals(bVal)) throw new ScriptError("EQUALVERIFY failed");
  } else if (opcode === OP_VERIFY) {
    if (!castToBool(stack.popItem())) throw new ScriptError("VERIFY failed");
  } else if (opcode === OP_NOP) {
    // No-op.
  } else if (opcode === OP_CODESEPARATOR) {
    if (options.codeSeparatorOffset !== undefined) {
      options.codeSeparatorOffset.value = offsetAfterOpcode;
    }
  } else if (opcode === OP_CHECKSIG || opcode === OP_CHECKSIGVERIFY) {
    const pubkey = stack.popItem();
    const signature = stack.popItem();
    const valid = checkEcdsaSignature({
      signature,
      pubkey,
      tx: options.tx,
      inputIndex: options.inputIndex,
      scriptCode: options.codeSeparatorOffset && options.codeSeparatorOffset.value > 0
        ? options.scriptCode.subarray(options.codeSeparatorOffset.value)
        : options.scriptCode,
      amount: options.amount,
      witness: options.witness,
    });
    if (opcode === OP_CHECKSIG) {
      stack.pushItem(encodeBool(valid));
    } else if (!valid) {
      throw new ScriptError("CHECKSIGVERIFY failed");
    }
  } else if (opcode === OP_CHECKMULTISIG || opcode === OP_CHECKMULTISIGVERIFY) {
    execCheckmultisig(stack, opcode, {
      ...options,
      scriptCode: options.codeSeparatorOffset && options.codeSeparatorOffset.value > 0
        ? options.scriptCode.subarray(options.codeSeparatorOffset.value)
        : options.scriptCode,
    });
  } else if (opcode === OP_CHECKLOCKTIMEVERIFY) {
    if ((options.verifyFlags ?? SCRIPT_VERIFY_DEFAULT) & SCRIPT_VERIFY_CHECKLOCKTIMEVERIFY) {
      execChecklocktimeverify(stack, options.tx);
    }
  } else if (opcode === OP_CHECKSEQUENCEVERIFY) {
    if ((options.verifyFlags ?? SCRIPT_VERIFY_DEFAULT) & SCRIPT_VERIFY_CHECKSEQUENCEVERIFY) {
      execChecksequenceverify(stack, options.tx, options.inputIndex);
    }
  } else {
    return false;
  }
  return true;
}

export function evaluateScript(
  script: Buffer,
  stack: Stack,
  options: EvalOptions,
): void {
  const verifyFlags = options.verifyFlags ?? SCRIPT_VERIFY_DEFAULT;
  const branches: boolean[] = [];
  const altStack = new Stack();
  let offset = 0;
  while (offset < script.length) {
    const opcode = script[offset]!;
    const fExec = branchExec(branches);

    if (opcode === OP_IF || opcode === OP_NOTIF) {
      if (fExec) {
        if (stack.length === 0) throw new ScriptError("OP_IF stack empty");
        let branch = castToBool(stack.popItem());
        if (opcode === OP_NOTIF) branch = !branch;
        branches.push(branch);
      } else {
        branches.push(false);
      }
      offset += 1;
      continue;
    }
    if (opcode === OP_ELSE) {
      if (branches.length === 0) throw new ScriptError("unbalanced conditional");
      branches[branches.length - 1] = !branches[branches.length - 1];
      offset += 1;
      continue;
    }
    if (opcode === OP_ENDIF) {
      if (branches.length === 0) throw new ScriptError("unbalanced conditional");
      branches.pop();
      offset += 1;
      continue;
    }

    if (!fExec) {
      offset = advanceInactiveOpcode(script, offset);
      continue;
    }

    offset += 1;
    if (opcode === OP_0) {
      stack.pushItem(Buffer.alloc(0));
    } else if (opcode >= OP_1 && opcode <= OP_16) {
      stack.pushItem(encodeOpN(opcode - OP_1 + 1));
    } else if (opcode === OP_1NEGATE) {
      stack.pushItem(Buffer.from([0x81]));
    } else if (
      (opcode >= 1 && opcode <= 75) ||
      opcode === OP_PUSHDATA1 ||
      opcode === OP_PUSHDATA2 ||
      opcode === OP_PUSHDATA4
    ) {
      offset -= 1;
      const [item, nextOffset] = readPush(script, offset);
      offset = nextOffset;
      stack.pushItem(item);
    } else if (!executeCommonOpcode(opcode, stack, altStack, { ...options, verifyFlags }, offset)) {
      throw new ScriptError(`unsupported opcode 0x${opcode.toString(16)}`);
    }
  }
  if (branches.length !== 0) {
    throw new ScriptError("unbalanced conditional");
  }
}

export function p2pkhScriptCode(pubkeyHash: Buffer): Buffer {
  return Buffer.concat([
    Buffer.from([OP_DUP, OP_HASH160, pubkeyHash.length]),
    pubkeyHash,
    Buffer.from([0x88, OP_CHECKSIG]),
  ]);
}

export function parsePushOnlyScriptSig(scriptSig: Buffer): Buffer[] {
  let offset = 0;
  const pushes: Buffer[] = [];
  while (offset < scriptSig.length) {
    const opcode = scriptSig[offset]!;
    offset += 1;
    if (opcode === OP_0) {
      pushes.push(Buffer.alloc(0));
    } else if (opcode >= OP_1 && opcode <= OP_16) {
      pushes.push(Buffer.from([opcode - OP_1 + 1]));
    } else if (opcode === OP_1NEGATE) {
      pushes.push(Buffer.from([0x81]));
    } else if (
      (opcode >= 1 && opcode <= 75) ||
      opcode === OP_PUSHDATA1 ||
      opcode === OP_PUSHDATA2 ||
      opcode === OP_PUSHDATA4
    ) {
      offset -= 1;
      const [item, nextOffset] = readPush(scriptSig, offset);
      offset = nextOffset;
      pushes.push(item);
    } else {
      throw new ScriptError("non-push opcode in P2SH scriptSig");
    }
  }
  return pushes;
}

export function isP2pkh(scriptPubKey: Buffer): boolean {
  return (
    scriptPubKey.length === 25 &&
    scriptPubKey[0] === OP_DUP &&
    scriptPubKey[1] === OP_HASH160 &&
    scriptPubKey[2] === 0x14 &&
    scriptPubKey[23] === OP_EQUALVERIFY &&
    scriptPubKey[24] === OP_CHECKSIG
  );
}

export function isP2pk(scriptPubKey: Buffer): boolean {
  if (scriptPubKey.length === 35) {
    return scriptPubKey[0] === 33 && scriptPubKey[34] === OP_CHECKSIG;
  }
  if (scriptPubKey.length === 67) {
    return scriptPubKey[0] === 65 && scriptPubKey[66] === OP_CHECKSIG;
  }
  return false;
}

export function isP2wpkh(scriptPubKey: Buffer): boolean {
  return scriptPubKey.length === 22 && scriptPubKey[0] === 0x00 && scriptPubKey[1] === 0x14;
}

export function isP2sh(scriptPubKey: Buffer): boolean {
  return (
    scriptPubKey.length === 23 &&
    scriptPubKey[0] === OP_HASH160 &&
    scriptPubKey[1] === 0x14 &&
    scriptPubKey[22] === OP_EQUAL
  );
}

export function isP2wsh(scriptPubKey: Buffer): boolean {
  return scriptPubKey.length === 34 && scriptPubKey[0] === 0x00 && scriptPubKey[1] === 0x20;
}

export function isP2tr(scriptPubKey: Buffer): boolean {
  return (
    scriptPubKey.length === 2 + WITNESS_V1_TAPROOT_XONLY_PK_LEN &&
    scriptPubKey[0] === OP_1 &&
    scriptPubKey[1] === WITNESS_V1_TAPROOT_XONLY_PK_LEN
  );
}

export function witnessProgramVersion(scriptPubKey: Buffer): number | null {
  if (scriptPubKey.length < 4) {
    return null;
  }
  const versionByte = scriptPubKey[0]!;
  let version: number;
  if (versionByte === OP_0) {
    version = 0;
  } else if (versionByte >= OP_1 && versionByte <= OP_16) {
    version = versionByte - OP_1 + 1;
  } else {
    return null;
  }

  let pc = 1;
  if (pc >= scriptPubKey.length) {
    return null;
  }
  const opcode = scriptPubKey[pc]!;
  let pushLen: number;
  let dataStart: number;
  if (opcode >= 1 && opcode <= 75) {
    pushLen = opcode;
    dataStart = pc + 1;
  } else if (opcode === OP_PUSHDATA1) {
    if (pc + 1 >= scriptPubKey.length) {
      return null;
    }
    pushLen = scriptPubKey[pc + 1]!;
    dataStart = pc + 2;
  } else if (opcode === OP_PUSHDATA2) {
    if (pc + 2 >= scriptPubKey.length) {
      return null;
    }
    pushLen = scriptPubKey.readUInt16LE(pc + 1);
    dataStart = pc + 3;
  } else if (opcode === OP_PUSHDATA4) {
    if (pc + 4 >= scriptPubKey.length) {
      return null;
    }
    pushLen = scriptPubKey.readUInt32LE(pc + 1);
    dataStart = pc + 5;
  } else {
    return null;
  }

  if (pushLen < 2 || pushLen > 40) {
    return null;
  }
  if (dataStart + pushLen !== scriptPubKey.length) {
    return null;
  }
  return version;
}

function tapscriptOpcodeIsSuccess(opcode: number): boolean {
  if (opcode === 80 || opcode === 98) {
    return true;
  }
  if (opcode >= 126 && opcode <= 129) {
    return true;
  }
  if (opcode >= 131 && opcode <= 134) {
    return true;
  }
  if (opcode >= 137 && opcode <= 138) {
    return true;
  }
  if (opcode >= 141 && opcode <= 142) {
    return true;
  }
  if (opcode >= 149 && opcode <= 153) {
    return true;
  }
  if (opcode >= 187 && opcode <= 254) {
    return true;
  }
  return false;
}

function tapscriptPrescanOpSuccess(script: Buffer): boolean {
  let pc = 0;
  while (pc < script.length) {
    const opcode = script[pc]!;
    if (opcode === OP_0) {
      pc += 1;
      continue;
    }
    if ((opcode >= OP_1 && opcode <= OP_16) || opcode === OP_1NEGATE) {
      pc += 1;
      continue;
    }
    if (opcode >= 1 && opcode <= 75) {
      pc += 1 + opcode;
      continue;
    }
    if (opcode === OP_PUSHDATA1 || opcode === OP_PUSHDATA2 || opcode === OP_PUSHDATA4) {
      try {
        [, pc] = readPush(script, pc);
      } catch {
        return false;
      }
      continue;
    }
    if (tapscriptOpcodeIsSuccess(opcode)) {
      return true;
    }
    pc += 1;
  }
  return false;
}

function evaluateTapscript(
  script: Buffer,
  stack: Stack,
  options: {
    tx: Transaction;
    inputIndex: number;
    tapleafDigest: Buffer;
    spentPrevouts: readonly (readonly [number, Buffer])[];
    annex: Buffer | null;
    validationBudgetLeft: { value: number };
    sighashCache?: TransactionSighashCache | undefined;
  },
): void {
  if (tapscriptPrescanOpSuccess(script)) {
    return;
  }

  let codeseparatorPos = 0xffffffff;
  let instructionPos = 0;
  let offset = 0;
  const branches: boolean[] = [];
  const altStack = new Stack();
  while (offset < script.length) {
    const instrAt = instructionPos;
    const opcode = script[offset]!;
    const fExec = branchExec(branches);

    if (opcode === OP_IF || opcode === OP_NOTIF) {
      if (fExec) {
        if (stack.length === 0) throw new ScriptError("OP_IF stack empty");
        let branch = castToBool(stack.popItem());
        if (opcode === OP_NOTIF) branch = !branch;
        branches.push(branch);
      } else {
        branches.push(false);
      }
      offset += 1;
      instructionPos += 1;
      continue;
    }
    if (opcode === OP_ELSE) {
      if (branches.length === 0) throw new ScriptError("unbalanced conditional");
      branches[branches.length - 1] = !branches[branches.length - 1];
      offset += 1;
      instructionPos += 1;
      continue;
    }
    if (opcode === OP_ENDIF) {
      if (branches.length === 0) throw new ScriptError("unbalanced conditional");
      branches.pop();
      offset += 1;
      instructionPos += 1;
      continue;
    }

    if (!fExec) {
      offset = advanceInactiveOpcode(script, offset);
      instructionPos += 1;
      continue;
    }

    const codeSeparatorRef = { value: codeseparatorPos };

    if (opcode === OP_0) {
      stack.pushItem(Buffer.alloc(0));
      offset += 1;
      instructionPos += 1;
    } else if (opcode >= OP_1 && opcode <= OP_16) {
      stack.pushItem(encodeOpN(opcode - OP_1 + 1));
      offset += 1;
      instructionPos += 1;
    } else if (opcode === OP_1NEGATE) {
      stack.pushItem(Buffer.from([0x81]));
      offset += 1;
      instructionPos += 1;
    } else if (
      (opcode >= 1 && opcode <= 75) ||
      opcode === OP_PUSHDATA1 ||
      opcode === OP_PUSHDATA2 ||
      opcode === OP_PUSHDATA4
    ) {
      const [item, nextOffset] = readPush(script, offset);
      offset = nextOffset;
      stack.pushItem(item);
      instructionPos += 1;
    } else if (opcode === OP_CODESEPARATOR) {
      codeseparatorPos = instrAt;
      offset += 1;
      instructionPos += 1;
    } else if (opcode === OP_CHECKMULTISIG || opcode === OP_CHECKMULTISIGVERIFY) {
      throw new ScriptError("CHECKMULTISIG disabled in tapscript");
    } else if (opcode === 0x61) {
      offset += 1;
      instructionPos += 1;
    } else if (opcode === OP_CHECKSIG || opcode === OP_CHECKSIGVERIFY) {
      const pubkey = stack.popItem();
      const signature = stack.popItem();
      if (pubkey.length === 0) {
        throw new ScriptError("empty pubkey in tapscript checksig");
      }

      const consumeSigopIfNonempty = (): void => {
        if (signature.length > 0) {
          options.validationBudgetLeft.value -= VALIDATION_WEIGHT_PER_SIGOP;
          if (options.validationBudgetLeft.value < 0) {
            throw new ScriptError("tapscript validation weight exceeded");
          }
        }
      };

      if (pubkey.length !== 32) {
        if (signature.length === 0) {
          if (opcode === OP_CHECKSIGVERIFY) {
            throw new ScriptError("CHECKSIGVERIFY failed");
          }
          stack.pushItem(Buffer.alloc(0));
        } else {
          consumeSigopIfNonempty();
          if (opcode === OP_CHECKSIG) {
            stack.pushItem(Buffer.from([1]));
          }
        }
        offset += 1;
        instructionPos += 1;
        continue;
      }

      let valid = false;
      if (signature.length > 0) {
        consumeSigopIfNonempty();
        let hashType = TAPROOT_SIGHASH_DEFAULT;
        let sig64 = signature;
        if (signature.length === 65) {
          hashType = signature[64]!;
          if (hashType === TAPROOT_SIGHASH_DEFAULT) {
            throw new ScriptError("invalid tap hashtype byte");
          }
          sig64 = signature.subarray(0, 64);
        } else if (signature.length !== 64) {
          throw new ScriptError("invalid Schnorr signature length");
        }
        try {
          const hashOptions = {
            hashType,
            annex: options.annex,
            extFlag: 1,
            tapleafHash: options.tapleafDigest,
            tapscriptCodeseparatorPos: codeseparatorPos,
          };
          const digest = options.sighashCache?.taprootSignatureHash(options.inputIndex, hashOptions) ??
            taprootSignatureHash(options.tx, options.inputIndex, options.spentPrevouts, hashOptions);
          valid = verifySchnorrWithSelectedBackend(pubkey, digest, sig64) === "valid";
        } catch (error) {
          throw new ScriptError(error instanceof Error ? error.message : "tapscript sighash failed");
        }
      }

      if (opcode === OP_CHECKSIG) {
        stack.pushItem(encodeBool(valid));
      } else if (!valid) {
        throw new ScriptError("CHECKSIGVERIFY failed");
      }
      offset += 1;
      instructionPos += 1;
    } else if (opcode === OP_CHECKSIGADD) {
      const pubkey = stack.popItem();
      const nItem = stack.popItem();
      const signature = stack.popItem();
      if (pubkey.length === 0) {
        throw new ScriptError("empty pubkey in tapscript checksigadd");
      }
      const n = decodeScriptNum(nItem);
      let increment = false;
      if (pubkey.length !== 32) {
        if (signature.length > 0) {
          options.validationBudgetLeft.value -= VALIDATION_WEIGHT_PER_SIGOP;
          if (options.validationBudgetLeft.value < 0) {
            throw new ScriptError("tapscript validation weight exceeded");
          }
          increment = true;
        }
      } else if (signature.length > 0) {
        options.validationBudgetLeft.value -= VALIDATION_WEIGHT_PER_SIGOP;
        if (options.validationBudgetLeft.value < 0) {
          throw new ScriptError("tapscript validation weight exceeded");
        }
        let hashType = TAPROOT_SIGHASH_DEFAULT;
        let sig64 = signature;
        if (signature.length === 65) {
          hashType = signature[64]!;
          if (hashType === TAPROOT_SIGHASH_DEFAULT) {
            throw new ScriptError("invalid tap hashtype byte");
          }
          sig64 = signature.subarray(0, 64);
        } else if (signature.length !== 64) {
          throw new ScriptError("invalid Schnorr signature length");
        }
        const hashOptions = {
          hashType,
          annex: options.annex,
          extFlag: 1,
          tapleafHash: options.tapleafDigest,
          tapscriptCodeseparatorPos: codeseparatorPos,
        };
        const digest = options.sighashCache?.taprootSignatureHash(options.inputIndex, hashOptions) ??
          taprootSignatureHash(options.tx, options.inputIndex, options.spentPrevouts, hashOptions);
        increment = verifySchnorrWithSelectedBackend(pubkey, digest, sig64) === "valid";
      }
      stack.pushItem(encodeScriptNum(n + (increment ? 1 : 0)));
      offset += 1;
      instructionPos += 1;
    } else if (executeCommonOpcode(opcode, stack, altStack, {
      tx: options.tx,
      inputIndex: options.inputIndex,
      scriptCode: script,
      amount: 0,
      witness: true,
      codeSeparatorOffset: codeSeparatorRef,
    }, offset + 1)) {
      codeseparatorPos = codeSeparatorRef.value;
      offset += 1;
      instructionPos += 1;
    } else {
      throw new ScriptError(`unsupported tapscript opcode 0x${opcode.toString(16)}`);
    }
  }
  if (branches.length !== 0) {
    throw new ScriptError("unbalanced conditional");
  }
}

function verifyP2trScriptPath(options: {
  scriptPubKey: Buffer;
  witnessItemsWithoutAnnex: readonly Buffer[];
  annex: Buffer | null;
  tx: Transaction;
  inputIndex: number;
  spentPrevouts: readonly (readonly [number, Buffer])[];
  serializedWitnessForWeight: Buffer;
  sighashCache?: TransactionSighashCache | undefined;
}): boolean {
  if (options.spentPrevouts.length !== options.tx.inputs.length) {
    throw new ScriptError("spent_prevouts length mismatch");
  }

  const witnessItems = options.witnessItemsWithoutAnnex;
  if (witnessItems.length < 2) {
    throw new ScriptError("taproot script-path witness too short");
  }
  const scriptBytes = witnessItems[witnessItems.length - 2]!;
  const control = witnessItems[witnessItems.length - 1]!;
  const stackItems = witnessItems.slice(0, -2);

  if (scriptBytes.length === 0) {
    throw new ScriptError("empty tapscript");
  }
  const ctlLen = control.length;
  if (ctlLen < 33 || ctlLen > 33 + 128 * 32 || (ctlLen - 33) % 32 !== 0) {
    throw new ScriptError("invalid taproot control block length");
  }

  const leafMasked = control[0]! & 0xfe;
  if (leafMasked === ANNEX_TAG) {
    throw new ScriptError("invalid taproot leaf version");
  }

  const internalX = control.subarray(1, 33);
  const merkleBranch: Buffer[] = [];
  for (let index = 33; index < ctlLen; index += 32) {
    merkleBranch.push(control.subarray(index, index + 32));
  }

  let leafDigest: Buffer;
  let outX: Buffer;
  let parityOut: number;
  try {
    leafDigest = tapleafHash(leafMasked, scriptBytes);
    const merkleRoot = taprootMerkleRootFromBranch(merkleBranch, leafDigest);
    const tweak = taprootTweakWithSelectedBackend(internalX, merkleRoot);
    if (tweak.result !== "valid") {
      throw new ScriptError("taproot tweak failed");
    }
    parityOut = tweak.parity;
    outX = tweak.outputXonly;
  } catch (error) {
    throw new ScriptError(error instanceof Error ? error.message : "taproot tweak failed");
  }

  if (!outX.equals(options.scriptPubKey.subarray(2)) || control[0] !== (leafMasked | parityOut)) {
    throw new ScriptError("taproot control block commitment mismatch");
  }

  if (leafMasked !== TAPROOT_LEAF_VERSION_TAPSCRIPT) {
    return true;
  }

  if (tapscriptPrescanOpSuccess(scriptBytes)) {
    return true;
  }

  if (stackItems.length > MAX_TAPSCRIPT_STACK_ELEMENTS) {
    throw new ScriptError("tapscript stack too many elements");
  }
  for (const elem of stackItems) {
    if (elem.length > MAX_SCRIPT_ELEMENT_SIZE_CONSENSUS) {
      throw new ScriptError("tapscript stack element too large");
    }
  }

  const budget = {
    value: VALIDATION_WEIGHT_OFFSET + options.serializedWitnessForWeight.length,
  };
  const execStack = new Stack(...stackItems);
  evaluateTapscript(scriptBytes, execStack, {
    tx: options.tx,
    inputIndex: options.inputIndex,
    tapleafDigest: leafDigest,
    spentPrevouts: options.spentPrevouts,
    annex: options.annex,
    validationBudgetLeft: budget,
    sighashCache: options.sighashCache,
  });

  if (!terminalSuccessStrict(execStack)) {
    throw new ScriptError(`tapscript failed final stack check (size ${execStack.length})`);
  }
  return true;
}

function terminalSuccessStrict(stack: Stack): boolean {
  return stack.length === 1 && castToBool(stack[0]!);
}

function terminalSuccessRelaxed(stack: Stack): boolean {
  return stack.length > 0 && castToBool(stack[stack.length - 1]!);
}

export function assertVerifyScript(
  scriptSig: Buffer,
  scriptPubKey: Buffer,
  options: {
    tx: Transaction;
    inputIndex: number;
    amount: number;
    witness?: readonly Buffer[];
    spentPrevouts?: readonly (readonly [number, Buffer])[];
    sighashCache?: TransactionSighashCache | undefined;
  },
): void {
  const witness = options.witness ?? [];

  if (isP2pk(scriptPubKey)) {
    if (witness.length > 0) throw new ScriptError("P2PK spend cannot have witness");
    const pushes = parsePushOnlyScriptSig(scriptSig);
    if (pushes.length !== 1 || pushes[0]!.length === 0) throw new ScriptError("P2PK scriptSig must contain one signature");
    const stackSig = new Stack();
    evaluateScript(scriptSig, stackSig, {
      tx: options.tx,
      inputIndex: options.inputIndex,
      scriptCode: scriptPubKey,
      amount: options.amount,
      witness: false,
      sighashCache: options.sighashCache,
    });
    const stack = new Stack(...stackSig);
    const codeSeparatorOffset = { value: 0 };
    evaluateScript(scriptPubKey, stack, {
      tx: options.tx,
      inputIndex: options.inputIndex,
      scriptCode: scriptPubKey,
      amount: options.amount,
      witness: false,
      codeSeparatorOffset,
      sighashCache: options.sighashCache,
    });
    if (!terminalSuccessStrict(stack)) throw new ScriptError(`P2PK final stack check failed (size ${stack.length})`);
    return;
  }

  if (isP2wpkh(scriptPubKey)) {
    const pubkeyHash = scriptPubKey.subarray(2);
    if (scriptSig.length > 0) throw new ScriptError("P2WPKH scriptSig must be empty");
    if (witness.length !== 2) throw new ScriptError("P2WPKH witness must contain signature and pubkey");
    const scriptCode = p2pkhScriptCode(pubkeyHash);
    const stack = new Stack(...witness);
    evaluateScript(scriptCode, stack, {
      tx: options.tx,
      inputIndex: options.inputIndex,
      scriptCode,
      amount: options.amount,
      witness: true,
      sighashCache: options.sighashCache,
    });
    if (!terminalSuccessStrict(stack)) throw new ScriptError(`P2WPKH final stack check failed (size ${stack.length})`);
    return;
  }

  if (isP2wsh(scriptPubKey)) {
    if (scriptSig.length > 0) throw new ScriptError("P2WSH scriptSig must be empty");
    if (witness.length < 1) throw new ScriptError("P2WSH witness missing witness script");
    const witnessProgram = scriptPubKey.subarray(2);
    const witnessScript = witness[witness.length - 1]!;
    if (witnessScript.length === 0 || witnessScript.length > MAX_CONSENSUS_SCRIPT_SIZE) {
      throw new ScriptError("invalid P2WSH witness script size");
    }
    if (!sha256Digest(witnessScript).equals(witnessProgram)) throw new ScriptError("P2WSH witness script hash mismatch");
    const stack = new Stack(...witness.slice(0, -1));
    const codeSeparatorOffset = { value: 0 };
    evaluateScript(witnessScript, stack, {
      tx: options.tx,
      inputIndex: options.inputIndex,
      scriptCode: witnessScript,
      amount: options.amount,
      witness: true,
      codeSeparatorOffset,
      sighashCache: options.sighashCache,
    });
    if (!terminalSuccessStrict(stack)) throw new ScriptError(`P2WSH final stack check failed (size ${stack.length})`);
    return;
  }

  if (isP2tr(scriptPubKey)) {
    if (scriptSig.length > 0) {
      throw new ScriptError("P2TR scriptSig must be empty");
    }
    const outputKeyX = scriptPubKey.subarray(2);
    const wit = [...witness];
    const witSerializedForWeight = serializedWitnessStackBytes(witness);
    let annex: Buffer | null = null;
    if (wit.length >= 2 && wit[wit.length - 1]!.length > 0 && wit[wit.length - 1]![0] === ANNEX_TAG) {
      annex = wit.pop()!;
    }
    if (wit.length >= 2) {
      if (options.spentPrevouts === undefined) {
        throw new ScriptError("P2TR script-path requires spent prevouts");
      }
      verifyP2trScriptPath({
        scriptPubKey,
        witnessItemsWithoutAnnex: wit,
        annex,
        tx: options.tx,
        inputIndex: options.inputIndex,
        spentPrevouts: options.spentPrevouts,
        serializedWitnessForWeight: witSerializedForWeight,
        sighashCache: options.sighashCache,
      });
      return;
    }
    if (options.spentPrevouts === undefined) {
      throw new ScriptError("P2TR key-path requires spent prevouts");
    }
    if (wit.length !== 1) {
      throw new ScriptError("P2TR key-path witness must contain one signature");
    }
    const sigblob = wit[0]!;
    if (sigblob.length !== 64 && sigblob.length !== 65) {
      throw new ScriptError("invalid Schnorr signature length");
    }
    let hashType = TAPROOT_SIGHASH_DEFAULT;
    let sig64 = sigblob;
    if (sigblob.length === 65) {
      hashType = sigblob[64]!;
      if (hashType === TAPROOT_SIGHASH_DEFAULT) {
        throw new ScriptError("invalid tap hashtype byte");
      }
      sig64 = sigblob.subarray(0, 64);
    }
    const hashOptions = { hashType, annex };
    const msg = options.sighashCache?.taprootSignatureHash(options.inputIndex, hashOptions) ??
      taprootSignatureHash(options.tx, options.inputIndex, options.spentPrevouts, hashOptions);
    if (verifySchnorrWithSelectedBackend(outputKeyX, msg, sig64) !== "valid") {
      throw new ScriptError("taproot key-path signature failed");
    }
    return;
  }

  let redeemCandidate: Buffer | null = null;
  if (isP2sh(scriptPubKey)) {
    const pushes = parsePushOnlyScriptSig(scriptSig);
    if (pushes.length === 0 || pushes[pushes.length - 1]!.length > MAX_P2SH_REDEEM_PUSH) {
      throw new ScriptError("invalid P2SH redeem script push");
    }
    redeemCandidate = pushes[pushes.length - 1]!;
    if (witnessProgramVersion(redeemCandidate) !== null) {
      if (!hash160(redeemCandidate).equals(scriptPubKey.subarray(2, 22))) {
        throw new ScriptError("P2SH redeem script hash mismatch");
      }
      assertVerifyScript(Buffer.alloc(0), redeemCandidate, options);
      return;
    }
  }

  const stackSig = new Stack();
  evaluateScript(scriptSig, stackSig, {
    tx: options.tx,
    inputIndex: options.inputIndex,
    scriptCode: scriptPubKey,
    amount: options.amount,
    witness: false,
    sighashCache: options.sighashCache,
  });

  if (redeemCandidate !== null && (stackSig.length === 0 || !stackSig[stackSig.length - 1]!.equals(redeemCandidate))) {
    throw new ScriptError("P2SH redeem script not on stack");
  }

  const stack = new Stack(...stackSig);
  const codeSeparatorOffset = { value: 0 };
  evaluateScript(scriptPubKey, stack, {
    tx: options.tx,
    inputIndex: options.inputIndex,
    scriptCode: scriptPubKey,
    amount: options.amount,
    witness: false,
    codeSeparatorOffset,
    sighashCache: options.sighashCache,
  });

  if (redeemCandidate === null) {
    if (!terminalSuccessRelaxed(stack)) throw new ScriptError(`legacy final stack check failed (size ${stack.length})`);
    return;
  }

  if (!terminalSuccessRelaxed(stack)) throw new ScriptError("P2SH outer final stack check failed");
  const expectedH160 = scriptPubKey.subarray(2, 22);
  if (!hash160(redeemCandidate).equals(expectedH160)) throw new ScriptError("P2SH redeem script hash mismatch");

  const inner = new Stack(...stackSig.slice(0, -1));
  const innerCodeSeparatorOffset = { value: 0 };
  evaluateScript(redeemCandidate, inner, {
    tx: options.tx,
    inputIndex: options.inputIndex,
    scriptCode: redeemCandidate,
    amount: options.amount,
    witness: false,
    codeSeparatorOffset: innerCodeSeparatorOffset,
    sighashCache: options.sighashCache,
  });
  if (!terminalSuccessRelaxed(inner)) throw new ScriptError(`P2SH inner final stack check failed (size ${inner.length})`);
}

export function verifyScript(
  scriptSig: Buffer,
  scriptPubKey: Buffer,
  options: {
    tx: Transaction;
    inputIndex: number;
    amount: number;
    witness?: readonly Buffer[];
    spentPrevouts?: readonly (readonly [number, Buffer])[];
    sighashCache?: TransactionSighashCache | undefined;
  },
): boolean {
  try {
    assertVerifyScript(scriptSig, scriptPubKey, options);
    return true;
  } catch {
    return false;
  }
}
