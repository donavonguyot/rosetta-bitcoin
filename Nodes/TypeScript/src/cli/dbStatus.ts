#!/usr/bin/env node
import { Settings } from "../config/settings.js";
import { ProjectTracker } from "../db/tracker.js";
import { VERSION } from "../index.js";
import { checkpointStatus } from "../wire/capabilities.js";
import { parseCli, parseOptionalInt } from "./args.js";

const options = parseCli(
  process.argv,
  {
    chain: { type: "string" },
    db: { type: "string" },
    phases: { type: "boolean", default: false },
    wire: { type: "boolean", default: false },
    checkpoint: { type: "string" },
    events: { type: "string" },
  },
  { name: "tsbitnode-legacy-db", version: VERSION },
);

const settings = Settings.fromEnv({
  ...(typeof options.chain === "string" ? { chain: options.chain } : {}),
  ...(typeof options.db === "string" ? { dbPath: options.db } : {}),
});

const tracker = new ProjectTracker(settings.resolvedDbPath());
try {
  if (options.wire) {
    console.log(JSON.stringify(tracker.wireProgress(), null, 2));
  } else if (options.phases) {
    console.log(JSON.stringify(tracker.listPhases(), null, 2));
  } else if (typeof options.checkpoint === "string") {
    const capMap = tracker.wireCapabilityMap();
    const caps = tracker.listWireCapabilities(options.checkpoint);
    const cpStatus = checkpointStatus(capMap)[options.checkpoint];
    console.log(JSON.stringify({ checkpoint: cpStatus, capabilities: caps }, null, 2));
  } else {
    const eventsLimit = parseOptionalInt(options.events);
    if (eventsLimit !== undefined) {
      console.log(JSON.stringify(tracker.recentEvents(eventsLimit), null, 2));
    } else {
      console.log(JSON.stringify(tracker.summary(settings.chain), null, 2));
    }
  }
} finally {
  tracker.close();
}
