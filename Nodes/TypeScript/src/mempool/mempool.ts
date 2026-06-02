import { Settings } from "../config/settings.js";
import { transactionTxid } from "../consensus/merkle.js";
import { ScriptVerifyError, verifyTransactionInput } from "../consensus/script/verify.js";
import { transactionWtxid } from "../consensus/witness.js";
import type { ProjectTracker } from "../db/tracker.js";
import { MSG_TX, MSG_WITNESS_TX } from "../messages/inventory.js";
import {
  transactionIsCoinbase,
  transactionSerialize,
  type Transaction,
  type TxIn,
} from "../messages/transaction.js";

import { OrphanPool, prevoutKey } from "./orphanPool.js";

interface MempoolEntry {
  tx: Transaction;
  addedAt: number;
}

export interface UtxoOverlayRow {
  value: number;
  scriptPubKeyHex: string;
}

export interface AcceptTransactionOptions {
  settings?: Settings;
  chain?: string;
  peerHost?: string;
  mempoolClaimedPrevouts?: ReadonlySet<string> | null;
  mempoolUtxoOverlay?: ReadonlyMap<string, UtxoOverlayRow> | null;
  orphanPool?: OrphanPool | null;
  deferOrphans?: boolean;
}

export interface MempoolOptions {
  maxSizeBytes?: number;
  tracker?: ProjectTracker | null;
  orphanPool?: OrphanPool | null;
  mempoolMaxCount?: number | null;
  mempoolMaxAgeSeconds?: number | null;
  settings?: Settings;
}

function inputPrevoutKey(txIn: TxIn): string {
  return prevoutKey(txIn.previousOutput.hash, txIn.previousOutput.index);
}

export function estimateTxVirtualSizeScaffold(tx: Transaction): number {
  return Math.max(1, transactionSerialize(tx, { includeWitness: false }).length);
}

function transactionFeeKnownPrevouts(
  tx: Transaction,
  tracker: ProjectTracker,
  chain: string,
): number | null {
  if (transactionIsCoinbase(tx)) {
    return null;
  }
  let spent = 0;
  for (const input of tx.inputs) {
    const row = tracker.getUtxo(chain, input.previousOutput.hash, input.previousOutput.index);
    if (row === null) {
      return null;
    }
    spent += row.value;
  }
  const outSum = tx.outputs.reduce((sum, output) => sum + output.value, 0);
  return spent - outSum;
}

function effectiveUtxoRow(
  tracker: ProjectTracker,
  chain: string,
  mempoolUtxoOverlay: ReadonlyMap<string, UtxoOverlayRow> | null | undefined,
  txIn: TxIn,
): { value: number; scriptPubKey: Buffer } | null {
  const key = inputPrevoutKey(txIn);
  const rowInternal = tracker.getUtxo(chain, txIn.previousOutput.hash, txIn.previousOutput.index);
  if (rowInternal !== null) {
    return { value: rowInternal.value, scriptPubKey: rowInternal.scriptPubKey };
  }
  if (mempoolUtxoOverlay === null || mempoolUtxoOverlay === undefined) {
    return null;
  }
  const overlay = mempoolUtxoOverlay.get(key);
  if (!overlay) {
    return null;
  }
  return {
    value: overlay.value,
    scriptPubKey: Buffer.from(overlay.scriptPubKeyHex, "hex"),
  };
}

export function collectMissingPrevouts(
  tx: Transaction,
  tracker: ProjectTracker,
  options: {
    chain?: string;
    mempoolUtxoOverlay?: ReadonlyMap<string, UtxoOverlayRow> | null;
    mempoolClaimedPrevouts?: ReadonlySet<string> | null;
  } = {},
): Set<string> | null {
  const chain = options.chain ?? "testnet4";
  if (transactionIsCoinbase(tx)) {
    return new Set();
  }
  if (tx.inputs.length === 0 || tx.outputs.length === 0) {
    return new Set();
  }

  const seenPrevouts = new Set<string>();
  const missing = new Set<string>();
  for (const txIn of tx.inputs) {
    const key = inputPrevoutKey(txIn);
    if (seenPrevouts.has(key)) {
      return null;
    }
    seenPrevouts.add(key);
    if (options.mempoolClaimedPrevouts?.has(key)) {
      return null;
    }
    const row = effectiveUtxoRow(tracker, chain, options.mempoolUtxoOverlay, txIn);
    if (row === null) {
      missing.add(key);
    }
  }
  return missing;
}

function missingPrevoutTuples(missing: Set<string>): Array<[Buffer, number]> {
  return [...missing].map((key) => {
    const separator = key.lastIndexOf(":");
    const hex = key.slice(0, separator);
    const index = Number.parseInt(key.slice(separator + 1), 10);
    return [Buffer.from(hex, "hex"), index];
  });
}

export function acceptTransaction(
  tx: Transaction,
  tracker: ProjectTracker,
  options: AcceptTransactionOptions = {},
): boolean {
  const settings = options.settings;
  const resolved = settings ?? Settings.fromEnv();
  const chain = options.chain ?? resolved.chain;
  const peerHost = options.peerHost ?? "";

  if (transactionIsCoinbase(tx)) {
    tracker.logEvent("mempool", "Rejected coinbase relay", "warning", { peer: peerHost });
    return false;
  }
  if (tx.inputs.length === 0) {
    tracker.logEvent("mempool", "Rejected tx: no inputs", "warning", { peer: peerHost });
    return false;
  }
  if (tx.outputs.length === 0) {
    tracker.logEvent("mempool", "Rejected tx: no outputs", "warning", { peer: peerHost });
    return false;
  }

  const minFeerate = resolved.minRelayFeerateSatVb;
  const allowOrphanEnqueue =
    options.orphanPool !== undefined &&
    options.orphanPool !== null &&
    options.deferOrphans === true &&
    resolved.enableOrphanPool;

  const seenPrevouts = new Set<string>();
  let inputTotalSat = 0;
  const missingPrevouts = new Set<string>();
  const rowsForInputs: Array<{ value: number; scriptPubKey: Buffer } | null> = new Array(tx.inputs.length).fill(
    null,
  );

  for (let inputIndex = 0; inputIndex < tx.inputs.length; inputIndex += 1) {
    const txIn = tx.inputs[inputIndex]!;
    const key = inputPrevoutKey(txIn);

    if (seenPrevouts.has(key)) {
      tracker.logEvent("mempool", "Rejected tx: duplicate prevout spends in single transaction", "warning", {
        peer: peerHost,
        duplicatePrevoutIndex: txIn.previousOutput.index,
      });
      return false;
    }
    seenPrevouts.add(key);

    if (options.mempoolClaimedPrevouts?.has(key)) {
      tracker.logEvent("mempool", "Rejected tx: mempool already spends this prevout", "warning", {
        peer: peerHost,
        spentTxid: Buffer.from(txIn.previousOutput.hash).reverse().toString("hex"),
        spentVout: txIn.previousOutput.index,
      });
      return false;
    }

    const row = effectiveUtxoRow(tracker, chain, options.mempoolUtxoOverlay, txIn);
    if (row === null) {
      missingPrevouts.add(key);
      continue;
    }
    rowsForInputs[inputIndex] = row;
  }

  if (missingPrevouts.size > 0) {
    if (allowOrphanEnqueue) {
      const enqueued = options.orphanPool!.tryAdd(tx, missingPrevoutTuples(missingPrevouts));
      if (enqueued) {
        tracker.logEvent("mempool", "Deferred tx: queued in orphan pool (missing prevouts)", "warning", {
          peer: peerHost,
          missingPrevouts: missingPrevoutTuples(missingPrevouts).map(([hash, vout]) => [
            Buffer.from(hash).reverse().toString("hex"),
            vout,
          ]),
        });
        return false;
      }
      tracker.logEvent("mempool", "Rejected tx: orphan pool capacity exhausted", "warning", {
        peer: peerHost,
        missingPrevouts: missingPrevoutTuples(missingPrevouts).map(([hash, vout]) => [
          Buffer.from(hash).reverse().toString("hex"),
          vout,
        ]),
      });
      return false;
    }
    tracker.logEvent("mempool", "Rejected tx: unknown prevouts (not in effective UTXO view)", "warning", {
      peer: peerHost,
      missingPrevouts: missingPrevoutTuples(missingPrevouts).map(([hash, vout]) => [
        Buffer.from(hash).reverse().toString("hex"),
        vout,
      ]),
    });
    return false;
  }

  for (let inputIndex = 0; inputIndex < tx.inputs.length; inputIndex += 1) {
    const row = rowsForInputs[inputIndex]!;
    try {
      verifyTransactionInput(tx, inputIndex, {
        scriptPubKey: row.scriptPubKey,
        amount: row.value,
      });
    } catch (error) {
      const message = error instanceof ScriptVerifyError ? error.message : String(error);
      tracker.logEvent("mempool", `Rejected tx: script/input verification failed: ${message}`, "warning", {
        peer: peerHost,
        inputIndex,
      });
      return false;
    }
    inputTotalSat += row.value;
  }

  const outputTotalSat = tx.outputs.reduce((sum, output) => sum + output.value, 0);
  if (outputTotalSat > inputTotalSat) {
    tracker.logEvent("mempool", "Rejected tx: outputs exceed inputs (negative fee)", "warning", {
      peer: peerHost,
      inputTotalSat,
      outputTotalSat,
    });
    return false;
  }

  const fee = inputTotalSat - outputTotalSat;
  if (minFeerate > 0) {
    const vsize = estimateTxVirtualSizeScaffold(tx);
    if (vsize <= 0) {
      return false;
    }
    const required = minFeerate * vsize;
    if (fee < required) {
      tracker.logEvent("mempool", "Rejected tx: fee rate below min relay", "warning", {
        peer: peerHost,
        fee,
        vbytesApprox: vsize,
        minSatVbyte: minFeerate,
      });
      return false;
    }
  }

  return true;
}

export function transactionMeetsPeerFeefilter(
  tx: Transaction,
  tracker: ProjectTracker,
  peerFeeFilterSatKvb: number | null,
  chain?: string,
): boolean {
  if (peerFeeFilterSatKvb === null || peerFeeFilterSatKvb <= 0) {
    return true;
  }
  const vsize = estimateTxVirtualSizeScaffold(tx);
  if (vsize <= 0) {
    return false;
  }
  const fee = transactionFeeKnownPrevouts(tx, tracker, chain ?? "testnet4");
  if (fee === null || fee < 0) {
    return true;
  }
  return fee * 1000 >= peerFeeFilterSatKvb * vsize;
}

export class Mempool {
  private readonly maxSizeBytes: number;
  private readonly maxTxCount: number;
  private readonly maxAgeSeconds: number;
  private readonly tracker: ProjectTracker | null;
  private readonly orphanPool: OrphanPool | null;

  private readonly txById = new Map<string, MempoolEntry>();
  private readonly byWtxid = new Map<string, Transaction>();
  private readonly spenders = new Map<string, Set<string>>();
  private readonly claimedPrevouts = new Set<string>();
  private sizeBytes = 0;

  constructor(options: MempoolOptions = {}) {
    const policy = options.settings ?? Settings.fromEnv();
    const maxSizeBytes = options.maxSizeBytes ?? 32 * 1024 * 1024;
    const maxTxCount = options.mempoolMaxCount ?? policy.mempoolMaxCount;
    const maxAgeSeconds = options.mempoolMaxAgeSeconds ?? policy.mempoolMaxAgeSeconds;

    if (maxSizeBytes < 1) {
      throw new Error("maxSizeBytes must be positive");
    }
    if (maxTxCount < 0) {
      throw new Error("mempoolMaxCount must be >= 0 (0 means unlimited)");
    }
    if (maxAgeSeconds < 0) {
      throw new Error("mempoolMaxAgeSeconds must be >= 0 (0 disables age eviction)");
    }

    this.maxSizeBytes = maxSizeBytes;
    this.maxTxCount = maxTxCount;
    this.maxAgeSeconds = maxAgeSeconds;
    this.tracker = options.tracker ?? null;
    this.orphanPool = options.orphanPool ?? null;
    this.persistStats();
  }

  acceptTransaction(tx: Transaction, options: AcceptTransactionOptions = {}): boolean {
    if (this.tracker === null) {
      throw new Error("Mempool.acceptTransaction requires a tracker");
    }
    const settings = options.settings ?? Settings.fromEnv();
    if (
      !acceptTransaction(tx, this.tracker, {
        ...options,
        settings,
        chain: options.chain ?? settings.chain,
        mempoolClaimedPrevouts: options.mempoolClaimedPrevouts ?? this.claimedPrevoutsFrozen(),
      })
    ) {
      return false;
    }
    return this.add(tx);
  }

  private mempoolUtxoOverlay(): Map<string, UtxoOverlayRow> {
    const rows = new Map<string, UtxoOverlayRow>();
    for (const entry of this.txById.values()) {
      const candidate = entry.tx;
      const prodTxid = transactionTxid(candidate);
      for (let voutIdx = 0; voutIdx < candidate.outputs.length; voutIdx += 1) {
        const txOut = candidate.outputs[voutIdx]!;
        rows.set(prevoutKey(prodTxid, voutIdx), {
          value: txOut.value,
          scriptPubKeyHex: txOut.scriptPubKey.toString("hex"),
        });
      }
    }
    return rows;
  }

  private clusterPostOrder(root: string): string[] {
    const order: string[] = [];
    const visiting = new Set<string>();

    const dfs = (tid: string): void => {
      if (!this.txById.has(tid)) {
        return;
      }
      if (visiting.has(tid)) {
        return;
      }
      visiting.add(tid);
      for (const child of [...(this.spenders.get(tid) ?? [])]) {
        dfs(child);
      }
      visiting.delete(tid);
      order.push(tid);
    };

    dfs(root);
    return order;
  }

  private removeSingle(txidKey: string): boolean {
    const entry = this.txById.get(txidKey);
    if (!entry) {
      return false;
    }
    this.txById.delete(txidKey);
    const tx = entry.tx;
    this.byWtxid.delete(transactionWtxid(tx).toString("hex"));

    for (const input of tx.inputs) {
      this.claimedPrevouts.delete(inputPrevoutKey(input));
      const parentId = input.previousOutput.hash.toString("hex");
      const childSpenders = this.spenders.get(parentId);
      if (childSpenders) {
        childSpenders.delete(txidKey);
        if (childSpenders.size === 0) {
          this.spenders.delete(parentId);
        }
      }
    }
    this.spenders.delete(txidKey);
    this.sizeBytes -= this.serializedLen(tx);
    return true;
  }

  private evictOldestCluster(): number {
    if (this.txById.size === 0) {
      return 0;
    }
    let root = "";
    let oldest = Number.POSITIVE_INFINITY;
    for (const [tid, entry] of this.txById) {
      if (entry.addedAt < oldest) {
        oldest = entry.addedAt;
        root = tid;
      }
    }
    let removed = 0;
    for (const tid of this.clusterPostOrder(root)) {
      if (this.txById.has(tid) && this.removeSingle(tid)) {
        removed += 1;
      }
    }
    return removed;
  }

  private linkIncomingSpenders(txidKey: string, tx: Transaction): void {
    for (const input of tx.inputs) {
      const parentId = input.previousOutput.hash.toString("hex");
      if (this.txById.has(parentId)) {
        let spenders = this.spenders.get(parentId);
        if (!spenders) {
          spenders = new Set<string>();
          this.spenders.set(parentId, spenders);
        }
        spenders.add(txidKey);
      }
    }
  }

  evictExpired(now: number): number {
    if (this.maxAgeSeconds <= 0) {
      return 0;
    }
    let removed = 0;
    while (true) {
      const expired: string[] = [];
      for (const [tid, entry] of this.txById) {
        if (now - entry.addedAt > this.maxAgeSeconds) {
          expired.push(tid);
        }
      }
      if (expired.length === 0) {
        this.persistStats();
        return removed;
      }
      let root = expired[0]!;
      let oldest = this.txById.get(root)!.addedAt;
      for (const tid of expired.slice(1)) {
        const addedAt = this.txById.get(tid)!.addedAt;
        if (addedAt < oldest) {
          oldest = addedAt;
          root = tid;
        }
      }
      for (const tid of this.clusterPostOrder(root)) {
        if (this.txById.has(tid) && this.removeSingle(tid)) {
          removed += 1;
        }
      }
    }
  }

  evictOverCapacity(): number {
    let removed = 0;
    while (this.txById.size > 0) {
      const overCount = this.maxTxCount > 0 && this.txById.size > this.maxTxCount;
      const overBytes = this.sizeBytes > this.maxSizeBytes;
      if (!overCount && !overBytes) {
        break;
      }
      const n = this.evictOldestCluster();
      if (n === 0) {
        break;
      }
      removed += n;
    }
    this.persistStats();
    return removed;
  }

  private tryPromoteOrphansFor(producer: Transaction): void {
    if (this.orphanPool === null || this.tracker === null) {
      return;
    }
    const prodTxid = transactionTxid(producer);
    for (let voutIdx = 0; voutIdx < producer.outputs.length; voutIdx += 1) {
      for (const candidate of this.orphanPool.takeReadyTransactionsForPrevout([prodTxid, voutIdx])) {
        const overlay = this.mempoolUtxoOverlay();
        const promoteSettings = Settings.fromEnv({ enableOrphanPool: true });
        const acceptedHere = acceptTransaction(candidate, this.tracker, {
          settings: promoteSettings,
          chain: promoteSettings.chain,
          mempoolClaimedPrevouts: this.claimedPrevoutsFrozen(),
          mempoolUtxoOverlay: overlay,
          orphanPool: this.orphanPool,
          deferOrphans: true,
        });
        if (acceptedHere && this.add(candidate)) {
          continue;
        }
        const requeue = collectMissingPrevouts(candidate, this.tracker, {
          chain: promoteSettings.chain,
          mempoolUtxoOverlay: overlay,
          mempoolClaimedPrevouts: this.claimedPrevoutsFrozen(),
        });
        if (requeue !== null && requeue.size > 0) {
          this.orphanPool.tryAdd(candidate, missingPrevoutTuples(requeue));
        }
      }
    }
  }

  claimedPrevoutsFrozen(): ReadonlySet<string> {
    return this.claimedPrevouts;
  }

  entryAddedAt(txid: Buffer): number | null {
    const entry = this.txById.get(txid.toString("hex"));
    return entry ? entry.addedAt : null;
  }

  private persistStats(): void {
    if (this.tracker === null) {
      return;
    }
    this.tracker.setMeta("mempool_tx_count", String(this.txById.size));
    this.tracker.setMeta("mempool_size_bytes", String(this.sizeBytes));
  }

  size(): number {
    return this.txById.size;
  }

  get(txid: Buffer): Transaction | null {
    return this.txById.get(txid.toString("hex"))?.tx ?? null;
  }

  *iterPooledTransactions(): Generator<Transaction> {
    for (const entry of this.txById.values()) {
      yield entry.tx;
    }
  }

  getForInv(invType: number, invHash: Buffer): Transaction | null {
    if (invType === MSG_WITNESS_TX) {
      return this.byWtxid.get(invHash.toString("hex")) ?? null;
    }
    if (invType === MSG_TX) {
      return this.txById.get(invHash.toString("hex"))?.tx ?? null;
    }
    return null;
  }

  private serializedLen(tx: Transaction): number {
    return transactionSerialize(tx, { includeWitness: true }).length;
  }

  contains(txid: Buffer): boolean {
    return this.txById.has(txid.toString("hex"));
  }

  add(tx: Transaction): boolean {
    const txid = transactionTxid(tx);
    const txidKey = txid.toString("hex");
    if (this.txById.has(txidKey)) {
      return false;
    }

    const now = Date.now() / 1000;
    this.evictExpired(now);
    const size = this.serializedLen(tx);

    while (this.maxTxCount > 0 && this.txById.size >= this.maxTxCount) {
      if (this.evictOldestCluster() === 0) {
        break;
      }
    }
    while (this.sizeBytes + size > this.maxSizeBytes) {
      if (this.evictOldestCluster() === 0) {
        break;
      }
    }
    if (this.sizeBytes + size > this.maxSizeBytes) {
      return false;
    }
    if (this.maxTxCount > 0 && this.txById.size >= this.maxTxCount) {
      return false;
    }

    const wtxid = transactionWtxid(tx);
    this.txById.set(txidKey, { tx, addedAt: now });
    this.byWtxid.set(wtxid.toString("hex"), tx);
    this.linkIncomingSpenders(txidKey, tx);
    for (const input of tx.inputs) {
      this.claimedPrevouts.add(inputPrevoutKey(input));
    }
    this.sizeBytes += size;
    this.persistStats();
    this.tryPromoteOrphansFor(tx);
    return true;
  }

  remove(txid: Buffer): boolean {
    if (!this.removeSingle(txid.toString("hex"))) {
      return false;
    }
    this.persistStats();
    return true;
  }

  totalSizeBytes(): number {
    return this.sizeBytes;
  }
}

export { OrphanPool, prevoutKey } from "./orphanPool.js";
