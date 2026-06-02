import type { VerifiedBy, WireCapabilityRecord } from "../types/index.js";
import type { DatabaseSync } from "node:sqlite";

export interface WireCheckpoint {
  readonly id: string;
  readonly title: string;
  readonly description: string;
  readonly phase: string;
}

export interface WireCapability {
  readonly id: string;
  readonly checkpoint: string;
  readonly category: string;
  readonly name: string;
  readonly description: string;
  readonly required: boolean;
  readonly implemented: boolean;
}

export interface WireCheckpointStatus {
  checkpoint: string;
  title: string;
  phase: string;
  required_total: number;
  required_done: number;
  required_pass: boolean;
  optional_total: number;
  optional_done: number;
  capabilities_total: number;
  capabilities_done: number;
}

export interface FullNodeWireProgress {
  required_total: number;
  required_done: number;
  required_percent: number;
  checkpoints_total: number;
  checkpoints_passed: number;
  checkpoints_percent: number;
  full_node_wire_ready: boolean;
}

export const CHECKPOINTS: readonly WireCheckpoint[] = [
  {
    id: "cp0_framing",
    title: "Message framing",
    description: "Binary container format: magic, command, length, checksum.",
    phase: "phase0",
  },
  {
    id: "cp1_handshake",
    title: "Connection handshake",
    description: "version/verack exchange with correct services and user agent.",
    phase: "phase0",
  },
  {
    id: "cp2_discovery",
    title: "Peer discovery",
    description: "Find and connect to testnet4 peers.",
    phase: "phase0",
  },
  {
    id: "cp3_headers",
    title: "Header sync",
    description: "Download, parse, and persist the header chain.",
    phase: "phase1",
  },
  {
    id: "cp4_blocks",
    title: "Block download",
    description: "Request and receive full blocks over the wire.",
    phase: "phase2",
  },
  {
    id: "cp5_tx_relay",
    title: "Transaction relay",
    description: "Receive, validate policy, and rebroadcast transactions.",
    phase: "phase4",
  },
  {
    id: "cp6_serving",
    title: "Inbound serving",
    description: "Respond to peer requests as a network participant.",
    phase: "phase4",
  },
  {
    id: "cp7_keepalive",
    title: "Connection keepalive",
    description: "ping/pong and connection health.",
    phase: "phase0",
  },
  {
    id: "cp8_extensions",
    title: "Protocol extensions",
    description: "Optional modern protocol messages (sendheaders, compact blocks, etc.).",
    phase: "phase5",
  },
] as const;

export const CHECKPOINTS_BY_ID: Readonly<Record<string, WireCheckpoint>> = Object.fromEntries(
  CHECKPOINTS.map((cp) => [cp.id, cp]),
);

/** Seed capability registry — mirrors pybitnode/wire/capabilities.py structure. */
export const CAPABILITIES: readonly WireCapability[] = [
  {
    id: "frame.build",
    checkpoint: "cp0_framing",
    category: "framing",
    name: "Build P2P message frame",
    description: "Serialize 24-byte header + payload with correct checksum.",
    required: true,
    implemented: true,
  },
  {
    id: "frame.parse",
    checkpoint: "cp0_framing",
    category: "framing",
    name: "Parse P2P message header",
    description: "Read magic, command, length, checksum from 24-byte header.",
    required: true,
    implemented: true,
  },
  {
    id: "frame.checksum",
    checkpoint: "cp0_framing",
    category: "framing",
    name: "Verify payload checksum",
    description: "Reject messages where checksum != first 4 bytes of double-SHA256(payload).",
    required: true,
    implemented: true,
  },
  {
    id: "frame.magic",
    checkpoint: "cp0_framing",
    category: "framing",
    name: "Network magic validation",
    description: "Reject messages with wrong chain magic bytes.",
    required: true,
    implemented: true,
  },
  {
    id: "transport.outbound",
    checkpoint: "cp0_framing",
    category: "transport",
    name: "Outbound TCP connection",
    description: "Connect to peer host:port over asyncio TCP.",
    required: true,
    implemented: true,
  },
  {
    id: "transport.inbound",
    checkpoint: "cp0_framing",
    category: "transport",
    name: "Inbound TCP listener",
    description: "Accept incoming P2P connections on chain port.",
    required: false,
    implemented: false,
  },
  {
    id: "handshake.version.send",
    checkpoint: "cp1_handshake",
    category: "handshake",
    name: "Send version",
    description: "Send version message with protocol version, services, addrs, nonce, user agent.",
    required: true,
    implemented: true,
  },
  {
    id: "handshake.version.recv",
    checkpoint: "cp1_handshake",
    category: "handshake",
    name: "Receive and parse version",
    description: "Deserialize peer version including start_height and relay flag.",
    required: true,
    implemented: true,
  },
  {
    id: "handshake.verack.send",
    checkpoint: "cp1_handshake",
    category: "handshake",
    name: "Send verack",
    description: "Send verack after receiving peer version.",
    required: true,
    implemented: true,
  },
  {
    id: "handshake.verack.recv",
    checkpoint: "cp1_handshake",
    category: "handshake",
    name: "Receive verack",
    description: "Wait for peer verack to complete handshake.",
    required: true,
    implemented: true,
  },
  {
    id: "handshake.services",
    checkpoint: "cp1_handshake",
    category: "handshake",
    name: "Advertise NODE_NETWORK | NODE_WITNESS",
    description: "Set services flags required for full-node participation.",
    required: true,
    implemented: true,
  },
  {
    id: "handshake.sendheaders",
    checkpoint: "cp1_handshake",
    category: "handshake",
    name: "Send sendheaders (BIP130)",
    description: "Announce preference for headers-first block propagation.",
    required: true,
    implemented: true,
  },
  {
    id: "handshake.sendcmpct",
    checkpoint: "cp1_handshake",
    category: "handshake",
    name: "Send sendcmpct (BIP152)",
    description: "Negotiate compact block relay mode.",
    required: false,
    implemented: true,
  },
  {
    id: "handshake.wtxidrelay",
    checkpoint: "cp1_handshake",
    category: "handshake",
    name: "Send wtxidrelay (BIP339)",
    description: "Announce witness tx relay support.",
    required: false,
    implemented: false,
  },
  {
    id: "discovery.dns",
    checkpoint: "cp2_discovery",
    category: "discovery",
    name: "DNS seed resolution",
    description: "Resolve testnet4 DNS seeds to peer IP addresses.",
    required: true,
    implemented: true,
  },
  {
    id: "discovery.manual_peers",
    checkpoint: "cp2_discovery",
    category: "discovery",
    name: "Manual peer list",
    description: "Connect via --peers / PEERS env (host:port list).",
    required: true,
    implemented: true,
  },
  {
    id: "discovery.getaddr",
    checkpoint: "cp2_discovery",
    category: "discovery",
    name: "Send getaddr",
    description: "Request peer address gossip from connected peers.",
    required: true,
    implemented: true,
  },
  {
    id: "discovery.addr.recv",
    checkpoint: "cp2_discovery",
    category: "discovery",
    name: "Receive and parse addr",
    description: "Deserialize addr message and store peer addresses.",
    required: true,
    implemented: true,
  },
  {
    id: "discovery.addr.relay",
    checkpoint: "cp2_discovery",
    category: "discovery",
    name: "Relay addr to peers",
    description: "Forward known addresses to other connected peers.",
    required: false,
    implemented: false,
  },
  {
    id: "discovery.multi_peer",
    checkpoint: "cp2_discovery",
    category: "discovery",
    name: "Multiple simultaneous outbound peers",
    description: "Maintain a pool of 3+ outbound connections.",
    required: true,
    implemented: true,
  },
  {
    id: "headers.getheaders.send",
    checkpoint: "cp3_headers",
    category: "headers",
    name: "Send getheaders",
    description: "Request headers using block locator hashes.",
    required: true,
    implemented: true,
  },
  {
    id: "headers.headers.recv",
    checkpoint: "cp3_headers",
    category: "headers",
    name: "Receive and parse headers",
    description: "Deserialize headers message (80-byte header + varint tx count).",
    required: true,
    implemented: true,
  },
  {
    id: "headers.locator",
    checkpoint: "cp3_headers",
    category: "headers",
    name: "Block locator construction",
    description: "Build exponential block locator from stored header chain.",
    required: true,
    implemented: true,
  },
  {
    id: "headers.persist",
    checkpoint: "cp3_headers",
    category: "headers",
    name: "Persist headers to SQLite",
    description: "Store height, hash, prev_hash, timestamp for each header.",
    required: true,
    implemented: true,
  },
  {
    id: "headers.genesis",
    checkpoint: "cp3_headers",
    category: "headers",
    name: "Genesis header seeded",
    description: "Height 0 genesis block stored as chain anchor.",
    required: true,
    implemented: true,
  },
  {
    id: "headers.pow",
    checkpoint: "cp3_headers",
    category: "headers",
    name: "Proof-of-work validation",
    description: "Reject headers that do not meet nBits target.",
    required: true,
    implemented: true,
  },
  {
    id: "headers.chain_link",
    checkpoint: "cp3_headers",
    category: "headers",
    name: "Chain link validation",
    description: "Reject headers whose prev_hash does not match stored tip.",
    required: true,
    implemented: true,
  },
  {
    id: "headers.sync_to_tip",
    checkpoint: "cp3_headers",
    category: "headers",
    name: "Sync header chain to network tip",
    description: "Repeated getheaders until empty response or tip matches peer height.",
    required: true,
    implemented: true,
  },
  {
    id: "headers.resume",
    checkpoint: "cp3_headers",
    category: "headers",
    name: "Resume header sync from SQLite",
    description: "On restart, continue from stored best_height without re-fetching.",
    required: true,
    implemented: true,
  },
  {
    id: "headers.inv_trigger",
    checkpoint: "cp3_headers",
    category: "headers",
    name: "inv(MSG_BLOCK) triggers getheaders",
    description: "On block inv, update locator and fetch new headers.",
    required: true,
    implemented: true,
  },
  {
    id: "blocks.inv.recv",
    checkpoint: "cp4_blocks",
    category: "blocks",
    name: "Receive and parse inv",
    description: "Deserialize inv vectors (type + hash).",
    required: true,
    implemented: true,
  },
  {
    id: "blocks.getdata.send",
    checkpoint: "cp4_blocks",
    category: "blocks",
    name: "Send getdata for blocks",
    description: "Request MSG_WITNESS_BLOCK via getdata.",
    required: true,
    implemented: true,
  },
  {
    id: "blocks.block.recv",
    checkpoint: "cp4_blocks",
    category: "blocks",
    name: "Receive block message",
    description: "Read raw block payload from P2P wire.",
    required: true,
    implemented: true,
  },
  {
    id: "blocks.block.store",
    checkpoint: "cp4_blocks",
    category: "blocks",
    name: "Store raw block bytes",
    description: "Write block to blocks/*.dat flat files.",
    required: true,
    implemented: true,
  },
  {
    id: "blocks.notfound",
    checkpoint: "cp4_blocks",
    category: "blocks",
    name: "Handle notfound",
    description: "Request block from alternate peer on notfound.",
    required: true,
    implemented: true,
  },
  {
    id: "blocks.parallel",
    checkpoint: "cp4_blocks",
    category: "blocks",
    name: "Parallel block download",
    description: "Fetch blocks from multiple peers concurrently.",
    required: false,
    implemented: false,
  },
  {
    id: "tx.inv.recv",
    checkpoint: "cp5_tx_relay",
    category: "transactions",
    name: "Receive inv(MSG_WITNESS_TX)",
    description: "Parse transaction inventory announcements.",
    required: true,
    implemented: true,
  },
  {
    id: "tx.getdata.send",
    checkpoint: "cp5_tx_relay",
    category: "transactions",
    name: "Send getdata for transactions",
    description: "Request tx bytes from peer.",
    required: true,
    implemented: true,
  },
  {
    id: "tx.tx.recv",
    checkpoint: "cp5_tx_relay",
    category: "transactions",
    name: "Receive tx message",
    description: "Deserialize transaction from wire payload.",
    required: true,
    implemented: true,
  },
  {
    id: "tx.mempool",
    checkpoint: "cp5_tx_relay",
    category: "transactions",
    name: "Send mempool (BIP35)",
    description: "Request peer mempool tx inv after connection.",
    required: true,
    implemented: true,
  },
  {
    id: "tx.inv.send",
    checkpoint: "cp5_tx_relay",
    category: "transactions",
    name: "Announce transactions via inv",
    description: "Relay accepted mempool txs to peers.",
    required: true,
    implemented: true,
  },
  {
    id: "tx.feefilter",
    checkpoint: "cp5_tx_relay",
    category: "transactions",
    name: "Send feefilter (BIP133)",
    description: "Advertise minimum fee rate for inv relay.",
    required: false,
    implemented: true,
  },
  {
    id: "serve.getheaders",
    checkpoint: "cp6_serving",
    category: "serving",
    name: "Respond to getheaders",
    description: "Serve known headers to requesting peers.",
    required: true,
    implemented: false,
  },
  {
    id: "serve.getdata.blocks",
    checkpoint: "cp6_serving",
    category: "serving",
    name: "Respond to getdata (blocks)",
    description: "Serve stored blocks to requesting peers.",
    required: true,
    implemented: false,
  },
  {
    id: "serve.getdata.txs",
    checkpoint: "cp6_serving",
    category: "serving",
    name: "Respond to getdata (transactions)",
    description: "Serve mempool transactions to requesting peers.",
    required: true,
    implemented: false,
  },
  {
    id: "serve.inv.blocks",
    checkpoint: "cp6_serving",
    category: "serving",
    name: "Announce new blocks via inv",
    description: "Broadcast block inv when tip advances.",
    required: true,
    implemented: false,
  },
  {
    id: "keepalive.ping.recv",
    checkpoint: "cp7_keepalive",
    category: "keepalive",
    name: "Respond to ping with pong",
    description: "Reply to peer ping with matching nonce.",
    required: true,
    implemented: true,
  },
  {
    id: "keepalive.ping.send",
    checkpoint: "cp7_keepalive",
    category: "keepalive",
    name: "Send periodic ping",
    description: "Probe idle connections with ping messages.",
    required: true,
    implemented: true,
  },
  {
    id: "keepalive.timeout",
    checkpoint: "cp7_keepalive",
    category: "keepalive",
    name: "Disconnect stale peers",
    description: "Drop peers with no messages within timeout window.",
    required: true,
    implemented: true,
  },
  {
    id: "ext.cmpctblock",
    checkpoint: "cp8_extensions",
    category: "extensions",
    name: "Receive cmpctblock (BIP152)",
    description: "Parse compact block messages.",
    required: false,
    implemented: true,
  },
  {
    id: "ext.getblocktxn",
    checkpoint: "cp8_extensions",
    category: "extensions",
    name: "Send getblocktxn (BIP152)",
    description: "Request missing transactions for compact block.",
    required: false,
    implemented: true,
  },
  {
    id: "ext.reject",
    checkpoint: "cp8_extensions",
    category: "extensions",
    name: "Send/receive reject",
    description: "Protocol-level reject messages for invalid payloads (inbound parse path implemented).",
    required: false,
    implemented: true,
  },
  {
    id: "ext.bip324",
    checkpoint: "cp8_extensions",
    category: "extensions",
    name: "BIP324 v2 encrypted transport",
    description: "Encrypted P2P v2 transport instead of cleartext v1.",
    required: false,
    implemented: false,
  },
] as const;

export const CAPABILITIES_BY_ID: Readonly<Record<string, WireCapability>> = Object.fromEntries(
  CAPABILITIES.map((cap) => [cap.id, cap]),
);

export function capabilitiesForCheckpoint(checkpointId: string): readonly WireCapability[] {
  return CAPABILITIES.filter((cap) => cap.checkpoint === checkpointId);
}

export function checkpointStatus(
  capabilities: Readonly<Record<string, number>>,
): Record<string, WireCheckpointStatus> {
  const result: Record<string, WireCheckpointStatus> = {};
  for (const cp of CHECKPOINTS) {
    const caps = capabilitiesForCheckpoint(cp.id);
    const required = caps.filter((c) => c.required);
    const requiredDone = required.filter((c) => (capabilities[c.id] ?? 0) === 1).length;
    const optional = caps.filter((c) => !c.required);
    const optionalDone = optional.filter((c) => (capabilities[c.id] ?? 0) === 1).length;
    result[cp.id] = {
      checkpoint: cp.id,
      title: cp.title,
      phase: cp.phase,
      required_total: required.length,
      required_done: requiredDone,
      required_pass: required.length > 0 ? requiredDone === required.length : true,
      optional_total: optional.length,
      optional_done: optionalDone,
      capabilities_total: caps.length,
      capabilities_done: caps.filter((c) => (capabilities[c.id] ?? 0) === 1).length,
    };
  }
  return result;
}

export function fullNodeWireProgress(
  capabilities: Readonly<Record<string, number>>,
): FullNodeWireProgress {
  const required = CAPABILITIES.filter((c) => c.required);
  const requiredDone = required.filter((c) => (capabilities[c.id] ?? 0) === 1).length;
  const checkpoints = checkpointStatus(capabilities);
  const checkpointsPassed = Object.values(checkpoints).filter((cp) => cp.required_pass).length;
  return {
    required_total: required.length,
    required_done: requiredDone,
    required_percent: required.length > 0 ? Math.round((100 * requiredDone) / required.length * 10) / 10 : 100,
    checkpoints_total: CHECKPOINTS.length,
    checkpoints_passed: checkpointsPassed,
    checkpoints_percent: Math.round((100 * checkpointsPassed) / CHECKPOINTS.length * 10) / 10,
    full_node_wire_ready: requiredDone === required.length,
  };
}

export function seedCapabilityRecords(): WireCapabilityRecord[] {
  return CAPABILITIES.map((cap) => {
    const record: WireCapabilityRecord = { ...cap };
    if (cap.implemented) record.verifiedBy = "code";
    return record;
  });
}

/** Upsert registry defaults into wire_capabilities — mirrors pybitnode/db/schema.seed_wire_capabilities. */
export function seedWireCapabilities(db: Pick<DatabaseSync, "prepare">): void {
  const now = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
  const upsert = db.prepare(
    `INSERT INTO wire_capabilities(
       capability_id, checkpoint, category, name, description, required,
       implemented, verified_by, verified_at, notes
     ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(capability_id) DO UPDATE SET
       checkpoint = excluded.checkpoint,
       category = excluded.category,
       name = excluded.name,
       description = excluded.description,
       required = excluded.required,
       implemented = excluded.implemented,
       verified_by = excluded.verified_by,
       verified_at = excluded.verified_at,
       notes = excluded.notes`,
  );
  for (const cap of CAPABILITIES) {
    upsert.run(
      cap.id,
      cap.checkpoint,
      cap.category,
      cap.name,
      cap.description,
      cap.required ? 1 : 0,
      cap.implemented ? 1 : 0,
      cap.implemented ? "code" : "",
      cap.implemented ? now : "",
      "",
    );
  }
}

