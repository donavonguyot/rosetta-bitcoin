import type { ChainstateSession } from "../chainstate/chainstateSession.js";
import type { ChainstateOutpoint, ChainstateStoredUtxo } from "../chainstate/chainstate.js";
import { META_BLOCKS_VALIDATED_TOTAL } from "../metrics.js";
import { BlockHeaderCodec } from "../messages/headers.js";
import type { OutPoint, Transaction } from "../messages/transaction.js";
import { transactionIsCoinbase } from "../messages/transaction.js";
import { BlockValidationError, validateBlock, type ValidateBlockOptions } from "../sync/validate.js";
import { blockDeserialize, type Block } from "./block.js";
import { CoinbaseError, isSpendableOutput, validateBip34Height } from "./coinbase.js";
import { ConnectBlockError } from "./connect.js";
import { COINBASE_MATURITY } from "./constants.js";
import { transactionTxid } from "./merkle.js";
import { ScriptVerifyError } from "./script/verify.js";
import {
  ScriptVerifyRunner,
  ScriptVerifySettings,
  type ScriptVerifyBlockJob,
  type ScriptVerifyTask,
} from "./script/scriptVerifyRunner.js";
import { blockSubsidy } from "./subsidy.js";
import { blockHasWitness, validateWitnessCommitment } from "./witness.js";

interface NativeViewUtxo {
  txid: Buffer;
  vout: number;
  height: number;
  value: number;
  scriptPubKey: Buffer;
  coinbase: boolean;
}

class NativeBlockUtxoView {
  readonly created = new Map<string, NativeViewUtxo>();
  readonly spent = new Set<string>();
  readonly loaded = new Map<string, NativeViewUtxo>();
  readonly preloaded = new Set<string>();

  constructor(
    readonly session: ChainstateSession,
    readonly chain: string,
    readonly height: number,
  ) {}

  private key(txid: Buffer, vout: number): string {
    return `${txid.toString("hex")}:${vout}`;
  }

  keyFor(outpoint: OutPoint): string {
    return this.key(outpoint.hash, outpoint.index);
  }

  seedLoaded(outpoints: readonly OutPoint[], utxos: readonly (ChainstateStoredUtxo | null)[]): void {
    for (let index = 0; index < outpoints.length; index += 1) {
      const outpoint = outpoints[index]!;
      const lookup = this.keyFor(outpoint);
      this.preloaded.add(lookup);
      const utxo = utxos[index];
      if (utxo !== null && utxo !== undefined) {
        this.loaded.set(lookup, this.toViewUtxo(utxo));
      }
    }
  }

  async get(outpoint: OutPoint): Promise<NativeViewUtxo | null> {
    const lookup = this.key(outpoint.hash, outpoint.index);
    if (this.spent.has(lookup)) return null;
    const created = this.created.get(lookup);
    if (created) return created;
    const loaded = this.loaded.get(lookup);
    if (loaded) return loaded;
    if (this.preloaded.has(lookup)) return null;
    const utxo = await this.session.store.getUtxo(this.chain, outpoint.hash.toString("hex"), outpoint.index);
    if (utxo === null) return null;
    const viewUtxo = this.toViewUtxo(utxo);
    this.loaded.set(lookup, viewUtxo);
    return viewUtxo;
  }

  async spend(outpoint: OutPoint): Promise<NativeViewUtxo> {
    const lookup = this.key(outpoint.hash, outpoint.index);
    if (this.spent.has(lookup)) {
      throw new ConnectBlockError(`double spend of ${displayOutpoint(outpoint)}`);
    }
    const utxo = await this.get(outpoint);
    if (utxo === null) {
      throw new ConnectBlockError(`missing UTXO ${displayOutpoint(outpoint)}`);
    }
    if (utxo.coinbase && this.height - utxo.height < COINBASE_MATURITY) {
      throw new ConnectBlockError(
        `coinbase output not mature at height ${this.height} (created at ${utxo.height})`,
      );
    }
    this.spent.add(lookup);
    return utxo;
  }

  async create(
    txid: Buffer,
    vout: number,
    options: { value: number; scriptPubKey: Buffer; coinbase: boolean },
  ): Promise<void> {
    const lookup = this.key(txid, vout);
    if (this.created.has(lookup) || (await this.session.store.getUtxo(this.chain, txid.toString("hex"), vout)) !== null) {
      throw new ConnectBlockError(`duplicate UTXO ${displayHash(txid)}:${vout}`);
    }
    this.created.set(lookup, {
      txid: Buffer.from(txid),
      vout,
      height: this.height,
      value: options.value,
      scriptPubKey: options.scriptPubKey,
      coinbase: options.coinbase,
    });
  }

  spentOutpoints(): ChainstateOutpoint[] {
    const outpoints: ChainstateOutpoint[] = [];
    for (const lookup of this.spent) {
      if (this.created.has(lookup)) continue;
      const [txid, voutText] = lookup.split(":");
      outpoints.push({ txid: txid!, vout: Number.parseInt(voutText!, 10) });
    }
    return outpoints;
  }

  createdUtxos(): ChainstateStoredUtxo[] {
    const utxos: ChainstateStoredUtxo[] = [];
    for (const utxo of this.created.values()) {
      const lookup = this.key(utxo.txid, utxo.vout);
      if (this.spent.has(lookup)) continue;
      utxos.push(this.toStoredUtxo(utxo));
    }
    return utxos;
  }

  undoEntries(): ChainstateStoredUtxo[] {
    const entries: ChainstateStoredUtxo[] = [];
    for (const lookup of this.spent) {
      if (this.created.has(lookup)) continue;
      const utxo = this.loaded.get(lookup);
      if (!utxo) {
        const [txid, voutText] = lookup.split(":");
        throw new ConnectBlockError(
          `internal error: could not capture undo for ${Buffer.from(txid!, "hex").reverse().toString("hex")}:${voutText}`,
        );
      }
      entries.push(this.toStoredUtxo(utxo));
    }
    return entries;
  }

  private toViewUtxo(utxo: ChainstateStoredUtxo): NativeViewUtxo {
    return {
      txid: Buffer.from(utxo.txid, "hex"),
      vout: utxo.vout,
      height: utxo.height,
      value: Number(utxo.value),
      scriptPubKey: utxo.scriptPubKey,
      coinbase: utxo.coinbase,
    };
  }

  private toStoredUtxo(utxo: NativeViewUtxo): ChainstateStoredUtxo {
    return {
      txid: utxo.txid.toString("hex"),
      vout: utxo.vout,
      height: utxo.height,
      value: BigInt(utxo.value),
      scriptPubKey: utxo.scriptPubKey,
      coinbase: utxo.coinbase,
    };
  }
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

function displayHash(internalHash: Buffer): string {
  return Buffer.from(internalHash).reverse().toString("hex");
}

function outpointLookup(outpoint: OutPoint): string {
  return `${outpoint.hash.toString("hex")}:${outpoint.index}`;
}

function displayOutpoint(outpoint: OutPoint): string {
  return `${displayHash(outpoint.hash)}:${outpoint.index}`;
}

function syncTimingEnabled(): boolean {
  const raw = process.env.SYNC_TIMING;
  return raw === "1" || raw?.toLowerCase() === "true";
}

function elapsedMs(start: bigint): number {
  return Number(process.hrtime.bigint() - start) / 1_000_000;
}

function addTiming(timings: Record<string, number>, stage: string, ms: number): void {
  timings[stage] = (timings[stage] ?? 0) + ms;
}

async function timeAsync<T>(
  timings: Record<string, number>,
  stage: string,
  fn: () => Promise<T>,
): Promise<T> {
  const start = process.hrtime.bigint();
  try {
    return await fn();
  } finally {
    addTiming(timings, stage, elapsedMs(start));
  }
}

function timeSync<T>(timings: Record<string, number>, stage: string, fn: () => T): T {
  const start = process.hrtime.bigint();
  try {
    return fn();
  } finally {
    addTiming(timings, stage, elapsedMs(start));
  }
}

async function preloadBlockPrevouts(view: NativeBlockUtxoView, block: Block): Promise<void> {
  const outpoints: OutPoint[] = [];
  const seen = new Set<string>();
  for (const tx of block.transactions) {
    if (transactionIsCoinbase(tx)) continue;
    for (const txIn of tx.inputs) {
      const outpoint = txIn.previousOutput;
      const lookup = outpointLookup(outpoint);
      if (seen.has(lookup)) continue;
      seen.add(lookup);
      outpoints.push(outpoint);
    }
  }
  if (outpoints.length === 0) return;
  const utxos = await view.session.store.getUtxos(
    view.chain,
    outpoints.map((outpoint) => ({ txid: outpoint.hash.toString("hex"), vout: outpoint.index })),
  );
  view.seedLoaded(outpoints, utxos);
}

async function stageNonCoinbaseTransaction(
  view: NativeBlockUtxoView,
  tx: Transaction,
  transactionIndex: number,
): Promise<{ inputTotal: number; verifyJob: ScriptVerifyBlockJob }> {
  const seenPrevouts = new Set<string>();
  const utxoInfos: NativeViewUtxo[] = [];
  for (const txIn of tx.inputs) {
    const outpoint = txIn.previousOutput;
    const lookup = outpointLookup(outpoint);
    if (seenPrevouts.has(lookup)) {
      throw new ConnectBlockError(`double spend of ${displayOutpoint(outpoint)}`);
    }
    seenPrevouts.add(lookup);

    const utxo = await view.get(outpoint);
    if (utxo === null) {
      throw new ConnectBlockError(`missing UTXO ${displayOutpoint(outpoint)}`);
    }
    if (utxo.coinbase && view.height - utxo.height < COINBASE_MATURITY) {
      throw new ConnectBlockError(
        `coinbase output not mature at height ${view.height} (created at ${utxo.height})`,
      );
    }
    utxoInfos.push(utxo);
    await view.spend(outpoint);
  }

  let inputTotal = 0;
  const spentPrevouts = utxoInfos.map(
    (utxo) => [utxo.value, utxo.scriptPubKey] as const,
  );
  const verifyTasks: ScriptVerifyTask[] = [];
  for (let inputIndex = 0; inputIndex < tx.inputs.length; inputIndex += 1) {
    const utxo = utxoInfos[inputIndex]!;
    verifyTasks.push({
      inputIndex,
      scriptPubKey: utxo.scriptPubKey,
      amount: utxo.value,
    });
    inputTotal += utxo.value;
  }
  return {
    inputTotal,
    verifyJob: {
      transactionIndex,
      transaction: tx,
      spentPrevouts,
      tasks: verifyTasks,
    },
  };
}

async function verifyBlockScriptJobs(
  jobs: readonly ScriptVerifyBlockJob[],
  timings: Record<string, number>,
  scriptVerifyRunner: ScriptVerifyRunner | null,
): Promise<void> {
  const localRunner = scriptVerifyRunner === null
    ? new ScriptVerifyRunner(new ScriptVerifySettings(false, 1, Number.MAX_SAFE_INTEGER))
    : null;
  const runner = scriptVerifyRunner ?? localRunner!;
  try {
    const stats = await runner.verifyBlockInputs(jobs);
    addTiming(timings, "script_verify", stats.elapsedMs);
    if (syncTimingEnabled()) {
      for (const [stage, elapsed] of Object.entries(stats.details)) {
        addTiming(timings, stage, elapsed);
      }
      timings.script_verify_mode = stats.mode === "native_block_parallel" ? 4 : stats.mode === "block_parallel" ? 3 : stats.mode === "tx_parallel" ? 2 : 1;
    }
  } catch (error) {
    if (error instanceof ScriptVerifyError) {
      throw new ConnectBlockError(error.message);
    }
    throw error;
  } finally {
    if (localRunner !== null) {
      await localRunner.close();
    }
  }
}

export interface NativeConnectBlockOptions {
  height: number;
  expectedPrev: Buffer;
  expectedHash?: Buffer;
  chainName?: string;
  scriptVerifyRunner?: ScriptVerifyRunner | undefined | undefined;
}

export async function connectBlockNative(
  session: ChainstateSession,
  payload: Buffer,
  options: NativeConnectBlockOptions,
): Promise<Block> {
  const blockConnectStart = process.hrtime.bigint();
  const timings: Record<string, number> = {
    utxo_load: 0,
    script_verify: 0,
    utxo_apply: 0,
    commit: 0,
    block_connect_store_commit: 0,
  };
  const chainName = options.chainName ?? "testnet4";
  const validatedHeight = await session.store.getValidatedHeight(chainName);
  if (options.height !== validatedHeight + 1) {
    throw new ConnectBlockError(
      `cannot connect height ${options.height} on top of validated tip ${validatedHeight}`,
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
    const blocker = {
      height: options.height,
      failure: error instanceof Error ? error.message : String(error),
      failure_type: error instanceof Error ? error.name : "Error",
      recorded_at: new Date().toISOString(),
    };
    await session.store.setCurrentBlocker(chainName, blocker);
    await session.store.setLastError(chainName, blocker.failure);
    if (error instanceof BlockValidationError) {
      throw new ConnectBlockError(error.message);
    }
    throw error;
  }

  const view = new NativeBlockUtxoView(session, chainName, options.height);
  let totalFees = 0;
  const verifyJobs: ScriptVerifyBlockJob[] = [];
  try {
    await timeAsync(timings, "utxo_load", () => preloadBlockPrevouts(view, block));
    for (let transactionIndex = 0; transactionIndex < block.transactions.length; transactionIndex += 1) {
      const tx = block.transactions[transactionIndex]!;
      if (transactionIsCoinbase(tx)) {
        continue;
      }
      const { inputTotal, verifyJob } = await stageNonCoinbaseTransaction(view, tx, transactionIndex);
      verifyJobs.push(verifyJob);
      const outputTotal = tx.outputs.reduce((sum, output) => sum + output.value, 0);
      if (inputTotal < outputTotal) {
        throw new ConnectBlockError("transaction outputs exceed inputs");
      }
      totalFees += inputTotal - outputTotal;
      const txid = transactionTxid(tx);
      for (let index = 0; index < tx.outputs.length; index += 1) {
        const output = tx.outputs[index]!;
        if (!isSpendableOutput(output.scriptPubKey)) continue;
        await view.create(txid, index, {
          value: output.value,
          scriptPubKey: output.scriptPubKey,
          coinbase: false,
        });
      }
    }

    await verifyBlockScriptJobs(verifyJobs, timings, options.scriptVerifyRunner ?? null);

    const coinbase = block.transactions[0]!;
    validateCoinbase(coinbase, options.height, totalFees);
    if (blockHasWitness(block)) {
      validateWitnessCommitment(coinbase, block.transactions);
    }

    const coinbaseTxid = transactionTxid(coinbase);
    for (let index = 0; index < coinbase.outputs.length; index += 1) {
      const output = coinbase.outputs[index]!;
      if (!isSpendableOutput(output.scriptPubKey)) continue;
      await view.create(coinbaseTxid, index, {
        value: output.value,
        scriptPubKey: output.scriptPubKey,
        coinbase: true,
      });
    }
  } catch (error) {
    const blocker = {
      height: options.height,
      block_hash: options.expectedHash
        ? Buffer.from(options.expectedHash).reverse().toString("hex")
        : BlockHeaderCodec.blockHashHex(block.header),
      failure: error instanceof Error ? error.message : String(error),
      failure_type: error instanceof Error ? error.name : "Error",
      recorded_at: new Date().toISOString(),
    };
    await session.store.setCurrentBlocker(chainName, blocker);
    await session.store.setLastError(chainName, blocker.failure);
    throw error instanceof ConnectBlockError ? error : new ConnectBlockError(blocker.failure);
  }

  const writeResult = session.blockStore.write(payload);
  const blockHash = displayHash(options.expectedHash ?? BlockHeaderCodec.blockHash(block.header));
  const commitPayload = timeSync(timings, "utxo_apply", () => ({
    chain: chainName,
    height: options.height,
    blockHash,
    blockIndex: {
      height: options.height,
      blockHash,
      fileNumber: writeResult.fileNumber,
      fileOffset: writeResult.offset,
      blockSize: writeResult.size,
    },
    spentOutpoints: view.spentOutpoints(),
    createdUtxos: view.createdUtxos(),
    undoEntries: view.undoEntries(),
  }));
  await timeAsync(timings, "commit", () => session.store.commitBlock(commitPayload));
  await session.store.setCurrentBlocker(chainName, null);
  await session.store.setLastError(chainName, null);
  await session.store.logEvent("metrics", META_BLOCKS_VALIDATED_TOTAL, "info", JSON.stringify({ increment: 1 }));
  timings.block_connect_store_commit = elapsedMs(blockConnectStart);
  if (syncTimingEnabled()) {
    const details = {
      height: options.height,
      block_hash: blockHash,
      timings_ms: Object.fromEntries(
        Object.entries(timings).map(([stage, value]) => [stage, Number(value.toFixed(3))]),
      ),
    };
    const detailsJson = JSON.stringify(details);
    await session.store.logEvent("timing", "block_connect_store_commit", "info", detailsJson);
    console.error(`SYNC_TIMING ${detailsJson}`);
  }
  return block;
}

export function deserializeStoredNativeBlock(session: ChainstateSession, fileName: string, offset: number, size: number): Block {
  return blockDeserialize(session.blockStore.read(fileName, offset, size));
}
