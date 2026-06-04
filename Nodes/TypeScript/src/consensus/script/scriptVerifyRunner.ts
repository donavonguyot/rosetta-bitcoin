import { availableParallelism } from "node:os";
import { Worker } from "node:worker_threads";

import { transactionSerialize, type Transaction } from "../../messages/transaction.js";
import { ScriptVerifyError, verifyTransactionInput } from "./verify.js";
import { TransactionSighashCache } from "./sighash.js";

export interface ScriptVerifyTask {
  inputIndex: number;
  scriptPubKey: Buffer;
  amount: number;
}

export interface ScriptVerifyBlockJob {
  transactionIndex: number;
  transaction: Transaction;
  spentPrevouts: readonly (readonly [number, Buffer])[];
  tasks: readonly ScriptVerifyTask[];
}

export type ScriptVerifyMode = "sequential" | "tx_parallel" | "block_parallel" | "native_block_parallel";

export interface ScriptVerifyRunStats {
  elapsedMs: number;
  mode: ScriptVerifyMode;
  details: Record<string, number>;
}

interface WorkerTask {
  inputIndex: number;
  scriptPubKey: Buffer;
  amount: number;
}

interface WorkerPrevout {
  amount: number;
  scriptPubKey: Buffer;
}

interface WorkerTransactionJob {
  transactionIndex: number;
  transaction: Buffer;
  spentPrevouts: WorkerPrevout[];
  tasks: WorkerTask[];
}

interface WorkerRequest {
  id: number;
  mode: ScriptVerifyMode;
  jobs: WorkerTransactionJob[];
}

interface WorkerFailure {
  transactionIndex: number;
  inputIndex: number;
  message: string;
  name: string;
}

interface WorkerResponse {
  id: number;
  elapsedMs: number;
  details: Record<string, number>;
  failures: WorkerFailure[];
}

interface PendingJob {
  request: WorkerRequest;
  resolve: (response: WorkerResponse) => void;
  reject: (error: Error) => void;
}

interface WorkerSlot {
  worker: Worker;
  busy: boolean;
  current: PendingJob | null;
}

export class ScriptVerifySettings {
  constructor(
    readonly parallelEnabled: boolean,
    readonly maxWorkers: number,
    readonly minInputs: number,
  ) {}

  static fromEnv(env: NodeJS.ProcessEnv = process.env): ScriptVerifySettings {
    const defaultWorkers = Math.max(1, availableParallelism() - 1);
    return new ScriptVerifySettings(
      envBool(env.PAR_SCRIPT_VERIFY, true),
      envInt(env.PAR_SCRIPT_WORKERS, defaultWorkers, 1),
      envInt(env.PAR_SCRIPT_MIN_INPUTS, 2, 1),
    );
  }
}

export class ScriptVerifyRunner {
  private readonly workers: WorkerSlot[] = [];
  private readonly queue: PendingJob[] = [];
  private nextId = 1;
  private closed = false;

  constructor(readonly settings = ScriptVerifySettings.fromEnv()) {}

  async verifyInputs(
    transaction: Transaction,
    spentPrevouts: readonly (readonly [number, Buffer])[],
    tasks: readonly ScriptVerifyTask[],
  ): Promise<ScriptVerifyRunStats> {
    return this.verifyBlockInputs([
      {
        transactionIndex: 0,
        transaction,
        spentPrevouts,
        tasks,
      },
    ]);
  }

  async verifyBlockInputs(jobs: readonly ScriptVerifyBlockJob[]): Promise<ScriptVerifyRunStats> {
    if (this.closed) {
      throw new Error("script verify runner is closed");
    }
    const inputCount = jobs.reduce((sum, job) => sum + job.tasks.length, 0);
    if (inputCount === 0) return { elapsedMs: 0, mode: "sequential", details: {} };
    if (!this.settings.parallelEnabled || this.settings.maxWorkers <= 1 || inputCount < this.settings.minInputs) {
      return verifySequentialBlock(jobs);
    }
    return this.verifyBlockParallel(jobs);
  }

  async close(): Promise<void> {
    this.closed = true;
    const queued = this.queue.splice(0);
    for (const job of queued) {
      job.reject(new Error("script verify runner closed"));
    }
    const terminations = this.workers.map((slot) => slot.worker.terminate());
    this.workers.length = 0;
    await Promise.allSettled(terminations);
  }

  private async verifyBlockParallel(jobs: readonly ScriptVerifyBlockJob[]): Promise<ScriptVerifyRunStats> {
    const serializeStarted = process.hrtime.bigint();
    const workerJobs = jobs.map((job) => ({
      transactionIndex: job.transactionIndex,
      transaction: transactionSerialize(job.transaction, { includeWitness: true }),
      spentPrevouts: job.spentPrevouts.map(([amount, scriptPubKey]) => ({ amount, scriptPubKey })),
      tasks: job.tasks.map((task) => ({
        inputIndex: task.inputIndex,
        scriptPubKey: task.scriptPubKey,
        amount: task.amount,
      })),
    }));
    const serializeMs = elapsedMs(serializeStarted);
    const inputCount = jobs.reduce((sum, job) => sum + job.tasks.length, 0);
    const workerCount = Math.min(this.settings.maxWorkers, inputCount);
    const chunks = chunkBlockJobs(workerJobs, workerCount);
    const waitStarted = process.hrtime.bigint();
    const mode: ScriptVerifyMode = "native_block_parallel";
    const results = await Promise.all(
      chunks.map((chunk) =>
        this.runJob({
          id: this.nextId++,
          mode,
          jobs: chunk,
        }),
      ),
    );
    const waitMs = elapsedMs(waitStarted);
    const failures = results.flatMap((result) => result.failures);
    if (failures.length > 0) {
      failures.sort((left, right) => left.transactionIndex - right.transactionIndex || left.inputIndex - right.inputIndex);
      throw new ScriptVerifyError(failures[0]!.message);
    }
    const details = mergeDetails(results.map((result) => result.details));
    details.script_worker_serialize = (details.script_worker_serialize ?? 0) + serializeMs;
    details.script_worker_wait = (details.script_worker_wait ?? 0) + waitMs;
    return {
      elapsedMs: results.reduce((sum, result) => sum + result.elapsedMs, 0),
      mode,
      details,
    };
  }

  private runJob(request: WorkerRequest): Promise<WorkerResponse> {
    return new Promise<WorkerResponse>((resolve, reject) => {
      const job: PendingJob = { request, resolve, reject };
      const idle = this.workers.find((slot) => !slot.busy);
      if (idle !== undefined) {
        this.assignJob(idle, job);
        return;
      }
      if (this.workers.length < this.settings.maxWorkers) {
        this.assignJob(this.createWorker(), job);
        return;
      }
      this.queue.push(job);
    });
  }

  private createWorker(): WorkerSlot {
    const isTypeScriptRuntime = import.meta.url.endsWith(".ts");
    const worker = new Worker(
      new URL(isTypeScriptRuntime ? "./scriptVerifyWorker.ts" : "./scriptVerifyWorker.js", import.meta.url),
      {
        execArgv: isTypeScriptRuntime ? ["--import", "tsx"] : [],
      },
    );
    const slot: WorkerSlot = { worker, busy: false, current: null };
    worker.on("message", (message: WorkerResponse) => {
      const current = slot.current;
      slot.current = null;
      slot.busy = false;
      if (current === null) return;
      if (message.id !== current.request.id) {
        current.reject(new Error("script verify worker returned mismatched job id"));
      } else {
        current.resolve(message);
      }
      this.drain(slot);
    });
    worker.on("error", (error) => {
      const current = slot.current;
      slot.current = null;
      slot.busy = false;
      if (current !== null) {
        current.reject(error instanceof Error ? error : new Error(String(error)));
      }
      this.removeWorker(slot);
      this.drain();
    });
    worker.on("exit", (code) => {
      const current = slot.current;
      slot.current = null;
      slot.busy = false;
      this.removeWorker(slot);
      if (current !== null && code !== 0) {
        current.reject(new Error(`script verify worker exited with code ${code}`));
      }
      this.drain();
    });
    this.workers.push(slot);
    return slot;
  }

  private assignJob(slot: WorkerSlot, job: PendingJob): void {
    slot.busy = true;
    slot.current = job;
    slot.worker.postMessage(job.request);
  }

  private drain(preferred?: WorkerSlot): void {
    if (this.queue.length === 0 || this.closed) return;
    const slot = preferred && !preferred.busy ? preferred : this.workers.find((candidate) => !candidate.busy);
    if (slot === undefined) return;
    const job = this.queue.shift();
    if (job === undefined) return;
    this.assignJob(slot, job);
  }

  private removeWorker(slot: WorkerSlot): void {
    const index = this.workers.indexOf(slot);
    if (index >= 0) {
      this.workers.splice(index, 1);
    }
  }
}

function envBool(value: string | undefined, fallback: boolean): boolean {
  if (value === undefined) return fallback;
  const normalized = value.toLowerCase();
  if (["1", "true", "yes", "on"].includes(normalized)) return true;
  if (["0", "false", "no", "off"].includes(normalized)) return false;
  return fallback;
}

function envInt(value: string | undefined, fallback: number, min: number): number {
  if (value === undefined) return fallback;
  const parsed = Number.parseInt(value, 10);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.max(min, parsed);
}

function chunkBlockJobs(jobs: readonly WorkerTransactionJob[], chunkCount: number): WorkerTransactionJob[][] {
  const chunks = Array.from({ length: chunkCount }, () => [] as WorkerTransactionJob[]);
  const chunkMaps = chunks.map(() => new Map<number, WorkerTransactionJob>());
  let itemIndex = 0;
  for (const job of jobs) {
    for (const task of job.tasks) {
      const chunkIndex = itemIndex % chunkCount;
      const chunkMap = chunkMaps[chunkIndex]!;
      let chunkJob = chunkMap.get(job.transactionIndex);
      if (chunkJob === undefined) {
        chunkJob = {
          transactionIndex: job.transactionIndex,
          transaction: job.transaction,
          spentPrevouts: job.spentPrevouts,
          tasks: [],
        };
        chunkMap.set(job.transactionIndex, chunkJob);
        chunks[chunkIndex]!.push(chunkJob);
      }
      chunkJob.tasks.push({
        inputIndex: task.inputIndex,
        scriptPubKey: task.scriptPubKey,
        amount: task.amount,
      });
      itemIndex += 1;
    }
  }
  return chunks.filter((chunk) => chunk.length > 0);
}

function verifySequentialBlock(jobs: readonly ScriptVerifyBlockJob[]): ScriptVerifyRunStats {
  let elapsedMs = 0;
  const details: Record<string, number> = {};
  for (const job of jobs) {
    const cacheStarted = process.hrtime.bigint();
    const cache = new TransactionSighashCache(job.transaction, job.spentPrevouts);
    addDetail(details, "script_sighash_cache_build", elapsedMsFrom(cacheStarted));
    for (const task of job.tasks) {
      const started = process.hrtime.bigint();
      try {
        verifyTransactionInput(job.transaction, task.inputIndex, {
          scriptPubKey: task.scriptPubKey,
          amount: task.amount,
          spentPrevouts: job.spentPrevouts,
          sighashCache: cache,
        });
      } finally {
        const elapsed = elapsedMsFrom(started);
        elapsedMs += elapsed;
        addDetail(details, "script_interpreter_eval", elapsed);
      }
    }
  }
  return { elapsedMs, mode: "sequential", details };
}

function mergeDetails(sources: readonly Record<string, number>[]): Record<string, number> {
  const merged: Record<string, number> = {};
  for (const source of sources) {
    for (const [key, value] of Object.entries(source)) {
      addDetail(merged, key, value);
    }
  }
  return merged;
}

function addDetail(details: Record<string, number>, stage: string, ms: number): void {
  details[stage] = (details[stage] ?? 0) + ms;
}

function elapsedMs(start: bigint): number {
  return Number(process.hrtime.bigint() - start) / 1_000_000;
}

function elapsedMsFrom(start: bigint): number {
  return elapsedMs(start);
}
