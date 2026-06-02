import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { DatabaseSync } from "node:sqlite";

export interface BatchStart {
  lineNo: number;
  batchNum: number;
  startValidated: number;
  timestamp: string;
}

export interface BatchEnd {
  lineNo: number;
  batchNum: number;
  endValidated: number;
  timestamp: string;
  validatedDelta: number;
}

export interface SyncDbMetrics {
  validatedHeight: number;
  headerHeight: number;
  blockCount: number;
  syncStatus: string;
}

export interface SyncProgressReport {
  validated_height: number;
  header_height: number;
  block_count: number;
  sync_status: string;
  pct_to_target: number;
  target_height: number;
  last_batch_validated_delta: number | null;
  last_batch_timestamp: string | null;
}

const BATCH_START_RE =
  /^=== batch (\d+) start_validated=(\d+) (\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z) ===\s*$/;
const BATCH_END_RE =
  /^=== batch (\d+) end_validated=(\d+) downloaded_delta=(\d+) exit=(\d+) \((\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)\) validated_delta=(\d+) ===\s*$/;

export function parseBatchLogLines(lines: string[]): {
  lastStart: BatchStart | null;
  lastEnd: BatchEnd | null;
} {
  let lastStart: BatchStart | null = null;
  let lastEnd: BatchEnd | null = null;

  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i]!.replace(/\n$/, "");
    const startMatch = BATCH_START_RE.exec(line);
    if (startMatch) {
      lastStart = {
        lineNo: i + 1,
        batchNum: Number.parseInt(startMatch[1]!, 10),
        startValidated: Number.parseInt(startMatch[2]!, 10),
        timestamp: startMatch[3]!,
      };
      continue;
    }
    const endMatch = BATCH_END_RE.exec(line);
    if (endMatch) {
      lastEnd = {
        lineNo: i + 1,
        batchNum: Number.parseInt(endMatch[1]!, 10),
        endValidated: Number.parseInt(endMatch[2]!, 10),
        timestamp: endMatch[5]!,
        validatedDelta: Number.parseInt(endMatch[6]!, 10),
      };
    }
  }

  return { lastStart, lastEnd };
}

export function validatedHeightFromLog(
  lastStart: BatchStart | null,
  lastEnd: BatchEnd | null,
): number | null {
  if (lastEnd === null && lastStart === null) {
    return null;
  }
  if (lastEnd === null) {
    return lastStart!.startValidated;
  }
  if (lastStart === null) {
    return lastEnd.endValidated;
  }
  if (lastStart.lineNo > lastEnd.lineNo) {
    return lastStart.startValidated;
  }
  return lastEnd.endValidated;
}

export function pctToTarget(height: number, target: number): number {
  if (target <= 0) {
    return 0;
  }
  return Math.min(100, Math.round((100 * height) / target * 100) / 100);
}

export function openReadonlyDb(dbPath: string): DatabaseSync {
  const resolved = resolve(dbPath);
  if (!existsSync(resolved)) {
    throw new Error(`Database not found: ${resolved}`);
  }
  return new DatabaseSync(resolved, { readOnly: true });
}

export function readValidatedHeightDb(dbPath: string, chain: string): number {
  if (!existsSync(resolve(dbPath))) {
    return 0;
  }
  const db = openReadonlyDb(dbPath);
  try {
    const row = db
      .prepare(`SELECT height FROM validated_tip WHERE chain = ? LIMIT 1`)
      .get(chain) as { height: number } | undefined;
    return row?.height ?? 0;
  } finally {
    db.close();
  }
}

export function readSyncDbMetrics(dbPath: string, chain: string): SyncDbMetrics {
  if (!existsSync(resolve(dbPath))) {
    return {
      validatedHeight: 0,
      headerHeight: 0,
      blockCount: 0,
      syncStatus: "unknown",
    };
  }
  const db = openReadonlyDb(dbPath);
  try {
    const validatedRow = db
      .prepare(`SELECT height FROM validated_tip WHERE chain = ? LIMIT 1`)
      .get(chain) as { height: number } | undefined;
    const headerRow = db
      .prepare(`SELECT MAX(height) AS h FROM headers WHERE chain = ?`)
      .get(chain) as { h: number | null } | undefined;
    const blockRow = db
      .prepare(`SELECT COUNT(*) AS count FROM blocks WHERE chain = ?`)
      .get(chain) as { count: number };
    const syncRow = db
      .prepare(`SELECT sync_status FROM sync_state WHERE chain = ? LIMIT 1`)
      .get(chain) as { sync_status: string } | undefined;
    return {
      validatedHeight: validatedRow?.height ?? 0,
      headerHeight: headerRow?.h ?? 0,
      blockCount: blockRow.count,
      syncStatus: syncRow?.sync_status ?? "unknown",
    };
  } finally {
    db.close();
  }
}

export function buildReport(options: {
  logPath: string;
  target: number;
  dbPath: string | null;
  chain: string;
}): SyncProgressReport {
  let lastStart: BatchStart | null = null;
  let lastEnd: BatchEnd | null = null;

  if (existsSync(options.logPath)) {
    const text = readFileSync(options.logPath, { encoding: "utf-8" });
    const lines = text.split(/\r?\n/);
    ({ lastStart, lastEnd } = parseBatchLogLines(lines));
  } else if (options.dbPath === null) {
    throw new Error(`Log not found: ${options.logPath}`);
  }

  let validatedHeight: number;
  let headerHeight = 0;
  let blockCount = 0;
  let syncStatus = "unknown";

  if (options.dbPath !== null) {
    const metrics = readSyncDbMetrics(options.dbPath, options.chain);
    validatedHeight = metrics.validatedHeight;
    headerHeight = metrics.headerHeight;
    blockCount = metrics.blockCount;
    syncStatus = metrics.syncStatus;
  } else {
    const fromLog = validatedHeightFromLog(lastStart, lastEnd);
    if (fromLog === null) {
      throw new Error(`No batch start/end markers found in ${options.logPath}`);
    }
    validatedHeight = fromLog;
  }

  return {
    validated_height: validatedHeight,
    header_height: headerHeight,
    block_count: blockCount,
    sync_status: syncStatus,
    pct_to_target: pctToTarget(validatedHeight, options.target),
    target_height: options.target,
    last_batch_validated_delta: lastEnd?.validatedDelta ?? null,
    last_batch_timestamp: lastEnd?.timestamp ?? null,
  };
}

export function formatTextReport(report: SyncProgressReport): string[] {
  const lines = [
    `validated_height=${report.validated_height}`,
    `header_height=${report.header_height}`,
    `block_count=${report.block_count}`,
    `sync_status=${report.sync_status}`,
    `pct_to_target=${report.pct_to_target}%`,
    `target_height=${report.target_height}`,
    `last_batch_validated_delta=${report.last_batch_validated_delta ?? ""}`,
    `last_batch_timestamp=${report.last_batch_timestamp ?? ""}`,
  ];
  return lines;
}

function printHelp(): void {
  console.log(`Usage: sync-progress-report [options]

Report sync batch progress from log (optional read-only DB).

Options:
  --log <path>       Path to sync_batch_run.log (default: ./sync_batch_run.log)
  --target <n>       Target height for % progress (default: 10000)
  --chain <name>     Chain when reading --db (default: testnet4)
  --db [<path>]      Read heights read-only from SQLite (default: ./data-ts/tsbitnode.db)
  --json             Emit JSON instead of text lines
  -h, --help         Show help`);
}

export function parseProgressReportArgv(argv: string[]): {
  logPath: string;
  target: number;
  chain: string;
  dbPath: string | null;
  json: boolean;
  help: boolean;
} {
  let logPath = "sync_batch_run.log";
  let target = 10_000;
  let chain = "testnet4";
  let dbPath: string | null = null;
  let dbFlagSeen = false;
  let json = false;
  let help = false;

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i]!;
    if (arg === "--help" || arg === "-h") {
      help = true;
      continue;
    }
    if (arg === "--json") {
      json = true;
      continue;
    }
    if (arg === "--log") {
      logPath = argv[++i] ?? "";
      continue;
    }
    if (arg === "--target") {
      target = Number.parseInt(argv[++i] ?? "", 10);
      continue;
    }
    if (arg === "--chain") {
      chain = argv[++i] ?? chain;
      continue;
    }
    if (arg === "--db") {
      dbFlagSeen = true;
      const next = argv[i + 1];
      if (next !== undefined && !next.startsWith("-")) {
        dbPath = next;
        i += 1;
      } else {
        dbPath = "./data-ts/tsbitnode.db";
      }
      continue;
    }
    if (arg.startsWith("--db=")) {
      dbFlagSeen = true;
      dbPath = arg.slice("--db=".length);
      continue;
    }
    throw new Error(`Unknown argument: ${arg}`);
  }

  if (!dbFlagSeen) {
    dbPath = null;
  }

  return { logPath, target, chain, dbPath, json, help };
}

async function main(): Promise<number> {
  try {
    const args = parseProgressReportArgv(process.argv.slice(2));
    if (args.help) {
      printHelp();
      return 0;
    }

    const report = buildReport({
      logPath: args.logPath,
      target: args.target,
      dbPath: args.dbPath,
      chain: args.chain,
    });

    if (args.json) {
      console.log(JSON.stringify(report, null, 2));
    } else {
      for (const line of formatTextReport(report)) {
        console.log(line);
      }
    }
    return 0;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    console.error(`error: ${message}`);
    return 1;
  }
}

const entryPath = process.argv[1] ?? "";
if (entryPath.endsWith("syncProgressReport.js") || entryPath.endsWith("syncProgressReport.ts")) {
  main().then((code) => {
    process.exitCode = code;
  });
}
