#!/usr/bin/env node
import { join } from "node:path";
import { pathToFileURL } from "node:url";

import { Settings } from "../config/settings.js";
import { ChainstateSession } from "../chainstate/chainstateSession.js";
import { getChain } from "../chain/params.js";
import { secp256k1BackendInfo } from "../consensus/cryptoBackend.js";
import { isProcessAlive, readSyncLockMetadata, syncLockPath } from "../storage/syncLock.js";
import { VERSION } from "../version.js";
import { parseCli } from "./args.js";

export interface NativeStatusDocument {
  ok: boolean;
  node_id: string;
  implementation: "TypeScriptNode";
  network: string;
  runtime_surface: "native";
  runtime_status: "running" | "not_running";
  chain: string;
  datadir: string;
  binary_gate_status: "passed" | "failed" | "not_attempted";
  chainstate_backend: string;
  chainstate_backend_path: string;
  backend_version: string;
  codec_version: string;
  chainstate_generation_id: string;
  chainstate_status: string;
  native_storage: true;
  local_sqlite_artifact_absent: true;
  generation_id: string;
  sync_status: string;
  validated_height: number;
  validated_hash: string | null;
  header_height: number;
  header_hash: string | null;
  header_count: number;
  block_count: number;
  stored_block_height: number;
  stored_block_hash: string | null;
  block_gap_count: number;
  utxo_count: number;
  chainstate_utxo_count: number;
  native_crypto_backend: string;
  native_crypto_available: boolean;
  taproot_tweak_backend: string;
  lock_status: "locked" | "stale" | "unlocked";
  active_writer_pid: number | null;
  current_blocker: Record<string, unknown> | null;
  last_error: string | null;
  updated_at: string;
}

function binaryGateStatus(syncStatus: string, currentBlocker: Record<string, unknown> | null): NativeStatusDocument["binary_gate_status"] {
  if (currentBlocker !== null) {
    return "failed";
  }
  return syncStatus === "blocks_current" ? "passed" : "not_attempted";
}

export async function nativeStatusDocument(settings: Settings): Promise<NativeStatusDocument> {
  const chain = getChain(settings.chain);
  const lockMetadata = readSyncLockMetadata(syncLockPath(settings.dataDir));
  const lockAlive = lockMetadata !== null && isProcessAlive(lockMetadata.pid);
  const session = await ChainstateSession.openNative(settings.dataDir, chain, { acquireLock: false });
  try {
    const syncState = await session.store.getSyncState(chain.name);
    const validatedHeight = Math.max(0, await session.store.getValidatedHeight(chain.name));
    const validatedHash = await session.store.getValidatedHash(chain.name);
    const headerCount = await session.store.headerCount(chain.name);
    const blockCount = await session.store.blockCount(chain.name);
    const storedBlockHeight = await session.store.maxStoredBlockHeight(chain.name);
    const storedBlock = storedBlockHeight > 0 ? await session.store.getBlock(chain.name, storedBlockHeight) : null;
    const currentBlocker = await session.store.currentBlocker(chain.name);
    const syncStatus = syncState?.syncStatus ?? "starting";
    const cryptoInfo = secp256k1BackendInfo();
    const chainstateBackendPath = join(session.dataDir, "chainstate-rocksdb");
    const activeWriterPid = lockAlive ? lockMetadata.pid : null;
    return {
      ok: true,
      node_id: session.store.metadata.generationId,
      implementation: "TypeScriptNode",
      network: chain.name,
      runtime_surface: "native",
      runtime_status: activeWriterPid === null ? "not_running" : "running",
      chain: chain.name,
      datadir: session.dataDir,
      binary_gate_status: binaryGateStatus(syncStatus, currentBlocker),
      chainstate_backend: session.store.metadata.backendName,
      chainstate_backend_path: chainstateBackendPath,
      backend_version: session.store.metadata.backendVersion,
      codec_version: session.store.metadata.codecVersion,
      chainstate_generation_id: session.store.metadata.generationId,
      chainstate_status: session.store.metadata.status,
      native_storage: true,
      local_sqlite_artifact_absent: true,
      generation_id: session.store.metadata.generationId,
      sync_status: syncStatus,
      validated_height: validatedHeight,
      validated_hash: validatedHash,
      header_height: syncState?.bestHeight ?? 0,
      header_hash: syncState?.bestHash || null,
      header_count: headerCount,
      block_count: blockCount,
      stored_block_height: storedBlockHeight,
      stored_block_hash: storedBlock?.blockHash ?? null,
      block_gap_count: storedBlockHeight > 0 ? Math.max(0, storedBlockHeight - blockCount) : 0,
      utxo_count: await session.store.utxoCount(chain.name),
      chainstate_utxo_count: await session.store.utxoCount(chain.name),
      native_crypto_backend: String(cryptoInfo.ecdsa_backend ?? cryptoInfo.selected_backend ?? "unknown"),
      native_crypto_available: Boolean(cryptoInfo.native_available),
      taproot_tweak_backend: String(cryptoInfo.taproot_tweak_backend ?? "unknown"),
      lock_status: lockMetadata === null ? "unlocked" : lockAlive ? "locked" : "stale",
      active_writer_pid: activeWriterPid,
      current_blocker: currentBlocker,
      last_error: await session.store.lastError(chain.name),
      updated_at: session.store.metadata.updatedAt,
    };
  } finally {
    await session.close();
  }
}

async function main(): Promise<void> {
  const options = parseCli(
    process.argv,
    {
      chain: { type: "string" },
      datadir: { type: "string" },
    },
    { name: "tsbitnode-status", version: VERSION },
  );
  const settings = Settings.fromEnv({
    ...(typeof options.chain === "string" ? { chain: options.chain } : {}),
    ...(typeof options.datadir === "string" ? { dataDir: options.datadir } : {}),
  });
  console.log(JSON.stringify(await nativeStatusDocument(settings), null, 2));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  });
}
