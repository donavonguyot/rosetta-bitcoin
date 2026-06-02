#!/usr/bin/env node
import { mkdirSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

import { parseCli } from "../cli/args.js";
import { Settings } from "../config/settings.js";
import { utcNowIso } from "../db/schema.js";
import { ProjectTracker } from "../db/tracker.js";
import { VERSION } from "../index.js";

const options = parseCli(
  process.argv,
  {
    db: { type: "string" },
    out: { type: "string", default: "snapshots" },
    chain: { type: "string" },
  },
  { name: "export-snapshots", version: VERSION },
);

const settings = Settings.fromEnv({
  ...(typeof options.db === "string" ? { dbPath: options.db } : {}),
  ...(typeof options.chain === "string" ? { chain: options.chain } : {}),
});

const dbPath = settings.resolvedDbPath();
const outDir = resolve(String(options.out));
mkdirSync(outDir, { recursive: true });

const tracker = new ProjectTracker(dbPath);
try {
  const exportedAt = utcNowIso();
  const summary = { ...tracker.summary(settings.chain), exported_at: exportedAt };
  writeFileSync(`${outDir}/status.json`, `${JSON.stringify(summary, null, 2)}\n`);
  writeFileSync(`${outDir}/phases.json`, `${JSON.stringify(tracker.listPhases(), null, 2)}\n`);
  writeFileSync(`${outDir}/wire.json`, `${JSON.stringify(tracker.wireProgress(), null, 2)}\n`);

  const capabilities = tracker.listWireCapabilities();
  const manifest = {
    exported_at: exportedAt,
    db_path: dbPath,
    chain: settings.chain,
    schema_version: tracker.getMeta("schema_version") ?? "0",
    files: ["status.json", "phases.json", "wire.json", "capabilities.json"],
  };
  writeFileSync(`${outDir}/capabilities.json`, `${JSON.stringify(capabilities, null, 2)}\n`);
  writeFileSync(`${outDir}/manifest.json`, `${JSON.stringify(manifest, null, 2)}\n`);
} finally {
  tracker.close();
}

console.log(`Exported snapshots to ${outDir}`);
