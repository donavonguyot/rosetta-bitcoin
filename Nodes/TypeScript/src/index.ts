/** tsbitnode — binary-compatible Bitcoin full node (testnet4). */

export const VERSION = "0.1.0";

export { Settings, type SettingsOptions } from "./config/settings.js";
export { getChain, CHAINS, type ChainParams } from "./chain/params.js";
export { runNode } from "./node.js";
export { startMetricsServer, type MetricsServerHandle } from "./metricsHttp.js";
export { prometheusExpositionFormat } from "./metrics.js";
