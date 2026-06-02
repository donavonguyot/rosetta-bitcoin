import {
  isP2pk,
  isP2pkh,
  isP2sh,
  isP2tr,
  isP2wpkh,
  isP2wsh,
  verifyScript,
  witnessProgramVersion,
} from "./interpreter.js";
import type { Transaction } from "../../messages/transaction.js";

export class ScriptVerifyError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ScriptVerifyError";
  }
}

export function verifyTransactionInput(
  transaction: Transaction,
  inputIndex: number,
  options: {
    scriptPubKey: Buffer;
    amount: number;
    spentPrevouts?: readonly (readonly [number, Buffer])[];
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

  if (
    !(
      isP2pk(options.scriptPubKey) ||
      isP2pkh(options.scriptPubKey) ||
      isP2wpkh(options.scriptPubKey) ||
      isP2sh(options.scriptPubKey) ||
      isP2wsh(options.scriptPubKey) ||
      isP2tr(options.scriptPubKey)
    )
  ) {
    throw new ScriptVerifyError("unsupported scriptPubKey template");
  }

  const verifyOptions: {
    tx: Transaction;
    inputIndex: number;
    amount: number;
    witness: readonly Buffer[];
    spentPrevouts?: readonly (readonly [number, Buffer])[];
  } = {
    tx: transaction,
    inputIndex,
    amount: options.amount,
    witness,
  };
  if (options.spentPrevouts !== undefined) {
    verifyOptions.spentPrevouts = options.spentPrevouts;
  }

  if (!verifyScript(txIn.scriptSig, options.scriptPubKey, verifyOptions)) {
    throw new ScriptVerifyError(`script verification failed for input ${inputIndex}`);
  }
}
