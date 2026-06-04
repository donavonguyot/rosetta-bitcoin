import { parentPort } from "node:worker_threads";

import { transactionDeserialize } from "../../messages/transaction.js";
import { TransactionSighashCache } from "./sighash.js";
import { ScriptVerifyError, verifyTransactionInput } from "./verify.js";

interface WorkerTask {
  inputIndex: number;
  scriptPubKey: Buffer | Uint8Array;
  amount: number;
}

interface WorkerPrevout {
  amount: number;
  scriptPubKey: Buffer | Uint8Array;
}

interface WorkerRequest {
  id: number;
  jobs: WorkerTransactionJob[];
}

interface WorkerTransactionJob {
  transactionIndex: number;
  transaction: Buffer | Uint8Array;
  spentPrevouts: WorkerPrevout[];
  tasks: WorkerTask[];
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

function toBuffer(value: Buffer | Uint8Array): Buffer {
  return Buffer.isBuffer(value) ? value : Buffer.from(value);
}

function fail(transactionIndex: number, inputIndex: number, error: unknown): WorkerFailure {
  if (error instanceof ScriptVerifyError || error instanceof Error) {
    return {
      transactionIndex,
      inputIndex,
      message: error.message,
      name: error.name,
    };
  }
  return {
    transactionIndex,
    inputIndex,
    message: String(error),
    name: "Error",
  };
}

function addDetail(details: Record<string, number>, stage: string, elapsedMs: number): void {
  details[stage] = (details[stage] ?? 0) + elapsedMs;
}

function elapsedMs(start: bigint): number {
  return Number(process.hrtime.bigint() - start) / 1_000_000;
}

if (parentPort === null) {
  throw new Error("script verify worker requires parentPort");
}

parentPort.on("message", (message: WorkerRequest) => {
  const started = process.hrtime.bigint();
  const failures: WorkerFailure[] = [];
  const details: Record<string, number> = {};
  try {
    for (const job of message.jobs) {
      const parseStarted = process.hrtime.bigint();
      const [transaction] = transactionDeserialize(toBuffer(job.transaction), 0);
      addDetail(details, "script_worker_serialize", elapsedMs(parseStarted));
      const spentPrevouts = job.spentPrevouts.map(
        (prevout) => [prevout.amount, toBuffer(prevout.scriptPubKey)] as const,
      );
      const cacheStarted = process.hrtime.bigint();
      const cache = new TransactionSighashCache(transaction, spentPrevouts);
      addDetail(details, "script_sighash_cache_build", elapsedMs(cacheStarted));
      for (const task of job.tasks) {
        const verifyStarted = process.hrtime.bigint();
        try {
          verifyTransactionInput(transaction, task.inputIndex, {
            scriptPubKey: toBuffer(task.scriptPubKey),
            amount: task.amount,
            spentPrevouts,
            sighashCache: cache,
          });
        } catch (error) {
          failures.push(fail(job.transactionIndex, task.inputIndex, error));
        } finally {
          addDetail(details, "script_interpreter_eval", elapsedMs(verifyStarted));
        }
      }
    }
  } catch (error) {
    failures.push(fail(Number.MAX_SAFE_INTEGER, Number.MAX_SAFE_INTEGER, error));
  }
  const response: WorkerResponse = {
    id: message.id,
    elapsedMs: elapsedMs(started),
    details,
    failures,
  };
  parentPort!.postMessage(response);
});
