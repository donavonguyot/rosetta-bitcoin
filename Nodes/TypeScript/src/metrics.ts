import type { ProjectTracker } from "./db/tracker.js";

export const META_BLOCKS_VALIDATED_TOTAL = "metric_blocks_validated_total";
export const META_TXS_RELAYED_TOTAL = "metric_txs_relayed_total";
export const META_LAST_ERROR = "last_error";

function readInt(metaValue: string | undefined): number {
  if (!metaValue) return 0;
  const parsed = Number.parseInt(metaValue, 10);
  return Number.isNaN(parsed) ? 0 : parsed;
}

export function snapshotCounters(tracker: ProjectTracker): Record<string, number> {
  return {
    blocks_validated_total: readInt(tracker.getMeta(META_BLOCKS_VALIDATED_TOTAL)),
    txs_relayed_total: readInt(tracker.getMeta(META_TXS_RELAYED_TOTAL)),
  };
}

export function incrMetaCounter(tracker: ProjectTracker, key: string, delta = 1): void {
  const current = Number.parseInt(tracker.getMeta(key) ?? "0", 10);
  tracker.setMeta(key, String(current + delta));
}

export function recordLastError(tracker: ProjectTracker, message: string): void {
  tracker.setMeta(META_LAST_ERROR, message.slice(0, 4000));
}

export function clearLastError(tracker: ProjectTracker): void {
  tracker.setMeta(META_LAST_ERROR, "");
}

function escapePrometheusLabelValue(raw: string): string {
  let out = "";
  for (const ch of raw) {
    if (ch === "\\") out += "\\\\";
    else if (ch === "\n") out += "\\n";
    else if (ch === '"') out += '\\"';
    else out += ch;
  }
  return out;
}

export function prometheusExpositionFormat(
  tracker: ProjectTracker,
  options: { chain: string },
): string {
  const chainEsc = escapePrometheusLabelValue(options.chain);
  const counters = snapshotCounters(tracker);
  const summary = tracker.summary(options.chain);
  const sync = summary.sync;
  const syncStatus =
    typeof sync.sync_status === "string" ? sync.sync_status : "unknown";
  const syncStatusEsc = escapePrometheusLabelValue(syncStatus);
  const mempoolTxCount = readInt(tracker.getMeta("mempool_tx_count"));
  const mempoolSizeBytes = readInt(tracker.getMeta("mempool_size_bytes"));

  const lines = [
    "# HELP blocks_validated_total Blocks validated and connected.",
    "# TYPE blocks_validated_total counter",
    `blocks_validated_total{chain="${chainEsc}"} ${counters.blocks_validated_total}`,
    "",
    "# HELP txs_relayed_total Transactions relayed toward peers.",
    "# TYPE txs_relayed_total counter",
    `txs_relayed_total{chain="${chainEsc}"} ${counters.txs_relayed_total}`,
    "",
    "# HELP validated_height Validated chain tip height.",
    "# TYPE validated_height gauge",
    `validated_height{chain="${chainEsc}"} ${summary.validated_height}`,
    "",
    "# HELP header_height Highest stored header height.",
    "# TYPE header_height gauge",
    `header_height{chain="${chainEsc}"} ${tracker.maxHeaderHeight()}`,
    "",
    "# HELP block_count Stored block count.",
    "# TYPE block_count gauge",
    `block_count{chain="${chainEsc}"} ${summary.block_count}`,
    "",
    "# HELP utxo_count UTXO set size.",
    "# TYPE utxo_count gauge",
    `utxo_count{chain="${chainEsc}"} ${summary.utxo_count}`,
    "",
    "# HELP peer_count Connected peer count.",
    "# TYPE peer_count gauge",
    `peer_count{chain="${chainEsc}"} ${summary.connected_peers}`,
    "",
    "# HELP peer_records_total Total peer records in database.",
    "# TYPE peer_records_total gauge",
    `peer_records_total{chain="${chainEsc}"} ${summary.peer_count}`,
    "",
    "# HELP mempool_tx_count Mempool transaction count.",
    "# TYPE mempool_tx_count gauge",
    `mempool_tx_count{chain="${chainEsc}"} ${mempoolTxCount}`,
    "",
    "# HELP mempool_size_bytes Mempool size in bytes.",
    "# TYPE mempool_size_bytes gauge",
    `mempool_size_bytes{chain="${chainEsc}"} ${mempoolSizeBytes}`,
    "",
    "# HELP sync_status_info Current sync status (1 = active status label).",
    "# TYPE sync_status_info gauge",
    `sync_status_info{chain="${chainEsc}",status="${syncStatusEsc}"} 1`,
    "",
  ];
  return lines.join("\n");
}
