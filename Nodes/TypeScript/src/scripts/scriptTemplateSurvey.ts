#!/usr/bin/env node
/**
 * Offline survey: validated tip, rejection events (script stubs), stored-block output tagging.
 *
 * Opens tsbitnode.db in **read-only** mode. Does not fetch from the network.
 *
 * Example:
 *   npm run build && npm run survey:scripts -- --db ./data-ts/tsbitnode.db --scan-blocks 20
 */

import { existsSync } from "node:fs";
import { resolve } from "node:path";
import type { DatabaseSync } from "node:sqlite";

import { getChain } from "../chain/params.js";
import { blockDeserialize } from "../consensus/block.js";
import {
  isP2pk,
  isP2pkh,
  isP2sh,
  isP2tr,
  isP2wpkh,
  isP2wsh,
  witnessProgramVersion,
} from "../consensus/script/interpreter.js";
import { Settings } from "../config/settings.js";
import { BlockStore } from "../storage/blocks.js";
import { openReadonlyDb } from "./syncProgressReport.js";

export function classifyScriptPubkey(spk: Buffer): string {
  if (isP2tr(spk)) return "p2tr";
  if (isP2wpkh(spk)) return "p2wpkh";
  if (isP2wsh(spk)) return "p2wsh";
  const wpv = witnessProgramVersion(spk);
  if (wpv !== null && wpv > 1) return `witness_v${wpv}`;
  if (isP2sh(spk)) return "p2sh";
  if (isP2pkh(spk)) return "p2pkh";
  if (isP2pk(spk)) return "p2pk";
  if (spk.length === 0) return "empty";
  if (spk[0] === 0x6a) return "op_return";
  return `other(0x${spk[0]!.toString(16).padStart(2, "0")},len=${spk.length})`;
}

function summarizeSupportedTemplates(): readonly string[] {
  return [
    "P2PK (<pubkey> checksig)",
    "P2PKH",
    "P2SH (nested evaluation; inner script uses interpreter opcode subset)",
    "Witness v0 P2WPKH / P2WSH (incl. multisig redeem scripts via CHECKMULTISIG)",
    "Taproot v1 P2TR key-path and script-path (BIP341/342 subset)",
    "Witness v2+ programs: explicitly rejected at spend time (unsupported witness program version N)",
  ];
}

function fileNameForIndex(fileNumber: number): string {
  return `blk${String(fileNumber).padStart(5, "0")}.dat`;
}

export interface ScriptSurveyOptions {
  dbPath: string;
  chain: string;
  scanBlocks: number;
  blocksDir: string;
}

export function runScriptTemplateSurvey(options: ScriptSurveyOptions): number {
  const dbPath = resolve(options.dbPath);
  if (!existsSync(dbPath)) {
    console.error(`error: database not found: ${dbPath}`);
    return 2;
  }

  const chain = getChain(options.chain);
  const db = openReadonlyDb(dbPath);

  try {
    const validatedRow = db
      .prepare(`SELECT height, block_hash FROM validated_tip WHERE chain = ?`)
      .get(options.chain) as { height: number; block_hash: string } | undefined;
    if (validatedRow === undefined) {
      console.error(`error: no validated_tip row for chain=${JSON.stringify(options.chain)}`);
      return 2;
    }

    const syncRow = db
      .prepare(`SELECT best_height, header_count, sync_status FROM sync_state WHERE chain = ?`)
      .get(options.chain) as
      | { best_height: number; header_count: number; sync_status: string }
      | undefined;

    const maxRow = db
      .prepare(`SELECT MAX(height) AS mh FROM blocks WHERE chain = ?`)
      .get(options.chain) as { mh: number | null } | undefined;
    const maxBlock = maxRow?.mh ?? null;

    printSummary(validatedRow, syncRow, maxBlock);
    printEventCounts(db);

    if (options.scanBlocks > 0 && maxBlock !== null) {
      scanStoredBlocks(db, options, chain.magic, validatedRow.height, maxBlock);
    }
  } finally {
    db.close();
  }

  return 0;
}

function printSummary(
  validatedRow: { height: number; block_hash: string },
  syncRow:
    | { best_height: number; header_count: number; sync_status: string }
    | undefined,
  maxBlock: number | null,
): void {
  console.log("=== validated_tip ===");
  console.log(`  validated_height: ${validatedRow.height}`);
  console.log(`  validated_hash:   ${validatedRow.block_hash}`);
  if (syncRow) {
    console.log("=== sync_state ===");
    console.log(`  best_height:   ${syncRow.best_height}`);
    console.log(`  header_count:  ${syncRow.header_count}`);
    console.log(`  sync_status:   ${syncRow.sync_status}`);
  }
  console.log("=== blocks table ===");
  console.log(`  max_stored_height: ${maxBlock}`);
  const gap =
    maxBlock !== null && validatedRow.height !== null
      ? maxBlock - validatedRow.height
      : "";
  console.log(`  stored_minus_validated (download ahead): ${gap}`);

  console.log("\n=== supported spend templates (see src/consensus/script/verify.ts) ===");
  for (const item of summarizeSupportedTemplates()) {
    console.log(`  • ${item}`);
  }
  console.log("\n=== interpreter opcode subset ===");
  console.log(
    "  evaluateScript knows pushes, DUP, HASH160, EQUAL/EQUALVERIFY, VERIFY, " +
      "CHECKSIG/CHECKSIGVERIFY, CHECKMULTISIG/CHECKMULTISIGVERIFY, " +
      "CHECKLOCKTIMEVERIFY/CHECKSEQUENCEVERIFY (legacy redeem scripts). " +
      "Tapscript timelock opcodes are not implemented.",
  );
  console.log("\n=== consensus gaps (still likely on mainnet-style traffic) ===");
  console.log(
    "  • Bare/non-template outputs spent on spend path (bare multisig, odd P2PK variants, …).\n" +
      "    Unspendable outputs (common OP_RETURN commitments) skip verification.\n" +
      "  • Witness v2+ outputs are recognized and rejected with " +
      "'unsupported witness program version N' (see verify.ts).",
  );
}

function scanStoredBlocks(
  db: DatabaseSync,
  options: ScriptSurveyOptions,
  magic: Buffer,
  validatedHeight: number,
  maxBlock: number,
): void {
  const v = validatedHeight;
  const limitH = Math.min(v + options.scanBlocks, maxBlock);
  const rows = db
    .prepare(
      `SELECT height, file_number, file_offset, block_size
       FROM blocks
       WHERE chain = ? AND height > ? AND height <= ?
       ORDER BY height`,
    )
    .all(options.chain, v, limitH) as Array<{
    height: number;
    file_number: number;
    file_offset: number;
    block_size: number;
  }>;

  console.log(
    `\n=== scan stored blocks heights (${v}, ${v + options.scanBlocks}] ` +
      `available up to ${limitH} ===`,
  );
  if (rows.length === 0) {
    console.log(
      "  (none — validated tip caught up with stored blocks or nothing downloaded past tip)",
    );
    return;
  }

  const store = new BlockStore(options.blocksDir, magic);
  const outCtr = new Map<string, number>();
  for (const row of rows) {
    const payload = store.read(
      fileNameForIndex(row.file_number),
      row.file_offset,
      row.block_size,
    );
    const block = blockDeserialize(payload);
    for (const tx of block.transactions) {
      for (const output of tx.outputs) {
        const label = classifyScriptPubkey(output.scriptPubKey);
        outCtr.set(label, (outCtr.get(label) ?? 0) + 1);
      }
    }
  }

  console.log(`  scanned ${rows.length} block(s)`);
  const sorted = [...outCtr.entries()].sort((a, b) => b[1] - a[1]);
  for (const [label, count] of sorted) {
    console.log(`    ${label}: ${count}`);
  }
}

function countRejectedBlocks(db: DatabaseSync): { total: number; unsupportedTemplate: number } {
  const totalRow = db
    .prepare(`SELECT COUNT(*) AS c FROM events WHERE message = 'Rejected invalid block'`)
    .get() as { c: number };
  const unsupportedRow = db
    .prepare(
      `SELECT COUNT(*) AS c FROM events WHERE message = 'Rejected invalid block' ` +
        `AND details_json LIKE '%unsupported scriptPubKey template%'`,
    )
    .get() as { c: number };
  return { total: totalRow.c, unsupportedTemplate: unsupportedRow.c };
}

function printEventCounts(db: DatabaseSync): void {
  const { total, unsupportedTemplate } = countRejectedBlocks(db);
  console.log("\n=== events (all chains in this DB file) ===");
  console.log(`  Rejected invalid block (total rows):           ${total}`);
  console.log(`  …details_json mentions unsupported script…:      ${unsupportedTemplate}`);
}

function printHelp(): void {
  console.log(`Usage: script-template-survey [options]

Offline script template survey (read-only SQLite).

Options:
  --db <path>           Path to tsbitnode.db (default: ./data-ts/tsbitnode.db)
  --chain <name>        Chain name (default: testnet4)
  --scan-blocks <n>     Classify output scriptPubKeys for stored blocks with height in
                        (validated_height, validated_height+N]; 0 skips (default: 0)
  --blocks-dir <path>   Block flat-file directory (default: ./data-ts/blocks)
  -h, --help            Show help`);
}

export function parseScriptSurveyArgv(argv: string[]): ScriptSurveyOptions & { help: boolean } {
  const settings = Settings.fromEnv();
  let dbPath = settings.resolvedDbPath();
  let chain = settings.chain;
  let scanBlocks = 0;
  let blocksDir = settings.blocksDir();
  let help = false;

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i]!;
    if (arg === "--help" || arg === "-h") {
      help = true;
      continue;
    }
    if (arg === "--db") {
      dbPath = argv[++i] ?? dbPath;
      continue;
    }
    if (arg.startsWith("--db=")) {
      dbPath = arg.slice("--db=".length);
      continue;
    }
    if (arg === "--chain") {
      chain = argv[++i] ?? chain;
      continue;
    }
    if (arg.startsWith("--chain=")) {
      chain = arg.slice("--chain=".length);
      continue;
    }
    if (arg === "--scan-blocks") {
      scanBlocks = Number.parseInt(argv[++i] ?? "0", 10);
      continue;
    }
    if (arg.startsWith("--scan-blocks=")) {
      scanBlocks = Number.parseInt(arg.slice("--scan-blocks=".length), 10);
      continue;
    }
    if (arg === "--blocks-dir") {
      blocksDir = argv[++i] ?? blocksDir;
      continue;
    }
    if (arg.startsWith("--blocks-dir=")) {
      blocksDir = arg.slice("--blocks-dir=".length);
      continue;
    }
    throw new Error(`Unknown argument: ${arg}`);
  }

  return { dbPath, chain, scanBlocks, blocksDir, help };
}

async function main(): Promise<number> {
  try {
    const args = parseScriptSurveyArgv(process.argv.slice(2));
    if (args.help) {
      printHelp();
      return 0;
    }

    const dbPath = resolve(args.dbPath);
    if (!existsSync(dbPath)) {
      console.error(`error: database not found: ${dbPath}`);
      return 2;
    }

    return runScriptTemplateSurvey({
      dbPath: args.dbPath,
      chain: args.chain,
      scanBlocks: args.scanBlocks,
      blocksDir: args.blocksDir,
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    console.error(`error: ${message}`);
    return 1;
  }
}

const entryPath = process.argv[1] ?? "";
if (entryPath.endsWith("scriptTemplateSurvey.js") || entryPath.endsWith("scriptTemplateSurvey.ts")) {
  main().then((code) => {
    process.exitCode = code;
  });
}
