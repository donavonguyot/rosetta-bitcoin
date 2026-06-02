/** Shared primitive types used across layers. */

export type HexString = string;
export type Hash256 = Buffer;
export type PeerEndpoint = readonly [host: string, port: number];

export type SyncStatus =
  | "starting"
  | "genesis_seeded"
  | "connected"
  | "headers_syncing"
  | "headers_current"
  | "blocks_syncing"
  | "blocks_current"
  | "running"
  | "error";

export type PhaseStatus = "pending" | "in_progress" | "completed";

export type VerifiedBy = "code" | "test" | "live" | "manual";

export interface ProjectPhase {
  phase: string;
  title: string;
  status: PhaseStatus;
  notes: string;
  updatedAt: string;
}

export interface SyncState {
  chain: string;
  bestHeight: number;
  bestHash: HexString;
  headerCount: number;
  syncStatus: SyncStatus;
  updatedAt: string;
}

export interface BlockHeader {
  version: number;
  prevBlock: Buffer;
  merkleRoot: Buffer;
  timestamp: number;
  bits: number;
  nonce: number;
}

export interface UtxoEntry {
  txid: HexString;
  vout: number;
  height: number;
  valueSats: bigint;
  scriptPubKey: Buffer;
}

export interface WireCapabilityRecord {
  id: string;
  checkpoint: string;
  category: string;
  name: string;
  description: string;
  required: boolean;
  implemented: boolean;
  verifiedBy?: VerifiedBy;
  notes?: string;
}
