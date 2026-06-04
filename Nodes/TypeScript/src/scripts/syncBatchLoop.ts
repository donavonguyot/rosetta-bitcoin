import { spawn } from "node:child_process";
import {
  closeSync,
  existsSync,
  mkdirSync,
  openSync,
  writeFileSync,
  writeSync,
} from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createInterface } from "node:readline";

import { getChain } from "../chain/params.js";
import { ChainstateSession } from "../chainstate/chainstateSession.js";
import {
  SYNC_LOCK_PARENT_ENV,
  SyncLockHeldError,
  acquireSyncLock,
  releaseSyncLock,
} from "../storage/syncLock.js";

const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");

function utcTimestamp(): string {
  return new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
}

function repoRoot(): string {
  return REPO_ROOT;
}

function defaultSyncBin(): string {
  return join(repoRoot(), "dist/cli/syncRunner.js");
}

export interface BatchLoopOptions {
  datadir: string;
  target: number;
  blocksMax: number;
  logPath: string;
  maxBatches: number;
  chain: string;
  syncBin: string;
  peers: string;
  noHeaderRefresh: boolean;
  syncExtra: string[];
}

export function parseBatchLoopArgv(argv: string[]): BatchLoopOptions & { help: boolean } {
  let datadir = "";
  let target = 0;
  let blocksMax = 200;
  let logPath = join(repoRoot(), "sync_batch_run.log");
  let maxBatches = 1000;
  let chain = "testnet4";
  let syncBin = defaultSyncBin();
  let peers = "";
  let noHeaderRefresh = false;
  let help = false;
  const syncExtra: string[] = [];
  let passthrough = false;

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i]!;
    if (passthrough) {
      syncExtra.push(arg);
      continue;
    }
    if (arg === "--") {
      passthrough = true;
      continue;
    }
    if (arg === "--help" || arg === "-h") {
      help = true;
      continue;
    }
    if (arg === "--datadir") {
      datadir = argv[++i] ?? "";
      continue;
    }
    if (arg === "--target") {
      target = Number.parseInt(argv[++i] ?? "", 10);
      continue;
    }
    if (arg === "--blocks-max") {
      blocksMax = Number.parseInt(argv[++i] ?? "", 10);
      continue;
    }
    if (arg === "--log") {
      logPath = argv[++i] ?? logPath;
      continue;
    }
    if (arg === "--max-batches") {
      maxBatches = Number.parseInt(argv[++i] ?? "", 10);
      continue;
    }
    if (arg === "--chain") {
      chain = argv[++i] ?? chain;
      continue;
    }
    if (arg === "--sync") {
      syncBin = argv[++i] ?? syncBin;
      continue;
    }
    if (arg === "--peers") {
      peers = argv[++i] ?? "";
      continue;
    }
    if (arg === "--no-header-refresh") {
      noHeaderRefresh = true;
      continue;
    }
    throw new Error(`Unknown argument: ${arg}`);
  }

  return {
    datadir,
    target,
    blocksMax,
    logPath,
    maxBatches,
    chain,
    syncBin,
    peers,
    noHeaderRefresh,
    syncExtra,
    help,
  };
}

function printHelp(): void {
  console.log(`Usage: sync-batch-loop --datadir <path> --target <height> [options] [-- sync flags]

Run tsbitnode-sync in sequential batches (exclusive <datadir>/.tsbitnode_sync.lock;
polls validated_height from native chainstate).

Options:
  --datadir <path>       Native datadir path
  --target <n>           Passed as --blocks-target
  --blocks-max <n>       Blocks per batch (default: 200)
  --log <path>           Append log target (default: <repo>/sync_batch_run.log)
  --max-batches <n>      Stop after N batches (default: 1000)
  --chain <name>         Chain for RO height queries (default: testnet4)
  --sync <path>          tsbitnode-sync entry (default: dist/cli/syncRunner.js)
  --peers <host:port>    Optional comma-separated peers
  --no-header-refresh    Pass --no-header-refresh to tsbitnode-sync
  -h, --help             Show help

Extras after -- are forwarded to tsbitnode-sync (example: -- --connect-only).`);
}

async function validatedHeight(datadir: string, chainName: string): Promise<number> {
  const chain = getChain(chainName);
  const session = await ChainstateSession.openNative(resolve(datadir), chain, { acquireLock: false });
  try {
    return Math.max(0, await session.store.getValidatedHeight(chain.name));
  } finally {
    await session.close();
  }
}

function appendLine(logPath: string, line: string): void {
  mkdirSync(dirname(logPath), { recursive: true });
  writeFileSync(logPath, `\n${line}\n`, { flag: "a" });
}

async function runSyncBatch(
  options: BatchLoopOptions,
  batchNum: number,
  before: number,
  logPath: string,
): Promise<{ exitCode: number; after: number }> {
  const tsStart = utcTimestamp();
  const startLine = `=== batch ${batchNum} start_validated=${before} ${tsStart} ===`;
  console.log("");
  console.log(startLine);
  appendLine(logPath, startLine);

  const cmd = [
    options.syncBin,
    "--datadir",
    resolve(options.datadir),
    "--blocks-target",
    String(options.target),
    "--blocks-max",
    String(options.blocksMax),
  ];
  if (options.noHeaderRefresh) {
    cmd.push("--no-header-refresh");
  }
  if (options.peers.trim()) {
    cmd.push("--peers", options.peers.trim());
  }
  cmd.push(...options.syncExtra);

  const syncEnv = {
    ...process.env,
    [SYNC_LOCK_PARENT_ENV]: String(process.pid),
    MAX_OUTBOUND_PEERS: process.env.MAX_OUTBOUND_PEERS ?? "1",
    PARALLEL_BLOCK_DOWNLOADS: process.env.PARALLEL_BLOCK_DOWNLOADS ?? "0",
    SKIP_GETADDR: process.env.SKIP_GETADDR ?? "1",
  };

  const exitCode = await new Promise<number>((resolveExit, reject) => {
    const child = spawn(process.execPath, cmd, {
      cwd: repoRoot(),
      env: syncEnv,
      stdio: ["ignore", "pipe", "pipe"],
    });

    mkdirSync(dirname(logPath), { recursive: true });
    const logStream = openSync(logPath, "a");
    const stdout = child.stdout;
    const stderr = child.stderr;
    if (!stdout || !stderr) {
      reject(new Error("failed to capture sync stdout/stderr"));
      return;
    }

    const rlOut = createInterface({ input: stdout });
    rlOut.on("line", (line) => {
      const chunk = `${line}\n`;
      process.stdout.write(chunk);
      writeSync(logStream, chunk);
    });

    const rlErr = createInterface({ input: stderr });
    rlErr.on("line", (line) => {
      const chunk = `${line}\n`;
      process.stdout.write(chunk);
      writeSync(logStream, chunk);
    });

    child.on("error", reject);
    child.on("close", (code) => {
      closeSync(logStream);
      resolveExit(code ?? 1);
    });
  });

  const after = await validatedHeight(options.datadir, options.chain);
  const validatedDelta = after - before;
  const tsEnd = utcTimestamp();
  const endLine =
    `=== batch ${batchNum} end_validated=${after} downloaded_delta=${validatedDelta} ` +
    `exit=${exitCode} (${tsEnd}) validated_delta=${validatedDelta} ===`;
  console.log(endLine);
  appendLine(logPath, endLine);

  return { exitCode, after };
}

export async function runBatchLoop(options: BatchLoopOptions): Promise<number> {
  let syncLock: ReturnType<typeof acquireSyncLock> | null = null;

  try {
    syncLock = acquireSyncLock(options.datadir, { holder: "syncBatchLoop" });
  } catch (error) {
    if (error instanceof SyncLockHeldError) {
      console.error(`error: ${error.message}`);
      return 2;
    }
    throw error;
  }

  try {
    if (!existsSync(options.syncBin)) {
      console.error(`error: tsbitnode-sync missing: ${options.syncBin}`);
      return 1;
    }

    for (let batchNum = 1; batchNum <= options.maxBatches; batchNum += 1) {
      const before = await validatedHeight(options.datadir, options.chain);
      if (before >= options.target) {
        console.log(`done: validated_height=${before} (>= target ${options.target})`);
        return 0;
      }

      await runSyncBatch(options, batchNum, before, options.logPath);
    }

    const after = await validatedHeight(options.datadir, options.chain);
    console.error(
      `error: max batches reached (${options.maxBatches}); validated_height=${after} target=${options.target}`,
    );
    return 4;
  } finally {
    if (syncLock !== null) {
      releaseSyncLock(syncLock);
    }
  }
}

async function main(): Promise<number> {
  const parsed = parseBatchLoopArgv(process.argv.slice(2));
  if (parsed.help) {
    printHelp();
    return 0;
  }
  if (!parsed.datadir) {
    console.error("error: --datadir is required");
    return 1;
  }
  if (!Number.isFinite(parsed.target) || parsed.target <= 0) {
    console.error("error: --target must be a positive integer");
    return 1;
  }

  const { help: _help, ...options } = parsed;
  return runBatchLoop(options);
}

const entryPath = process.argv[1] ?? "";
if (entryPath.endsWith("syncBatchLoop.js") || entryPath.endsWith("syncBatchLoop.ts")) {
  main().then((code) => {
    process.exitCode = code;
  });
}
