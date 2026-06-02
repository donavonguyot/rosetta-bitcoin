export interface ChainstateMetadata {
  backendName: string;
  backendVersion: string;
  schemaVersion: string;
  codecVersion: string;
  chain: string;
  generationId: string;
  status: string;
  tipHeight: number;
  tipHash: string;
  createdAt: string;
  updatedAt: string;
}

export interface ChainstateSyncState {
  bestHeight: number;
  bestHash: string;
  headerCount: number;
  syncStatus: string;
}

export interface ChainstateHeaderRecord {
  height: number;
  blockHash: string;
  prevHash: string;
  headerSerializedHex: string;
}

export interface ChainstateBlockIndexRecord {
  height: number;
  blockHash: string;
  fileNumber: number;
  fileOffset: number;
  blockSize: number;
}

export interface ChainstateStoredUtxo {
  txid: string;
  vout: number;
  height: number;
  value: bigint;
  scriptPubKey: Buffer;
  coinbase: boolean;
}

export interface ChainstateOutpoint {
  txid: string;
  vout: number;
}

export interface ChainstateUndoEntry extends ChainstateStoredUtxo {}

export interface ChainstateBlockCommit {
  chain: string;
  height: number;
  blockHash: string;
  spentOutpoints: readonly ChainstateOutpoint[];
  createdUtxos: readonly ChainstateStoredUtxo[];
  undoEntries: readonly ChainstateUndoEntry[];
}

export interface ChainstateCommitResult {
  height: number;
  blockHash: string;
  createdUtxos: number;
  spentOutpoints: number;
}

export interface ChainstateStore {
  readonly metadata: ChainstateMetadata;

  close(): Promise<void>;
  metadataValue(key: string): Promise<string | null>;
  putMetadata(key: string, value: string): Promise<void>;

  getValidatedHeight(chain: string): Promise<number>;
  getValidatedHash(chain: string): Promise<string | null>;
  setValidatedTip(chain: string, height: number, blockHash: string): Promise<void>;

  getSyncState(chain: string): Promise<ChainstateSyncState | null>;
  upsertSyncState(chain: string, patch: Partial<ChainstateSyncState>): Promise<void>;

  insertHeader(chain: string, record: ChainstateHeaderRecord): Promise<void>;
  getHeaderHash(chain: string, height: number): Promise<string | null>;
  getHeaderSerializedHex(chain: string, height: number): Promise<string | null>;
  headerCount(chain: string): Promise<number>;

  recordBlock(chain: string, record: ChainstateBlockIndexRecord): Promise<void>;
  getBlock(chain: string, height: number): Promise<ChainstateBlockIndexRecord | null>;
  blockCount(chain: string): Promise<number>;
  maxStoredBlockHeight(chain: string): Promise<number>;

  getUtxo(chain: string, txid: string, vout: number): Promise<ChainstateStoredUtxo | null>;
  commitBlock(commit: ChainstateBlockCommit): Promise<ChainstateCommitResult>;
  readUndo(chain: string, height: number): Promise<ChainstateUndoEntry[]>;
  utxoCount(chain: string): Promise<number>;

  logEvent(category: string, message: string, severity?: string, detailsJson?: string): Promise<void>;
}
