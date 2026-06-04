#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import { transactionDeserialize, type Transaction } from "../messages/transaction.js";
import { ScriptVerifyError, verifyTransactionInput } from "../consensus/script/verify.js";
import { VERSION } from "../version.js";
import { parseCli } from "./args.js";

type JsonObject = Record<string, unknown>;

interface ManifestEntry extends JsonObject {
  fixture_id: string;
  height: number;
  txid: string;
  input_index: number;
  expected_result?: string;
  missing_rule?: string;
  required_rules?: string[];
  prev_amount_sats?: number;
  spent_script_pubkey?: string;
  files?: Record<string, string[]>;
}

interface ScriptCorpusCase {
  fixtureId: string;
  height: number;
  txid: string;
  inputIndex: number;
  expectedResult: string;
  missingRule: string;
  requiredRules: string[];
  transaction: Transaction;
  scriptPubKey: Buffer;
  amount: number;
  spentPrevouts: readonly (readonly [number, Buffer])[];
}

function currentFileDir(): string {
  return dirname(fileURLToPath(import.meta.url));
}

export function repoRoot(): string {
  for (let dir = currentFileDir(); dir !== dirname(dir); dir = dirname(dir)) {
    if (existsSync(join(dir, "NodeCore")) && existsSync(join(dir, "Nodes", "TypeScript"))) {
      return dir;
    }
  }
  for (let dir = process.cwd(); dir !== dirname(dir); dir = dirname(dir)) {
    if (existsSync(join(dir, "NodeCore")) && existsSync(join(dir, "Nodes", "TypeScript"))) {
      return dir;
    }
  }
  throw new Error("could not locate repository root");
}

function todayStamp(): string {
  return new Date().toISOString().slice(0, 10);
}

export function defaultManifestPath(): string {
  return join(repoRoot(), "NodeCore", "conformance", "fixtures", "scripts", "manifest.json");
}

export function defaultResultPath(): string {
  return join(
    repoRoot(),
    "NodeCore",
    "conformance",
    "results",
    `typescript_script_corpus_${todayStamp()}.json`,
  );
}

function firstFixturePath(manifestPath: string, entry: ManifestEntry, category: string): string | null {
  const values = entry.files?.[category] ?? [];
  if (values.length === 0) {
    return null;
  }
  return join(dirname(manifestPath), values[0]!);
}

function readHex(path: string): Buffer {
  return Buffer.from(readFileSync(path, "ascii").trim(), "hex");
}

function asNumber(value: unknown): number | null {
  if (typeof value === "number") return value;
  if (typeof value === "string" && value.trim() !== "") return Number.parseInt(value, 10);
  return null;
}

function asHex(value: unknown): string | null {
  return typeof value === "string" && value.trim() !== "" ? value.trim() : null;
}

function prevoutTuple(prevout: JsonObject): readonly [number, Buffer] {
  const amount = asNumber(prevout.amount ?? prevout.amount_sats ?? prevout.value);
  const scriptPubKey = asHex(prevout.spk ?? prevout.script_pubkey ?? prevout.scriptPubKey);
  if (amount === null || scriptPubKey === null) {
    throw new Error(`prevout is missing amount or scriptPubKey: ${JSON.stringify(prevout)}`);
  }
  return [amount, Buffer.from(scriptPubKey, "hex")] as const;
}

function spentPrevouts(manifestPath: string, entry: ManifestEntry): readonly (readonly [number, Buffer])[] {
  const prevoutsPath = firstFixturePath(manifestPath, entry, "prevouts");
  if (prevoutsPath !== null) {
    const parsed = JSON.parse(readFileSync(prevoutsPath, "utf8")) as unknown;
    if (!Array.isArray(parsed)) {
      throw new Error(`prevouts must be a list for ${entry.fixture_id}`);
    }
    return parsed.map((prevout) => prevoutTuple(prevout as JsonObject));
  }

  const prevSpkPath = firstFixturePath(manifestPath, entry, "prev_spk");
  const amount = asNumber(entry.prev_amount_sats);
  const scriptPubKey = prevSpkPath !== null ? readFileSync(prevSpkPath, "ascii").trim() : asHex(entry.spent_script_pubkey);
  if (amount === null || scriptPubKey === null || scriptPubKey === "") {
    throw new Error(`fixture has no usable prevout data: ${entry.fixture_id}`);
  }
  return [[amount, Buffer.from(scriptPubKey, "hex")] as const];
}

function targetPrevout(
  manifestPath: string,
  entry: ManifestEntry,
  fallback: readonly [number, Buffer] | null,
): readonly [number, Buffer] {
  const prevSpkPath = firstFixturePath(manifestPath, entry, "prev_spk");
  const amount = asNumber(entry.prev_amount_sats);
  const scriptPubKey = prevSpkPath !== null ? readFileSync(prevSpkPath, "ascii").trim() : asHex(entry.spent_script_pubkey);
  if (amount !== null && scriptPubKey !== null && scriptPubKey !== "") {
    return [amount, Buffer.from(scriptPubKey, "hex")] as const;
  }
  if (fallback !== null) {
    return fallback;
  }
  throw new Error(`fixture has no usable target prevout data: ${entry.fixture_id}`);
}

function alignSpentPrevouts(
  manifestPath: string,
  entry: ManifestEntry,
  tx: Transaction,
  prevouts: readonly (readonly [number, Buffer])[],
): readonly (readonly [number, Buffer])[] {
  if (prevouts.length === tx.inputs.length) {
    return prevouts;
  }
  const aligned = [...prevouts];
  const inputIndex = Number(entry.input_index);
  const target = targetPrevout(manifestPath, entry, prevouts[0] ?? null);
  while (aligned.length < tx.inputs.length) {
    aligned.push([0, Buffer.alloc(0)] as const);
  }
  aligned[inputIndex] = target;
  return aligned;
}

export function loadCase(manifestPath: string, entry: ManifestEntry): ScriptCorpusCase {
  const txPath = firstFixturePath(manifestPath, entry, "tx");
  if (txPath === null) {
    throw new Error(`fixture has no transaction file: ${entry.fixture_id}`);
  }
  const payload = readHex(txPath);
  const [transaction, consumed] = transactionDeserialize(payload);
  if (consumed !== payload.length) {
    throw new Error(`transaction parser consumed ${consumed} of ${payload.length} bytes for ${entry.fixture_id}`);
  }

  const inputIndex = Number(entry.input_index);
  const alignedPrevouts = alignSpentPrevouts(manifestPath, entry, transaction, spentPrevouts(manifestPath, entry));
  if (inputIndex >= alignedPrevouts.length) {
    throw new Error(`fixture input_index ${inputIndex} has no matching prevout: ${entry.fixture_id}`);
  }
  const [amount, scriptPubKey] = alignedPrevouts[inputIndex]!;

  return {
    fixtureId: String(entry.fixture_id),
    height: Number(entry.height),
    txid: String(entry.txid),
    inputIndex,
    expectedResult: String(entry.expected_result ?? "valid"),
    missingRule: String(entry.missing_rule ?? ""),
    requiredRules: (entry.required_rules ?? []).map(String),
    transaction,
    scriptPubKey,
    amount,
    spentPrevouts: alignedPrevouts,
  };
}

export function loadCases(manifestPath: string, fixtureId = ""): ScriptCorpusCase[] {
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8")) as { fixtures?: ManifestEntry[] };
  return (manifest.fixtures ?? [])
    .filter((entry) => fixtureId === "" || entry.fixture_id === fixtureId)
    .map((entry) => loadCase(manifestPath, entry));
}

function verifyCase(testCase: ScriptCorpusCase): void {
  if (testCase.expectedResult !== "valid") {
    throw new Error(`unsupported expected result for ${testCase.fixtureId}: ${testCase.expectedResult}`);
  }
  verifyTransactionInput(testCase.transaction, testCase.inputIndex, {
    scriptPubKey: testCase.scriptPubKey,
    amount: testCase.amount,
    spentPrevouts: testCase.spentPrevouts,
  });
}

function failureType(error: unknown): string {
  if (error instanceof ScriptVerifyError) {
    return "ScriptVerifyError";
  }
  if (error instanceof Error) {
    return error.name || "Error";
  }
  return "Error";
}

function failureStage(message: string): string {
  const lower = message.toLowerCase();
  if (lower.includes("witness") || lower.includes("scriptpubkey") || lower.includes("template") || lower.includes("p2sh") || lower.includes("p2w") || lower.includes("p2tr")) {
    return "template";
  }
  if (lower.includes("sighash") || lower.includes("signature hash") || lower.includes("hash type") || lower.includes("hashtype")) {
    return "sighash";
  }
  if (lower.includes("unsupported opcode") || lower.includes("opcode")) {
    return "opcode";
  }
  if (lower.includes("taproot") || lower.includes("tapscript") || lower.includes("control block") || lower.includes("tapleaf")) {
    return "taproot";
  }
  if (lower.includes("signature") || lower.includes("schnorr") || lower.includes("ecdsa") || lower.includes("der")) {
    return "crypto";
  }
  if (lower.includes("stack") || lower.includes("branch") || lower.includes("conditional") || lower.includes("verify failed") || lower.includes("equalverify")) {
    return "stack";
  }
  return "unknown";
}

export function runCase(testCase: ScriptCorpusCase): JsonObject {
  try {
    verifyCase(testCase);
  } catch (error) {
    const failure = error instanceof Error ? error.message : String(error);
    return {
      fixture_id: testCase.fixtureId,
      result: "failed",
      height: testCase.height,
      txid: testCase.txid,
      input_index: testCase.inputIndex,
      required_rules: testCase.requiredRules,
      missing_rule: testCase.missingRule,
      failure,
      failure_type: failureType(error),
      failure_stage: failureStage(failure),
    };
  }
  return {
    fixture_id: testCase.fixtureId,
    result: "passed",
    height: testCase.height,
    txid: testCase.txid,
    input_index: testCase.inputIndex,
    required_rules: testCase.requiredRules,
    missing_rule: testCase.missingRule,
    failure: "",
    failure_type: "",
    failure_stage: "",
  };
}

function gitCommit(): string {
  try {
    return execFileSync("git", ["rev-parse", "HEAD"], { cwd: repoRoot(), encoding: "utf8" }).trim();
  } catch {
    return "";
  }
}

export function runCorpus(manifestPath: string, fixtureId = ""): JsonObject {
  const cases = loadCases(manifestPath, fixtureId);
  const results = cases.map(runCase);
  const passed = results.filter((result) => result.result === "passed").length;
  const failed = results.filter((result) => result.result === "failed").length;
  return {
    implementation: "TypeScriptNode",
    category: "script_corpus",
    runtime_surface: "host",
    captured_at: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
    commit: gitCommit(),
    node_version: process.version,
    tsbitnode_version: VERSION,
    manifest: relative(repoRoot(), manifestPath),
    fixture_count: results.length,
    passed,
    failed,
    result: failed === 0 ? "passed" : "failed",
    results,
  };
}

async function main(): Promise<void> {
  const options = parseCli(
    process.argv,
    {
      manifest: { type: "string" },
      "result-path": { type: "string" },
      "fixture-id": { type: "string" },
    },
    { name: "tsbitnode-script-corpus", version: VERSION },
  );
  const manifestPath = resolve(typeof options.manifest === "string" ? options.manifest : defaultManifestPath());
  const resultPath = resolve(typeof options["result-path"] === "string" ? options["result-path"] : defaultResultPath());
  const fixtureId = typeof options["fixture-id"] === "string" ? options["fixture-id"] : "";
  const result = runCorpus(manifestPath, fixtureId);
  mkdirSync(dirname(resultPath), { recursive: true });
  writeFileSync(resultPath, `${JSON.stringify(result, null, 2)}\n`, "utf8");
  console.log(JSON.stringify({
    fixture_count: result.fixture_count,
    passed: result.passed,
    failed: result.failed,
    result: result.result,
    result_path: resultPath,
  }, null, 2));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  });
}
