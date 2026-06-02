import { hash160, sha256Digest } from "../hash.js";
import { taprootTweakPubkeyXonly, verifyDerSignature, verifySchnorrSignature } from "../secp256k1.js";
import {
  ANNEX_TAG,
  MAX_CONSENSUS_SCRIPT_SIZE,
  MAX_P2SH_REDEEM_PUSH,
  MAX_PUBKEYS_PER_MULTISIG,
  MAX_SCRIPT_ELEMENT_SIZE_CONSENSUS,
  MAX_TAPSCRIPT_STACK_ELEMENTS,
  OP_0,
  OP_1,
  OP_16,
  OP_1NEGATE,
  OP_CHECKLOCKTIMEVERIFY,
  OP_CHECKMULTISIG,
  OP_CHECKMULTISIGVERIFY,
  OP_CHECKSEQUENCEVERIFY,
  OP_CHECKSIG,
  OP_CHECKSIGVERIFY,
  OP_CODESEPARATOR,
  OP_DROP,
  OP_DUP,
  OP_EQUAL,
  OP_EQUALVERIFY,
  OP_HASH160,
  OP_PUSHDATA1,
  OP_PUSHDATA2,
  OP_PUSHDATA4,
  OP_SWAP,
  OP_VERIFY,
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
}

function castToBool(item: Buffer): boolean {
  for (const byte of item) {
    if (byte !== 0) {
      if (byte === 0x80) return false;
      return true;
    }
  }
  return false;
}

function encodeOpN(value: number): Buffer {
  if (value === 0) return Buffer.alloc(0);
  if (value >= 1 && value <= 16) return Buffer.from([value]);
  throw new ScriptError(`cannot encode numeric ${value}`);
}

function decodeScriptNum(item: Buffer, maxLen = 4): number {
  if (item.length > maxLen) throw new ScriptError("script number overflow");
  if (item.length === 0) return 0;
  if (item[item.length - 1]! & 0x80) {
    throw new ScriptError("negative script numbers unsupported");
  }
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
}): boolean {
  if (options.signature.length === 0) return false;
  const sighashType = options.signature[options.signature.length - 1]!;
  const sigDer = options.signature.subarray(0, -1);
  const digest = options.witness
    ? bip143Sighash(
        options.tx,
        options.inputIndex,
        options.scriptCode,
        options.amount,
        sighashType,
      )
    : legacySighash(options.tx, options.inputIndex, options.scriptCode, sighashType);
  return verifyDerSignature(options.pubkey, digest, sigDer);
}

function txIsFinalForCltv(tx: Transaction): boolean {
  if (tx.lockTime === 0) return true;
  return tx.inputs.every((input) => input.sequence === SEQUENCE_FINAL);
}

function execChecklocktimeverify(stack: Stack, tx: Transaction): void {
  if (stack.length === 0) throw new ScriptError("CHECKLOCKTIMEVERIFY stack empty");
  if (tx.version < 2) throw new ScriptError("CHECKLOCKTIMEVERIFY requires tx version >= 2");
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
  if (tx.version < 2) throw new ScriptError("CHECKSEQUENCEVERIFY requires tx version >= 2");

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
  stack.pushItem(encodeOpN(success ? 1 : 0));
  if (opcode === OP_CHECKMULTISIGVERIFY && !success) {
    throw new ScriptError("CHECKMULTISIGVERIFY failed");
  }
}

export function evaluateScript(
  script: Buffer,
  stack: Stack,
  options: {
    tx: Transaction;
    inputIndex: number;
    scriptCode: Buffer;
    amount: number;
    witness: boolean;
    verifyFlags?: number;
  },
): void {
  const verifyFlags = options.verifyFlags ?? SCRIPT_VERIFY_DEFAULT;
  let offset = 0;
  while (offset < script.length) {
    const opcode = script[offset]!;
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
    } else if (opcode === OP_DUP) {
      const item = stack.popItem();
      stack.pushItem(item);
      stack.pushItem(item);
    } else if (opcode === OP_DROP) {
      stack.popItem();
    } else if (opcode === OP_HASH160) {
      stack.pushItem(hash160(stack.popItem()));
    } else if (opcode === OP_EQUAL) {
      const bVal = stack.popItem();
      const aVal = stack.popItem();
      stack.pushItem(encodeOpN(aVal.equals(bVal) ? 1 : 0));
    } else if (opcode === OP_EQUALVERIFY) {
      const bVal = stack.popItem();
      const aVal = stack.popItem();
      if (!aVal.equals(bVal)) throw new ScriptError("EQUALVERIFY failed");
    } else if (opcode === OP_VERIFY) {
      if (!castToBool(stack.popItem())) throw new ScriptError("VERIFY failed");
    } else if (opcode === OP_CHECKSIG || opcode === OP_CHECKSIGVERIFY) {
      const pubkey = stack.popItem();
      const signature = stack.popItem();
      const valid = checkEcdsaSignature({
        signature,
        pubkey,
        tx: options.tx,
        inputIndex: options.inputIndex,
        scriptCode: options.scriptCode,
        amount: options.amount,
        witness: options.witness,
      });
      stack.pushItem(encodeOpN(valid ? 1 : 0));
      if (opcode === OP_CHECKSIGVERIFY && !valid) {
        throw new ScriptError("CHECKSIGVERIFY failed");
      }
    } else if (opcode === OP_CHECKMULTISIG || opcode === OP_CHECKMULTISIGVERIFY) {
      execCheckmultisig(stack, opcode, options);
    } else if (opcode === OP_CHECKLOCKTIMEVERIFY) {
      if (verifyFlags & SCRIPT_VERIFY_CHECKLOCKTIMEVERIFY) {
        execChecklocktimeverify(stack, options.tx);
      }
    } else if (opcode === OP_CHECKSEQUENCEVERIFY) {
      if (verifyFlags & SCRIPT_VERIFY_CHECKSEQUENCEVERIFY) {
        execChecksequenceverify(stack, options.tx, options.inputIndex);
      }
    } else {
      throw new ScriptError(`unsupported opcode 0x${opcode.toString(16)}`);
    }
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
  },
): void {
  if (tapscriptPrescanOpSuccess(script)) {
    return;
  }

  let codeseparatorPos = 0xffffffff;
  let instructionPos = 0;
  let offset = 0;
  while (offset < script.length) {
    const instrAt = instructionPos;
    const opcode = script[offset]!;

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
    } else if (opcode === OP_DROP) {
      stack.popItem();
      offset += 1;
      instructionPos += 1;
    } else if (opcode === OP_SWAP) {
      const a = stack.popItem();
      const b = stack.popItem();
      stack.pushItem(a);
      stack.pushItem(b);
      offset += 1;
      instructionPos += 1;
    } else if (opcode === OP_DUP) {
      const item = stack.popItem();
      stack.pushItem(item);
      stack.pushItem(item);
      offset += 1;
      instructionPos += 1;
    } else if (opcode === OP_HASH160) {
      stack.pushItem(hash160(stack.popItem()));
      offset += 1;
      instructionPos += 1;
    } else if (opcode === OP_EQUAL) {
      const bVal = stack.popItem();
      const aVal = stack.popItem();
      stack.pushItem(encodeOpN(aVal.equals(bVal) ? 1 : 0));
      offset += 1;
      instructionPos += 1;
    } else if (opcode === OP_EQUALVERIFY) {
      const bVal = stack.popItem();
      const aVal = stack.popItem();
      if (!aVal.equals(bVal)) throw new ScriptError("EQUALVERIFY failed");
      offset += 1;
      instructionPos += 1;
    } else if (opcode === OP_VERIFY) {
      if (!castToBool(stack.popItem())) throw new ScriptError("VERIFY failed");
      offset += 1;
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
          const digest = taprootSignatureHash(options.tx, options.inputIndex, options.spentPrevouts, {
            hashType,
            annex: options.annex,
            extFlag: 1,
            tapleafHash: options.tapleafDigest,
            tapscriptCodeseparatorPos: codeseparatorPos,
          });
          valid = verifySchnorrSignature(pubkey, digest, sig64);
        } catch (error) {
          throw new ScriptError(error instanceof Error ? error.message : "tapscript sighash failed");
        }
      }

      stack.pushItem(encodeOpN(valid ? 1 : 0));
      if (opcode === OP_CHECKSIGVERIFY && !valid) {
        throw new ScriptError("CHECKSIGVERIFY failed");
      }
      offset += 1;
      instructionPos += 1;
    } else {
      throw new ScriptError(`unsupported tapscript opcode 0x${opcode.toString(16)}`);
    }
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
}): boolean {
  if (options.spentPrevouts.length !== options.tx.inputs.length) {
    return false;
  }

  const witnessItems = options.witnessItemsWithoutAnnex;
  if (witnessItems.length < 2) {
    return false;
  }
  const scriptBytes = witnessItems[witnessItems.length - 2]!;
  const control = witnessItems[witnessItems.length - 1]!;
  const stackItems = witnessItems.slice(0, -2);

  if (scriptBytes.length === 0 || scriptBytes.length > MAX_CONSENSUS_SCRIPT_SIZE) {
    return false;
  }
  const ctlLen = control.length;
  if (ctlLen < 33 || ctlLen > 33 + 128 * 32 || (ctlLen - 33) % 32 !== 0) {
    return false;
  }

  const leafMasked = control[0]! & 0xfe;
  if (leafMasked === ANNEX_TAG) {
    return false;
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
    [parityOut, outX] = taprootTweakPubkeyXonly(internalX, merkleRoot);
  } catch {
    return false;
  }

  if (!outX.equals(options.scriptPubKey.subarray(2)) || control[0] !== (leafMasked | parityOut)) {
    return false;
  }

  if (leafMasked !== TAPROOT_LEAF_VERSION_TAPSCRIPT) {
    return true;
  }

  if (tapscriptPrescanOpSuccess(scriptBytes)) {
    return true;
  }

  if (stackItems.length > MAX_TAPSCRIPT_STACK_ELEMENTS) {
    return false;
  }
  for (const elem of stackItems) {
    if (elem.length > MAX_SCRIPT_ELEMENT_SIZE_CONSENSUS) {
      return false;
    }
  }

  const budget = {
    value: VALIDATION_WEIGHT_OFFSET + options.serializedWitnessForWeight.length,
  };
  const execStack = new Stack(...stackItems);
  try {
    evaluateTapscript(scriptBytes, execStack, {
      tx: options.tx,
      inputIndex: options.inputIndex,
      tapleafDigest: leafDigest,
      spentPrevouts: options.spentPrevouts,
      annex: options.annex,
      validationBudgetLeft: budget,
    });
  } catch {
    return false;
  }

  return terminalSuccessStrict(execStack);
}

function terminalSuccessStrict(stack: Stack): boolean {
  return stack.length === 1 && castToBool(stack[0]!);
}

function terminalSuccessRelaxed(stack: Stack): boolean {
  return stack.length > 0 && castToBool(stack[stack.length - 1]!);
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
  },
): boolean {
  const witness = options.witness ?? [];

  if (isP2pk(scriptPubKey)) {
    if (witness.length > 0) return false;
    try {
      const pushes = parsePushOnlyScriptSig(scriptSig);
      if (pushes.length !== 1 || pushes[0]!.length === 0) return false;
    } catch {
      return false;
    }
    const stackSig = new Stack();
    try {
      evaluateScript(scriptSig, stackSig, {
        tx: options.tx,
        inputIndex: options.inputIndex,
        scriptCode: scriptPubKey,
        amount: options.amount,
        witness: false,
      });
    } catch {
      return false;
    }
    const stack = new Stack(...stackSig);
    try {
      evaluateScript(scriptPubKey, stack, {
        tx: options.tx,
        inputIndex: options.inputIndex,
        scriptCode: scriptPubKey,
        amount: options.amount,
        witness: false,
      });
    } catch {
      return false;
    }
    return terminalSuccessStrict(stack);
  }

  if (isP2wpkh(scriptPubKey)) {
    const pubkeyHash = scriptPubKey.subarray(2);
    if (scriptSig.length > 0) return false;
    if (witness.length !== 2) return false;
    const scriptCode = p2pkhScriptCode(pubkeyHash);
    const stack = new Stack(...witness);
    try {
      evaluateScript(scriptCode, stack, {
        tx: options.tx,
        inputIndex: options.inputIndex,
        scriptCode,
        amount: options.amount,
        witness: true,
      });
    } catch {
      return false;
    }
    return terminalSuccessStrict(stack);
  }

  if (isP2wsh(scriptPubKey)) {
    if (scriptSig.length > 0) return false;
    if (witness.length < 2) return false;
    const witnessProgram = scriptPubKey.subarray(2);
    const witnessScript = witness[witness.length - 1]!;
    if (witnessScript.length === 0 || witnessScript.length > MAX_CONSENSUS_SCRIPT_SIZE) {
      return false;
    }
    if (!sha256Digest(witnessScript).equals(witnessProgram)) return false;
    const stack = new Stack(...witness.slice(0, -1));
    try {
      evaluateScript(witnessScript, stack, {
        tx: options.tx,
        inputIndex: options.inputIndex,
        scriptCode: witnessScript,
        amount: options.amount,
        witness: true,
      });
    } catch {
      return false;
    }
    return terminalSuccessStrict(stack);
  }

  if (isP2tr(scriptPubKey)) {
    if (scriptSig.length > 0) {
      return false;
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
        return false;
      }
      return verifyP2trScriptPath({
        scriptPubKey,
        witnessItemsWithoutAnnex: wit,
        annex,
        tx: options.tx,
        inputIndex: options.inputIndex,
        spentPrevouts: options.spentPrevouts,
        serializedWitnessForWeight: witSerializedForWeight,
      });
    }
    if (options.spentPrevouts === undefined) {
      return false;
    }
    if (wit.length !== 1) {
      return false;
    }
    const sigblob = wit[0]!;
    if (sigblob.length !== 64 && sigblob.length !== 65) {
      return false;
    }
    let hashType = TAPROOT_SIGHASH_DEFAULT;
    let sig64 = sigblob;
    if (sigblob.length === 65) {
      hashType = sigblob[64]!;
      if (hashType === TAPROOT_SIGHASH_DEFAULT) {
        return false;
      }
      sig64 = sigblob.subarray(0, 64);
    }
    try {
      const msg = taprootSignatureHash(options.tx, options.inputIndex, options.spentPrevouts, {
        hashType,
        annex,
      });
      return verifySchnorrSignature(outputKeyX, msg, sig64);
    } catch {
      return false;
    }
  }

  let redeemCandidate: Buffer | null = null;
  if (isP2sh(scriptPubKey)) {
    try {
      const pushes = parsePushOnlyScriptSig(scriptSig);
      if (pushes.length === 0 || pushes[pushes.length - 1]!.length > MAX_P2SH_REDEEM_PUSH) {
        return false;
      }
      redeemCandidate = pushes[pushes.length - 1]!;
    } catch {
      return false;
    }
  }

  const stackSig = new Stack();
  try {
    evaluateScript(scriptSig, stackSig, {
      tx: options.tx,
      inputIndex: options.inputIndex,
      scriptCode: scriptPubKey,
      amount: options.amount,
      witness: false,
    });
  } catch {
    return false;
  }

  if (redeemCandidate !== null && (stackSig.length === 0 || !stackSig[stackSig.length - 1]!.equals(redeemCandidate))) {
    return false;
  }

  const stack = new Stack(...stackSig);
  try {
    evaluateScript(scriptPubKey, stack, {
      tx: options.tx,
      inputIndex: options.inputIndex,
      scriptCode: scriptPubKey,
      amount: options.amount,
      witness: false,
    });
  } catch {
    return false;
  }

  if (redeemCandidate === null) {
    return terminalSuccessStrict(stack);
  }

  if (!terminalSuccessRelaxed(stack)) return false;
  const expectedH160 = scriptPubKey.subarray(2, 22);
  if (!hash160(redeemCandidate).equals(expectedH160)) return false;

  const inner = new Stack(...stackSig.slice(0, -1));
  try {
    evaluateScript(redeemCandidate, inner, {
      tx: options.tx,
      inputIndex: options.inputIndex,
      scriptCode: redeemCandidate,
      amount: options.amount,
      witness: false,
    });
  } catch {
    return false;
  }
  return terminalSuccessRelaxed(inner);
}
