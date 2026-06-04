import { lookup } from "node:dns/promises";

import type { ChainParams } from "../chain/params.js";
import type { Settings } from "../config/settings.js";
import {
  filterExcludedPeers,
  PYTHON_NODE_DEFAULT_PEER,
  TESTNET4_FALLBACK_PEER_ENDPOINTS,
} from "../config/peers.js";
import type { NativeNodeState } from "../runtime/nodeState.js";
import { hostPortIsWellFormedEndpoint } from "../endpointParse.js";
import type { PeerEndpoint } from "../types/index.js";

export const BAN_HANDSHAKE_FAIL = 10;

function isRoutable(host: string, port: number): boolean {
  if (!hostPortIsWellFormedEndpoint(host, port)) {
    return false;
  }
  if (host === "0.0.0.0" || host === "::" || host === "127.0.0.1" || host === "::1") {
    return false;
  }
  if (host.startsWith("127.")) {
    return false;
  }
  return true;
}

/** Resolve DNS seeds to peer endpoints (best-effort). */
export async function resolveSeedPeers(
  chain: ChainParams,
  count: number,
): Promise<PeerEndpoint[]> {
  const peers: PeerEndpoint[] = [];
  const seen = new Set<string>();
  const seeds = [...chain.dnsSeeds].sort(() => Math.random() - 0.5);

  for (const seed of seeds) {
    try {
      const results = await lookup(seed, { all: true });
      for (const result of results) {
        if (result.address === PYTHON_NODE_DEFAULT_PEER) continue;
        const key = `${result.address}:${chain.defaultPort}`;
        if (seen.has(key)) continue;
        seen.add(key);
        peers.push([result.address, chain.defaultPort]);
        if (peers.length >= count) return peers;
      }
    } catch {
      continue;
    }
  }
  return peers;
}

async function resolveSeed(chain: ChainParams): Promise<PeerEndpoint> {
  if (chain.dnsSeeds.length === 0) {
    throw new Error(`No DNS seeds configured for ${chain.name}`);
  }
  for (const seed of chain.dnsSeeds) {
    try {
      const results = await lookup(seed, { all: true });
      if (results.length > 0) {
        return [results[0]!.address, chain.defaultPort];
      }
    } catch {
      continue;
    }
  }
  throw new Error(`Could not resolve any DNS seed for ${chain.name}`);
}

export function mergePeerCandidates(
  chain: ChainParams,
  options: {
    manual: readonly PeerEndpoint[];
    stored: readonly PeerEndpoint[];
    discovered: readonly PeerEndpoint[];
    seeds: readonly PeerEndpoint[];
  },
): PeerEndpoint[] {
  const merged: PeerEndpoint[] = [];
  const seen = new Set<string>();
  for (const group of [options.manual, options.stored, options.discovered, options.seeds]) {
    for (const [host, port] of group) {
      if (!isRoutable(host, port)) {
        continue;
      }
      const key = `${host}:${port}`;
      if (seen.has(key)) {
        continue;
      }
      seen.add(key);
      merged.push([host, port]);
    }
  }
  return merged;
}

/** Resolve DNS seeds and manual peers into connection targets. */
export async function bootstrapPeerTargets(
  chain: ChainParams,
  tracker: NativeNodeState,
  settings: Settings,
  manualPeers: readonly PeerEndpoint[],
): Promise<readonly PeerEndpoint[]> {
  const stored = tracker.listPeerAddressEndpoints(settings.maxOutboundPeers * 4);
  let seeds = await resolveSeedPeers(chain, settings.maxOutboundPeers);
  if (manualPeers.length === 0 && stored.length === 0 && seeds.length === 0) {
    try {
      seeds = [await resolveSeed(chain)];
    } catch {
      seeds = [...TESTNET4_FALLBACK_PEER_ENDPOINTS];
    }
  }
  const merged = mergePeerCandidates(chain, {
    manual: manualPeers,
    stored,
    discovered: [],
    seeds,
  }).slice(0, settings.maxOutboundPeers * 2);
  const threshold = settings.peerBanScoreThreshold;
  const manualSet = new Set(manualPeers.map(([host, port]) => `${host}:${port}`));
  const filtered = merged.filter(
    ([host, port]) =>
      manualSet.has(`${host}:${port}`) || tracker.getPeerEndpointBanScore(host, port) <= threshold,
  );
  const withoutExcluded = filterExcludedPeers(filtered);
  if (withoutExcluded.length > 0) {
    return withoutExcluded;
  }
  if (manualPeers.length > 0) {
    return [...manualPeers];
  }
  if (filtered.length > 0) {
    return filtered;
  }
  return [...TESTNET4_FALLBACK_PEER_ENDPOINTS];
}
