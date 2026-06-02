import { parseArgs, type ParseArgsOptionsConfig } from "node:util";

export function parseCli(
  argv: string[],
  options: ParseArgsOptionsConfig,
  config?: { version?: string; name?: string },
): Record<string, string | boolean | undefined> {
  const { values } = parseArgs({
    args: argv.slice(2),
    options: {
      help: { type: "boolean", short: "h", default: false },
      version: { type: "boolean", short: "v", default: false },
      ...options,
    },
    strict: true,
    allowPositionals: false,
  });

  if (values.help) {
    printHelp(config?.name ?? "tsbitnode", options);
    process.exit(0);
  }

  if (values.version && config?.version) {
    console.log(config.version);
    process.exit(0);
  }

  return values as Record<string, string | boolean | undefined>;
}

function printHelp(name: string, options: ParseArgsOptionsConfig): void {
  console.log(`Usage: ${name} [options]\n\nOptions:`);
  for (const [key, spec] of Object.entries(options)) {
    const short = spec.short ? `, -${spec.short}` : "";
    console.log(`  --${key}${short}`);
  }
}

export function parseOptionalInt(value: string | boolean | undefined): number | undefined {
  if (value === undefined || typeof value === "boolean") {
    return undefined;
  }
  return Number.parseInt(value, 10);
}
