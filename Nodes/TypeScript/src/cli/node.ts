#!/usr/bin/env node
import { Settings } from "../config/settings.js";
import { configureLogging, runNode } from "../node.js";
import { VERSION } from "../index.js";
import { parseCli, parseOptionalInt } from "./args.js";

const options = parseCli(
  process.argv,
  {
    chain: { type: "string" },
    datadir: { type: "string" },
    db: { type: "string" },
    peers: { type: "string" },
    "log-level": { type: "string" },
    "sync-only": { type: "boolean", default: false },
    "blocks-target": { type: "string" },
    "blocks-max": { type: "string" },
    listen: { type: "boolean", default: false },
  },
  { name: "tsbitnode", version: VERSION },
);

const blocksTarget = parseOptionalInt(options["blocks-target"]);
const blocksMax = parseOptionalInt(options["blocks-max"]);

const settings = Settings.fromEnv({
  ...(typeof options.chain === "string" ? { chain: options.chain } : {}),
  ...(typeof options.datadir === "string" ? { dataDir: options.datadir } : {}),
  ...(typeof options.db === "string" ? { dbPath: options.db } : {}),
  ...(typeof options.peers === "string" ? { peers: options.peers } : {}),
  ...(typeof options["log-level"] === "string" ? { logLevel: options["log-level"] } : {}),
  ...(blocksTarget !== undefined ? { blocksTargetHeight: blocksTarget } : {}),
  ...(blocksMax !== undefined ? { blocksMaxPerRun: blocksMax } : {}),
  ...(options.listen ? { listen: true } : {}),
});

configureLogging(settings.logLevel);

try {
  const code = await runNode(settings, { syncOnly: Boolean(options["sync-only"]) });
  process.exitCode = code;
} catch (error) {
  if (error instanceof Error) {
    console.error(error.message);
  }
  process.exitCode = 1;
}
