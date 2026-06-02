import { transactionTxid } from "../consensus/merkle.js";
import { transactionSerialize, type Transaction } from "../messages/transaction.js";

export interface OrphanPoolOptions {
  maxTransactions?: number;
  maxSizeBytes?: number;
}

interface OrphanSlot {
  tx: Transaction;
  unresolved: Set<string>;
  sizeBytes: number;
}

function txSerializedWeightBytes(tx: Transaction): number {
  return transactionSerialize(tx, { includeWitness: true }).length;
}

export function prevoutKey(hash: Buffer, index: number): string {
  return `${hash.toString("hex")}:${index}`;
}

export class OrphanPool {
  readonly maxTransactions: number;
  readonly maxSizeBytes: number;

  private readonly orphans = new Map<string, OrphanSlot>();
  private readonly pendingByPrevout = new Map<string, Set<string>>();
  private sizeBytes = 0;

  constructor(options: OrphanPoolOptions = {}) {
    const maxTransactions = options.maxTransactions ?? 1000;
    const maxSizeBytes = options.maxSizeBytes ?? 512 * 1024;
    if (maxTransactions < 1) {
      throw new Error("maxTransactions must be positive");
    }
    if (maxSizeBytes < 1) {
      throw new Error("maxSizeBytes must be positive");
    }
    this.maxTransactions = maxTransactions;
    this.maxSizeBytes = maxSizeBytes;
  }

  get length(): number {
    return this.orphans.size;
  }

  totalSizeBytes(): number {
    return this.sizeBytes;
  }

  contains(txid: Buffer): boolean {
    return this.orphans.has(txid.toString("hex"));
  }

  get(txid: Buffer): Transaction | null {
    return this.orphans.get(txid.toString("hex"))?.tx ?? null;
  }

  remove(txid: Buffer): boolean {
    const key = txid.toString("hex");
    const slot = this.orphans.get(key);
    if (!slot) {
      return false;
    }
    this.orphans.delete(key);
    this.purgePrevoutRefs(key, slot.unresolved);
    this.sizeBytes -= slot.sizeBytes;
    return true;
  }

  tryAdd(tx: Transaction, missingPrevouts: Iterable<[Buffer, number]>): boolean {
    const missing = [...missingPrevouts];
    if (missing.length === 0) {
      return false;
    }

    const txid = transactionTxid(tx);
    const txKey = txid.toString("hex");
    const size = txSerializedWeightBytes(tx);

    if (this.orphans.has(txKey)) {
      this.remove(txid);
    }

    if (this.orphans.size >= this.maxTransactions) {
      return false;
    }
    if (this.sizeBytes + size > this.maxSizeBytes) {
      return false;
    }

    const unresolved = new Set(missing.map(([hash, index]) => prevoutKey(hash, index)));
    const slot: OrphanSlot = { tx, unresolved, sizeBytes: size };
    this.orphans.set(txKey, slot);
    this.sizeBytes += size;
    for (const key of unresolved) {
      let pending = this.pendingByPrevout.get(key);
      if (!pending) {
        pending = new Set<string>();
        this.pendingByPrevout.set(key, pending);
      }
      pending.add(txKey);
    }
    return true;
  }

  takeReadyTransactionsForPrevout(prevout: [Buffer, number]): Transaction[] {
    const key = prevoutKey(prevout[0], prevout[1]);
    const txids = [...(this.pendingByPrevout.get(key) ?? [])];
    this.pendingByPrevout.delete(key);

    const detached: Transaction[] = [];
    for (const orphanKey of txids) {
      const slot = this.orphans.get(orphanKey);
      if (!slot) {
        continue;
      }
      const depsBefore = new Set(slot.unresolved);
      slot.unresolved.delete(key);
      if (slot.unresolved.size > 0) {
        continue;
      }
      this.orphans.delete(orphanKey);
      this.purgePrevoutRefs(orphanKey, depsBefore);
      this.sizeBytes -= slot.sizeBytes;
      detached.push(slot.tx);
    }
    return detached;
  }

  unresolvedPrevoutsSnapshot(txid: Buffer): ReadonlySet<string> | null {
    const slot = this.orphans.get(txid.toString("hex"));
    return slot ? new Set(slot.unresolved) : null;
  }

  clear(): void {
    this.orphans.clear();
    this.pendingByPrevout.clear();
    this.sizeBytes = 0;
  }

  private purgePrevoutRefs(txidKey: string, prevouts: Iterable<string>): void {
    for (const key of prevouts) {
      const pending = this.pendingByPrevout.get(key);
      if (!pending) {
        continue;
      }
      pending.delete(txidKey);
      if (pending.size === 0) {
        this.pendingByPrevout.delete(key);
      }
    }
  }
}
