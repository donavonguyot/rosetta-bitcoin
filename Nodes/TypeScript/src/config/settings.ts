export interface SettingsOptions {
  chain?: string;
  dataDir?: string;
  listen?: boolean;
  p2pPort?: number;
  peers?: string;
  logLevel?: string;
  protocolVersion?: number;
  userAgent?: string;
  blocksBatchSize?: number;
  blocksMaxPerRun?: number;
  blocksTargetHeight?: number;
  parallelBlockDownloads?: number;
  rebuildValidatedChain?: boolean;
  maxOutboundPeers?: number;
  pingIntervalSeconds?: number;
  peerStaleSeconds?: number;
  minRelayFeerateSatVb?: number;
  peerBanScoreThreshold?: number;
  peerBanDecayUptimeSeconds?: number;
  peerBanDecayAmount?: number;
  skipGetaddr?: boolean;
  syncSkipHeaders?: boolean;
  noHeaderRefresh?: boolean;
  simpleHandshake?: boolean;
  enableOrphanPool?: boolean;
  mempoolMaxCount?: number;
  mempoolMaxAgeSeconds?: number;
  metricsHttpBind?: string;
  metricsHttpPort?: number;
}

function envBool(name: string, defaultValue: boolean): boolean {
  const raw = process.env[name];
  if (raw === undefined) return defaultValue;
  return ["1", "true", "yes", "on"].includes(raw.trim().toLowerCase());
}

function envInt(name: string, defaultValue: number): number {
  const raw = process.env[name];
  if (raw === undefined || raw.trim() === "") return defaultValue;
  return Number.parseInt(raw, 10);
}

function envFloat(name: string, defaultValue: number): number {
  const raw = process.env[name];
  if (raw === undefined || raw.trim() === "") return defaultValue;
  return Number.parseFloat(raw);
}

export class Settings {
  chain = "testnet4";
  dataDir = "./data-ts";
  listen = false;
  p2pPort = 0;
  peers = "";
  logLevel = "info";
  protocolVersion = 70_016;
  userAgent = "/tsbitnode:0.1.0/";
  blocksBatchSize = 32;
  blocksMaxPerRun = 64;
  blocksTargetHeight = 0;
  parallelBlockDownloads = 0;
  rebuildValidatedChain = false;
  maxOutboundPeers = 3;
  pingIntervalSeconds = 1200;
  peerStaleSeconds = 5400;
  minRelayFeerateSatVb = 0;
  peerBanScoreThreshold = 100;
  peerBanDecayUptimeSeconds = 300;
  peerBanDecayAmount = 15;
  skipGetaddr = false;
  syncSkipHeaders = false;
  noHeaderRefresh = false;
  simpleHandshake = false;
  enableOrphanPool = false;
  mempoolMaxCount = 10_000;
  mempoolMaxAgeSeconds = 86_400;
  metricsHttpBind = "127.0.0.1";
  metricsHttpPort = 0;

  static fromEnv(overrides: SettingsOptions = {}): Settings {
    const settings = new Settings();
    settings.chain = process.env.CHAIN ?? settings.chain;
    settings.dataDir = process.env.DATA_DIR ?? settings.dataDir;
    settings.listen = envBool("LISTEN", settings.listen);
    settings.p2pPort = envInt("P2P_PORT", settings.p2pPort);
    settings.peers = process.env.PEERS ?? settings.peers;
    settings.logLevel = process.env.LOG_LEVEL ?? settings.logLevel;
    settings.protocolVersion = envInt("PROTOCOL_VERSION", settings.protocolVersion);
    settings.userAgent = process.env.USER_AGENT ?? settings.userAgent;
    settings.blocksBatchSize = envInt("BLOCKS_BATCH_SIZE", settings.blocksBatchSize);
    settings.blocksMaxPerRun = envInt("BLOCKS_MAX_PER_RUN", settings.blocksMaxPerRun);
    settings.blocksTargetHeight = envInt("BLOCKS_TARGET_HEIGHT", settings.blocksTargetHeight);
    settings.parallelBlockDownloads = envInt("PARALLEL_BLOCK_DOWNLOADS", settings.parallelBlockDownloads);
    settings.maxOutboundPeers = envInt("MAX_OUTBOUND_PEERS", settings.maxOutboundPeers);
    settings.pingIntervalSeconds = envFloat("PING_INTERVAL_SECONDS", settings.pingIntervalSeconds);
    settings.peerStaleSeconds = envFloat("PEER_STALE_SECONDS", settings.peerStaleSeconds);
    settings.minRelayFeerateSatVb = envInt("MIN_RELAY_FEERATE_SAT_VB", settings.minRelayFeerateSatVb);
    settings.peerBanScoreThreshold = envInt("PEER_BAN_SCORE_THRESHOLD", settings.peerBanScoreThreshold);
    settings.peerBanDecayUptimeSeconds = envFloat(
      "PEER_BAN_DECAY_UPTIME_SECONDS",
      settings.peerBanDecayUptimeSeconds,
    );
    settings.peerBanDecayAmount = envInt("PEER_BAN_DECAY_AMOUNT", settings.peerBanDecayAmount);
    settings.skipGetaddr = envBool("SKIP_GETADDR", settings.skipGetaddr);
    settings.syncSkipHeaders = envBool("SYNC_SKIP_HEADERS", settings.syncSkipHeaders);
    settings.noHeaderRefresh = envBool("NO_HEADER_REFRESH", settings.noHeaderRefresh);
    settings.simpleHandshake = envBool("SIMPLE_HANDSHAKE", settings.simpleHandshake);
    settings.enableOrphanPool = envBool("ENABLE_ORPHAN_POOL", settings.enableOrphanPool);
    settings.mempoolMaxCount = envInt("MEMPOOL_MAX_COUNT", settings.mempoolMaxCount);
    settings.mempoolMaxAgeSeconds = envInt("MEMPOOL_MAX_AGE_SECONDS", settings.mempoolMaxAgeSeconds);
    settings.metricsHttpBind = (process.env.METRICS_HTTP_BIND ?? settings.metricsHttpBind).trim();
    settings.metricsHttpPort = envInt(
      "METRICS_HTTP_PORT",
      envInt("METRICS_PORT", settings.metricsHttpPort),
    );
    Object.assign(settings, overrides);
    return settings;
  }

  blocksDir(): string {
    return `${this.dataDir.replace(/\/$/, "")}/blocks`;
  }
}
