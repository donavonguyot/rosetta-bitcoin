import type { ChainParams } from "../chain/params.js";
import type { ProjectTracker } from "../db/tracker.js";
import { META_BLOCKS_VALIDATED_TOTAL, incrMetaCounter } from "../metrics.js";
import { blockDeserialize, type Block } from "./block.js";
import { CoinbaseError, isSpendableOutput, validateBip34Height } from "./coinbase.js";
import { COINBASE_MATURITY } from "./constants.js";
import { transactionTxid } from "./merkle.js";
import { ScriptVerifyError, verifyTransactionInput } from "./script/verify.js";
import { blockSubsidy } from "./subsidy.js";
import { blockHasWitness, validateWitnessCommitment } from "./witness.js";
import type { OutPoint, Transaction } from "../messages/transaction.js";
import { transactionIsCoinbase } from "../messages/transaction.js";
import { BlockValidationError, validateBlock, type ValidateBlockOptions } from "../sync/validate.js";

export class ConnectBlockError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ConnectBlockError";
  }
}

export interface StoredUtxo {
  txid: string;
  vout: number;
  height: number;
  value: number;
  scriptPubKey: Buffer;
  coinbase: boolean;
}

export interface UtxoUndoEntry {
  txid: string;
  vout: number;
  height: number;
  value: number;
  scriptPubKey: Buffer;
  coinbase: boolean;
}

class BlockUtxoView {
  readonly created = new Map<string, StoredUtxo>();
  readonly spent = new Set<string>();

  constructor(
    readonly tracker: ProjectTracker,
    readonly chain: string,
    readonly height: number,
  ) {}

  private key(txid: Buffer, vout: number): string {
    return `${txid.toString("hex")}:${vout}`;
  }

  get(outpoint: OutPoint): StoredUtxo | null {
    const lookup = this.key(outpoint.hash, outpoint.index);
    if (this.spent.has(lookup)) return null;
    const created = this.created.get(lookup);
    if (created) return created;
    return this.tracker.getUtxo(this.chain, outpoint.hash, outpoint.index);
  }

  spend(outpoint: OutPoint): StoredUtxo {
    const lookup = this.key(outpoint.hash, outpoint.index);
    if (this.spent.has(lookup)) {
      throw new ConnectBlockError(
        `double spend of ${Buffer.from(outpoint.hash).reverse().toString("hex")}:${outpoint.index}`,
      );
    }
    const utxo = this.get(outpoint);
    if (utxo === null) {
      throw new ConnectBlockError(
        `missing UTXO ${Buffer.from(outpoint.hash).reverse().toString("hex")}:${outpoint.index}`,
      );
    }
    if (utxo.coinbase && this.height - utxo.height < COINBASE_MATURITY) {
      throw new ConnectBlockError(
        `coinbase output not mature at height ${this.height} (created at ${utxo.height})`,
      );
    }
    this.spent.add(lookup);
    return utxo;
  }

  create(
    txid: Buffer,
    vout: number,
    options: { value: number; scriptPubKey: Buffer; coinbase: boolean },
  ): void {
    const lookup = this.key(txid, vout);
    if (this.created.has(lookup) || this.tracker.getUtxo(this.chain, txid, vout) !== null) {
      throw new ConnectBlockError(
        `duplicate UTXO ${Buffer.from(txid).reverse().toString("hex")}:${vout}`,
      );
    }
    this.created.set(lookup, {
      txid: Buffer.from(txid).reverse().toString("hex"),
      vout,
      height: this.height,
      value: options.value,
      scriptPubKey: options.scriptPubKey,
      coinbase: options.coinbase,
    });
  }

  apply(): void {
    for (const lookup of this.spent) {
      if (this.created.has(lookup)) continue;
      const [txidHex, voutText] = lookup.split(":");
      this.tracker.spendUtxo(this.chain, Buffer.from(txidHex!, "hex"), Number.parseInt(voutText!, 10));
    }
    for (const utxo of this.created.values()) {
      const internalTxid = Buffer.from(utxo.txid, "hex").reverse();
      const lookup = this.key(internalTxid, utxo.vout);
      if (this.spent.has(lookup)) continue;
      this.tracker.addUtxo(this.chain, internalTxid, utxo.vout, {
        height: utxo.height,
        value: utxo.value,
        scriptPubKey: utxo.scriptPubKey,
        coinbase: utxo.coinbase,
      });
    }
  }
}

function externalSpendUndoEntries(view: BlockUtxoView): UtxoUndoEntry[] {
  const entries: UtxoUndoEntry[] = [];
  for (const lookup of view.spent) {
    if (view.created.has(lookup)) continue;
    const [txidHex, voutText] = lookup.split(":");
    const txid = Buffer.from(txidHex!, "hex");
    const vout = Number.parseInt(voutText!, 10);
    const utxo = view.tracker.getUtxo(view.chain, txid, vout);
    if (utxo === null) {
      throw new ConnectBlockError(
        `internal error: could not capture undo for ${Buffer.from(txid).reverse().toString("hex")}:${vout}`,
      );
    }
    entries.push({
      txid: utxo.txid,
      vout: utxo.vout,
      height: utxo.height,
      value: utxo.value,
      scriptPubKey: utxo.scriptPubKey,
      coinbase: utxo.coinbase,
    });
  }
  return entries;
}

function validateCoinbase(coinbase: Transaction, height: number, totalFees: number): void {
  try {
    validateBip34Height(coinbase, height);
  } catch (error) {
    if (error instanceof CoinbaseError) {
      throw new ConnectBlockError(error.message);
    }
    throw error;
  }

  const subsidy = blockSubsidy(height);
  const allowed = subsidy + totalFees;
  const outputTotal = coinbase.outputs.reduce((sum, output) => sum + output.value, 0);
  if (outputTotal > allowed) {
    throw new ConnectBlockError(
      `coinbase value ${outputTotal} exceeds subsidy+fees ${allowed} at height ${height}`,
    );
  }
}

function validateNonCoinbaseInputs(view: BlockUtxoView, tx: Transaction): number {
  const seenPrevouts = new Set<string>();
  const utxoInfos: StoredUtxo[] = [];
  for (const txIn of tx.inputs) {
    const outpoint = txIn.previousOutput;
    const lookup = `${outpoint.hash.toString("hex")}:${outpoint.index}`;
    if (seenPrevouts.has(lookup)) {
      throw new ConnectBlockError(
        `double spend of ${Buffer.from(outpoint.hash).reverse().toString("hex")}:${outpoint.index}`,
      );
    }
    seenPrevouts.add(lookup);

    const utxo = view.get(outpoint);
    if (utxo === null) {
      throw new ConnectBlockError(
        `missing UTXO ${Buffer.from(outpoint.hash).reverse().toString("hex")}:${outpoint.index}`,
      );
    }
    if (utxo.coinbase && view.height - utxo.height < COINBASE_MATURITY) {
      throw new ConnectBlockError(
        `coinbase output not mature at height ${view.height} (created at ${utxo.height})`,
      );
    }
    utxoInfos.push(utxo);
  }

  let inputTotal = 0;
  const spentPrevouts = utxoInfos.map(
    (utxo) => [utxo.value, utxo.scriptPubKey] as const,
  );
  for (let inputIndex = 0; inputIndex < tx.inputs.length; inputIndex += 1) {
    const utxo = utxoInfos[inputIndex]!;
    try {
      verifyTransactionInput(tx, inputIndex, {
        scriptPubKey: utxo.scriptPubKey,
        amount: utxo.value,
        spentPrevouts,
      });
    } catch (error) {
      if (error instanceof ScriptVerifyError) {
        throw new ConnectBlockError(error.message);
      }
      throw error;
    }
    inputTotal += utxo.value;
  }

  for (const txIn of tx.inputs) {
    view.spend(txIn.previousOutput);
  }

  return inputTotal;
}

export interface ConnectBlockOptions {
  height: number;
  expectedPrev: Buffer;
  expectedHash?: Buffer;
  chainName?: string;
}

export function connectBlock(
  tracker: ProjectTracker,
  payload: Buffer,
  options: ConnectBlockOptions,
): Block {
  const chainName = options.chainName ?? "testnet4";
  if (options.height !== tracker.getValidatedHeight(chainName) + 1) {
    throw new ConnectBlockError(
      `cannot connect height ${options.height} on top of validated tip ${tracker.getValidatedHeight(chainName)}`,
    );
  }

  let block: Block;
  try {
    const validateOptions: ValidateBlockOptions = {
      expectedPrev: options.expectedPrev,
    };
    if (options.expectedHash !== undefined) {
      validateOptions.expectedHash = options.expectedHash;
    }
    block = validateBlock(payload, validateOptions);
  } catch (error) {
    if (error instanceof BlockValidationError) {
      throw new ConnectBlockError(error.message);
    }
    throw error;
  }

  const view = new BlockUtxoView(tracker, chainName, options.height);
  let totalFees = 0;
  for (const tx of block.transactions) {
    if (transactionIsCoinbase(tx)) {
      continue;
    }
    const inputTotal = validateNonCoinbaseInputs(view, tx);
    const outputTotal = tx.outputs.reduce((sum, output) => sum + output.value, 0);
    if (inputTotal < outputTotal) {
      throw new ConnectBlockError("transaction outputs exceed inputs");
    }
    totalFees += inputTotal - outputTotal;
    const txid = transactionTxid(tx);
    for (let index = 0; index < tx.outputs.length; index += 1) {
      const output = tx.outputs[index]!;
      if (!isSpendableOutput(output.scriptPubKey)) continue;
      view.create(txid, index, {
        value: output.value,
        scriptPubKey: output.scriptPubKey,
        coinbase: false,
      });
    }
  }

  const coinbase = block.transactions[0]!;
  validateCoinbase(coinbase, options.height, totalFees);
  if (blockHasWitness(block)) {
    try {
      validateWitnessCommitment(coinbase, block.transactions);
    } catch (error) {
      throw new ConnectBlockError(error instanceof Error ? error.message : String(error));
    }
  }

  const coinbaseTxid = transactionTxid(coinbase);
  for (let index = 0; index < coinbase.outputs.length; index += 1) {
    const output = coinbase.outputs[index]!;
    if (!isSpendableOutput(output.scriptPubKey)) continue;
    view.create(coinbaseTxid, index, {
      value: output.value,
      scriptPubKey: output.scriptPubKey,
      coinbase: true,
    });
  }

  const undoEntries = externalSpendUndoEntries(view);
  tracker.withTransaction(() => {
    tracker.replaceUtxoUndo(chainName, options.height, undoEntries);
    view.apply();
    tracker.setValidatedTip(chainName, options.height, block.header);
    incrMetaCounter(tracker, META_BLOCKS_VALIDATED_TOTAL);
  });
  return block;
}

export function disconnectBlock(tracker: ProjectTracker, height: number, chain: ChainParams): void {
  const chainName = chain.name;
  const validated = tracker.getValidatedHeight(chainName);
  if (validated !== height) {
    throw new ConnectBlockError(`cannot disconnect height ${height}: validated tip is ${validated}`);
  }
  if (height < 1) {
    throw new ConnectBlockError("cannot disconnect genesis (height < 1)");
  }
  const prevHashHex = tracker.getHeaderHash(chainName, height - 1);
  if (prevHashHex === null) {
    throw new ConnectBlockError(`missing header at height ${height - 1}`);
  }

  let undoEntries: UtxoUndoEntry[];
  try {
    undoEntries = tracker.takeUtxoUndo(chainName, height);
  } catch {
    throw new ConnectBlockError(
      `missing UTXO undo data for height ${height}; reconnect this block or replay the chain (undo is recorded during connect)`,
    );
  }

  tracker.deleteUtxosCreatedAtHeight(chainName, height);
  for (const entry of undoEntries) {
    tracker.addUtxo(chainName, Buffer.from(entry.txid, "hex").reverse(), entry.vout, {
      height: entry.height,
      value: entry.value,
      scriptPubKey: entry.scriptPubKey,
      coinbase: entry.coinbase,
    });
  }
  tracker.setValidatedTip(chainName, height - 1, prevHashHex);
}
