import { splitManualPeerList } from "../endpointParse.js";
import type { PeerEndpoint } from "../types/index.js";

/** Manual peer used by PythonNode ops/scripts (see PythonNode/.tmp_continue_sync_batches.sh). */
export const PYTHON_NODE_DEFAULT_PEER = "89.167.10.150";
export const PYTHON_NODE_DEFAULT_PEER_PORT = 48_333;
export const PYTHON_NODE_DEFAULT_PEER_ENDPOINT: PeerEndpoint = [
  PYTHON_NODE_DEFAULT_PEER,
  PYTHON_NODE_DEFAULT_PEER_PORT,
];

/** Last-resort bootstrap targets when DNS seeds fail or exclusion removes all candidates. */
export const TESTNET4_FALLBACK_PEER_ENDPOINTS: readonly PeerEndpoint[] = [
  PYTHON_NODE_DEFAULT_PEER_ENDPOINT,
];

/** Filter peers that TypeScriptNode intentionally avoids sharing with PythonNode. */
export function filterExcludedPeers(
  peers: readonly PeerEndpoint[],
  excludeHosts: readonly string[] = [PYTHON_NODE_DEFAULT_PEER],
): PeerEndpoint[] {
  return peers.filter(([host]) => !excludeHosts.includes(host));
}

/** Resolve manual peer list, excluding PythonNode's default manual peer when alternatives exist. */
export function resolveManualPeers(raw: string, defaultPort: number): PeerEndpoint[] {
  const parsed = splitManualPeerList(raw, defaultPort);
  const filtered = filterExcludedPeers(parsed);
  return filtered.length > 0 ? filtered : parsed;
}
