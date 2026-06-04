import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { join, relative } from "node:path";
import { describe, expect, it } from "vitest";

const REPO_ROOT = join(import.meta.dirname, "..");
const FORBIDDEN = new RegExp([
  ["node", "sqlite"].join(":"),
  ["Database", "Sync"].join(""),
  ["Project", "Tracker"].join(""),
  ["tsbitnode", "db"].join("\\."),
  ["resolved", "Db", "Path"].join(""),
  ["db", "Path"].join(""),
].join("|"));

function listTrackedRuntimeFiles(): string[] {
  const output = execFileSync("git", ["ls-files", "Nodes/TypeScript/src", "Nodes/TypeScript/tests", "Nodes/TypeScript/package.json"], {
    cwd: join(REPO_ROOT, "..", ".."),
    encoding: "utf8",
  });
  return output
    .trim()
    .split("\n")
    .filter((path) => path.endsWith(".ts") || path.endsWith("package.json"));
}

describe("TypeScript runtime SQLite ban", () => {
  it("does not contain SQLite runtime dependencies or legacy tracker names", () => {
    const offenders: string[] = [];
    for (const path of listTrackedRuntimeFiles()) {
      const absolute = join(REPO_ROOT, "..", "..", path);
      if (!existsSync(absolute)) continue;
      const text = readFileSync(absolute, "utf8");
      if (FORBIDDEN.test(text)) {
        offenders.push(relative(join(REPO_ROOT, "..", ".."), absolute));
      }
    }
    expect(offenders).toEqual([]);
  });
});
