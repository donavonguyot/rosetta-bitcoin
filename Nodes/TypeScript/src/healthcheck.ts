import { Settings } from "./config/settings.js";
import { getChain } from "./chain/params.js";
import { NativeNodeState } from "./runtime/nodeState.js";
import { META_LAST_ERROR, snapshotCounters } from "./metrics.js";

export interface HealthcheckPayload {
  ok: boolean;
  healthy: boolean;
  sync_status: string;
  chain: string;
  validated_height: number;
  header_height: number;
  block_count: number;
  utxo_count: number;
  peer_count: number;
  peer_records_total: number;
  mempool_tx_count: number;
  mempool_size: number;
  mempool_size_bytes: number;
  sync_progress_pct?: number | null;
  last_error?: string | null;
  metrics: Record<string, number>;
  summary: Record<string, unknown>;
  [key: string]: unknown;
}

function syncProgressPct(validatedHeight: number, peerTipHeight: number): number | null {
  if (peerTipHeight <= 0) return null;
  if (validatedHeight <= 0) return 0;
  return Math.round(Math.min(100, (100 * validatedHeight) / peerTipHeight) * 100) / 100;
}

function lastErrorValue(tracker: NativeNodeState): string | null {
  const raw = tracker.getMeta(META_LAST_ERROR);
  if (raw === undefined || raw.trim() === "") return null;
  return raw;
}

export function validateHealthcheckPayload(doc: HealthcheckPayload): void {
  const requiredTop = [
    "ok",
    "healthy",
    "sync_status",
    "chain",
    "validated_height",
    "header_height",
    "block_count",
    "utxo_count",
    "peer_count",
    "peer_records_total",
    "mempool_tx_count",
    "mempool_size",
    "mempool_size_bytes",
    "metrics",
    "summary",
  ] as const;

  const missing = requiredTop.filter((key) => !(key in doc));
  if (missing.length > 0) {
    throw new Error(`healthcheck payload missing keys: ${missing.join(", ")}`);
  }

  if (typeof doc.ok !== "boolean" || typeof doc.healthy !== "boolean") {
    throw new Error("ok and healthy must be bool");
  }
  if (doc.ok !== doc.healthy) {
    throw new Error("healthy must match ok");
  }
  if (typeof doc.sync_status !== "string") {
    throw new Error("sync_status must be str");
  }
  if (typeof doc.chain !== "string") {
    throw new Error("chain must be str");
  }

  const intFields = [
    "validated_height",
    "header_height",
    "block_count",
    "utxo_count",
    "peer_count",
    "peer_records_total",
    "mempool_tx_count",
    "mempool_size",
    "mempool_size_bytes",
  ] as const;

  for (const key of intFields) {
    const value = doc[key];
    if (typeof value !== "number" || !Number.isInteger(value)) {
      throw new Error(`${key} must be int`);
    }
  }

  const syncProgress = doc.sync_progress_pct;
  if (syncProgress !== undefined && syncProgress !== null && typeof syncProgress !== "number") {
    throw new Error("sync_progress_pct must be a number or null");
  }

  const lastError = doc.last_error;
  if (lastError !== undefined && lastError !== null && typeof lastError !== "string") {
    throw new Error("last_error must be str or null");
  }

  const metrics = doc.metrics;
  if (typeof metrics !== "object" || metrics === null || Array.isArray(metrics)) {
    throw new Error("metrics must be a dict");
  }
  for (const [name, value] of Object.entries(metrics)) {
    if (typeof name !== "string") {
      throw new Error("metrics keys must be str");
    }
    if (typeof value !== "number" || !Number.isInteger(value) || value < 0) {
      throw new Error(`metrics.${name} must be a non-negative int`);
    }
  }

  if (typeof doc.summary !== "object" || doc.summary === null || Array.isArray(doc.summary)) {
    throw new Error("summary must be a dict");
  }
}

export function dockerHealthDocument(
  settings: Settings,
  tracker: NativeNodeState,
): HealthcheckPayload {
  const summary = tracker.summary(settings.chain);
  const sync = summary.sync as Record<string, unknown>;
  const syncStatus =
    typeof sync.sync_status === "string" ? sync.sync_status : "unknown";
  const mempoolTxCount = Number.parseInt(tracker.getMeta("mempool_tx_count") ?? "0", 10);
  const mempoolSizeBytes = Number.parseInt(tracker.getMeta("mempool_size_bytes") ?? "0", 10);
  const peerTipHeight =
    typeof sync.best_height === "number" ? sync.best_height : Number(sync.best_height ?? 0);
  const validatedHeight = Number(summary.validated_height ?? 0);
  const metrics = snapshotCounters(tracker);
  const ok = syncStatus !== "error";

  return {
    ok,
    healthy: ok,
    sync_status: syncStatus,
    chain: settings.chain,
    validated_height: validatedHeight,
    header_height: tracker.maxHeaderHeight(),
    block_count: Number(summary.block_count ?? 0),
    utxo_count: Number(summary.utxo_count ?? 0),
    peer_count: Number(summary.connected_peers ?? 0),
    peer_records_total: Number(summary.peer_count ?? 0),
    mempool_tx_count: mempoolTxCount,
    mempool_size: mempoolTxCount,
    mempool_size_bytes: mempoolSizeBytes,
    sync_progress_pct: syncProgressPct(validatedHeight, peerTipHeight),
    last_error: lastErrorValue(tracker),
    metrics,
    summary: summary as unknown as Record<string, unknown>,
  };
}

export async function runHealthcheck(): Promise<number> {
  const settings = Settings.fromEnv();
  const tracker = await NativeNodeState.open(settings, getChain(settings.chain), { acquireLock: false });
  try {
    const payload = dockerHealthDocument(settings, tracker);
    try {
      validateHealthcheckPayload(payload);
    } catch (error) {
      console.log(JSON.stringify(payload));
      const message = error instanceof Error ? error.message : String(error);
      console.error(`healthcheck: payload validation failed: ${message}`);
      return 1;
    }
    console.log(JSON.stringify(payload));
    if (payload.sync_status === "error") {
      return 1;
    }
    return 0;
  } finally {
    await tracker.close();
  }
}
