import type { PeerEndpoint } from "./types/index.js";

const DNS_LABEL_SAFE =
  /^(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)*[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$/;

function isValidListenPort(port: number): boolean {
  return port >= 1 && port <= 65_535;
}

function hostIsPlainHostname(host: string): boolean {
  const normalized = host.trim().replace(/\.$/, "");
  if (!normalized || normalized.length > 253) {
    return false;
  }
  if (normalized.includes("_")) {
    return false;
  }
  return DNS_LABEL_SAFE.test(normalized);
}

/** Reject malformed wire/storage endpoints before connect or INSERT. */
export function hostPortIsWellFormedEndpoint(host: string, port: number): boolean {
  if (!host) {
    return false;
  }
  let candidate = host.trim();
  if (candidate.startsWith("[") && candidate.endsWith("]")) {
    candidate = candidate.slice(1, -1);
  }
  if (!isValidListenPort(port)) {
    return false;
  }
  const lower = candidate.toLowerCase();
  if (lower.startsWith("::ffff:")) {
    const suffix = candidate.slice(7);
    return /^(\d{1,3}\.){3}\d{1,3}$/.test(suffix);
  }
  if (lower === "::ffff" || lower === "ffff") {
    return false;
  }
  if (/^\d{1,3}(\.\d{1,3}){3}$/.test(candidate)) {
    const parts = candidate.split(".").map((part) => Number.parseInt(part, 10));
    return parts.every((part) => part >= 0 && part <= 255);
  }
  if (candidate.includes(":")) {
    return /^[0-9a-f:]+$/i.test(candidate);
  }
  return hostIsPlainHostname(candidate);
}

/** Parse comma-separated host:port peer list (mirrors pybitnode.endpoint_parse). */
export function splitManualPeerList(raw: string, defaultPort: number): PeerEndpoint[] {
  const peers: PeerEndpoint[] = [];
  for (const part of raw.split(",")) {
    const trimmed = part.trim();
    if (!trimmed) continue;
    const colon = trimmed.lastIndexOf(":");
    if (colon > 0 && colon < trimmed.length - 1) {
      const host = trimmed.slice(0, colon);
      const port = Number.parseInt(trimmed.slice(colon + 1), 10);
      if (!Number.isFinite(port) || port <= 0 || port > 65_535) {
        throw new Error(`Invalid peer port in ${trimmed}`);
      }
      peers.push([host, port]);
    } else {
      peers.push([trimmed, defaultPort]);
    }
  }
  return peers;
}
