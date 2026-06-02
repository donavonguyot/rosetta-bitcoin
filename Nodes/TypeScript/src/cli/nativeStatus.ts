#!/usr/bin/env node
import { Settings } from "../config/settings.js";
import { ChainstateSession } from "../db/chainstateSession.js";
import { getChain } from "../chain/params.js";
import { VERSION } from "../version.js";
import { parseCli } from "./args.js";

export interface NativeStatusDocument {
  ok: boolean;
  runtime_surface: "native";
  chain: string;
  datadir: string;
  chainstate_backend: string;
  backend_version: string;
  codec_version: string;
  native_storage: true;
  local_sqlite_artifact_absent: true;
  generation_id: string;
  sync_status: string;
  validated_height: number;
  validated_hash: string | null;
  header_height: number;
  header_count: number;
  block_count: number;
  stored_block_height: number;
  utxo_count: number;
}

export async function nativeStatusDocument(settings: Settings): Promise<NativeStatusDocument> {
  const chain = getChain(settings.chain);
  const session = await ChainstateSession.openNative(settings.dataDir, chain, { acquireLock: false });
  try {
    const syncState = await session.store.getSyncState(chain.name);
    const validatedHeight = Math.max(0, await session.store.getValidatedHeight(chain.name));
    const validatedHash = await session.store.getValidatedHash(chain.name);
    const headerCount = await session.store.headerCount(chain.name);
    const storedBlockHeight = await session.store.maxStoredBlockHeight(chain.name);
    return {
      ok: true,
      runtime_surface: "native",
      chain: chain.name,
      datadir: session.dataDir,
      chainstate_backend: session.store.metadata.backendName,
      backend_version: session.store.metadata.backendVersion,
      codec_version: session.store.metadata.codecVersion,
      native_storage: true,
      local_sqlite_artifact_absent: true,
      generation_id: session.store.metadata.generationId,
      sync_status: syncState?.syncStatus ?? "starting",
      validated_height: validatedHeight,
      validated_hash: validatedHash,
      header_height: syncState?.bestHeight ?? 0,
      header_count: headerCount,
      block_count: await session.store.blockCount(chain.name),
      stored_block_height: storedBlockHeight,
      utxo_count: await session.store.utxoCount(chain.name),
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
    { name: "tsbitnode-native-status", version: VERSION },
  );
  const settings = Settings.fromEnv({
    ...(typeof options.chain === "string" ? { chain: options.chain } : {}),
    ...(typeof options.datadir === "string" ? { dataDir: options.datadir } : {}),
  });
  console.log(JSON.stringify(await nativeStatusDocument(settings), null, 2));
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
});
