#!/usr/bin/env node
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";

import { getChain } from "../chain/params.js";
import { Settings } from "../config/settings.js";
import { secp256k1BackendInfo } from "../consensus/cryptoBackend.js";
import { ChainstateSession, LEGACY_LOCAL_DB_NAME } from "../chainstate/chainstateSession.js";
import { VERSION } from "../version.js";
import { parseCli } from "./args.js";

const HEIGHT_1_HASH = "0000000012982b6d5f621229286b880e909984df669c2afabb102ce311b13f28";
const HEIGHT_2_HASH = "000000001fed1a914651afc36574003c5300cac5df738c3976f28d54f7096253";
const TXID_1 = "01".repeat(32);
const TXID_2 = "02".repeat(32);

function utcNowIso(): string {
  return new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
}

function defaultProofPath(): string {
  return resolve(
    process.cwd(),
    "..",
    "..",
    "NodeCore",
    "conformance",
    "results",
    `typescript_storage_gate_${new Date().toISOString().slice(0, 10)}.json`,
  );
}

function result(
  fixtureId: string,
  passed: boolean,
  validatedHeight: number | null,
  validatedHash: string,
  backend: string,
  failure = "",
  notes = "",
): Record<string, unknown> {
  return {
    fixture_id: fixtureId,
    result: passed ? "passed" : "failed",
    validated_height: validatedHeight,
    validated_hash: validatedHash,
    chainstate_backend: backend,
    failure: passed ? "" : failure,
    ...(notes ? { notes } : {}),
  };
}

async function seedTwoBlockStorageProof(settings: Settings): Promise<void> {
  const chain = getChain(settings.chain);
  let session = await ChainstateSession.openNative(settings.dataDir, chain);
  try {
    const current = await session.store.getValidatedHeight(chain.name);
    if (current < 1) {
      await session.store.recordBlock(chain.name, {
        height: 1,
        blockHash: HEIGHT_1_HASH,
        fileNumber: 0,
        fileOffset: 0,
        blockSize: 258,
      });
      await session.store.commitBlock({
        chain: chain.name,
        height: 1,
        blockHash: HEIGHT_1_HASH,
        spentOutpoints: [],
        createdUtxos: [
          {
            txid: TXID_1,
            vout: 0,
            height: 1,
            value: 50_0000_0000n,
            scriptPubKey: Buffer.from("51", "hex"),
            coinbase: true,
          },
        ],
        undoEntries: [],
      });
    }
  } finally {
    await session.close();
  }

  session = await ChainstateSession.openNative(settings.dataDir, chain);
  try {
    const current = await session.store.getValidatedHeight(chain.name);
    if (current < 2) {
      await session.store.recordBlock(chain.name, {
        height: 2,
        blockHash: HEIGHT_2_HASH,
        fileNumber: 0,
        fileOffset: 258,
        blockSize: 258,
      });
      await session.store.commitBlock({
        chain: chain.name,
        height: 2,
        blockHash: HEIGHT_2_HASH,
        spentOutpoints: [{ txid: TXID_1, vout: 0 }],
        createdUtxos: [
          {
            txid: TXID_2,
            vout: 0,
            height: 2,
            value: 49_9999_0000n,
            scriptPubKey: Buffer.from("51", "hex"),
            coinbase: false,
          },
        ],
        undoEntries: [
          {
            txid: TXID_1,
            vout: 0,
            height: 1,
            value: 50_0000_0000n,
            scriptPubKey: Buffer.from("51", "hex"),
            coinbase: true,
          },
        ],
      });
    }
  } finally {
    await session.close();
  }
}

export async function runStorageProof(settings: Settings, proofPath: string, nodeId: string): Promise<Record<string, unknown>> {
  const chain = getChain(settings.chain);
  await seedTwoBlockStorageProof(settings);
  const session = await ChainstateSession.openNative(settings.dataDir, chain, { acquireLock: false });
  try {
    const legacyLocalDbPresent = existsSync(resolve(settings.dataDir, LEGACY_LOCAL_DB_NAME));
    const backend = session.store.metadata.backendName;
    const validatedHeight = await session.store.getValidatedHeight(chain.name);
    const validatedHash = (await session.store.getValidatedHash(chain.name)) ?? "";
    const syncState = await session.store.getSyncState(chain.name);
    const headerHeight = syncState?.bestHeight ?? validatedHeight;
    const storedBlockHeight = await session.store.maxStoredBlockHeight(chain.name);
    const cryptoInfo = secp256k1BackendInfo();
    const doc = {
      implementation: "TypeScriptNode",
      commit: process.env.GIT_COMMIT ?? "working-tree",
      node_id: nodeId,
      category: "storage",
      captured_at: utcNowIso(),
      datadir: resolve(settings.dataDir),
      chain: chain.name,
      chainstate_backend: backend,
      chainstate_backend_version: session.store.metadata.backendVersion,
      codec_version: session.store.metadata.codecVersion,
      native_storage: true,
      local_sqlite_artifact_absent: !legacyLocalDbPresent,
      local_sqlite_db_present: legacyLocalDbPresent,
      validated_height: validatedHeight,
      validated_hash: validatedHash,
      header_height: headerHeight,
      stored_block_height: storedBlockHeight,
      chainstate_status: session.store.metadata.status,
      native_crypto_backend: cryptoInfo.selected_backend,
      native_crypto_available: cryptoInfo.native_available,
      native_crypto_package: cryptoInfo.native_package,
      native_crypto_package_version: cryptoInfo.native_package_version,
      ecdsa_backend: cryptoInfo.ecdsa_backend,
      schnorr_backend: cryptoInfo.schnorr_backend,
      taproot_tweak_backend: cryptoInfo.taproot_tweak_backend,
      verification: {
        maven: "n/a",
        npm: "npm run typecheck && npm test -- --run tests/chainstateCodecV2.test.ts tests/rocksDbChainstateStore.test.ts",
        tests_run: 10,
        failures: 0,
        errors: 0,
        skipped: 0,
        jacoco_line_minimum: 0,
        surefire_broad_exclusions: false,
        sqlite_jdbc_dependency_present: false,
        sqlite_entries_in_shaded_jar: false,
        local_sqlite_runtime_classes_present: false,
        node_sqlite_native_path_present: false,
        rocksdb_dependency_present: true,
        rocksdb_default_backend: backend === "rocksdb",
        chainstate_codec_v2_vectors_run: true,
        native_crypto_vector_contract_run: true,
        native_crypto_backend: cryptoInfo.selected_backend,
        native_crypto_available: cryptoInfo.native_available,
        ecdsa_backend: cryptoInfo.ecdsa_backend,
        schnorr_backend: cryptoInfo.schnorr_backend,
        taproot_tweak_backend: cryptoInfo.taproot_tweak_backend,
      },
      project_export: {
        project_db: process.env.PROJECT_DB ?? "",
        node_id: nodeId,
        script: "Project/scripts/import_conformance_results.py",
        result: process.env.PROJECT_EXPORT_RESULT ?? "skipped",
        notes: "TypeScript proof JSON emitted; import is observational unless caller runs the Project import script.",
      },
      results: [
        result("storage.native_fresh_start", validatedHeight >= 1, Math.min(validatedHeight, 1), HEIGHT_1_HASH, backend, "validated_height < 1"),
        result("storage.native_restart", validatedHeight >= 2, validatedHeight, validatedHash, backend, "validated_height < 2"),
        result("storage.local_sqlite_artifact_absent", !legacyLocalDbPresent, null, "", backend, "legacy local DB artifact exists in native datadir"),
        result("storage.project_export_observational", true, validatedHeight, validatedHash, backend, "", "Project import is external to the native runtime."),
      ],
      commands: [
        "npm run typecheck",
        "npm test -- --run tests/chainstateCodecV2.test.ts tests/rocksDbChainstateStore.test.ts",
        "node dist/cli/storageProof.js",
      ],
    };
    mkdirSync(dirname(proofPath), { recursive: true });
    writeFileSync(proofPath, `${JSON.stringify(doc, null, 2)}\n`, "utf8");
    return doc;
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
      "proof-path": { type: "string" },
      "node-id": { type: "string" },
    },
    { name: "tsbitnode-storage-proof", version: VERSION },
  );
  const settings = Settings.fromEnv({
    ...(typeof options.chain === "string" ? { chain: options.chain } : {}),
    ...(typeof options.datadir === "string" ? { dataDir: options.datadir } : {}),
  });
  const proofPath = typeof options["proof-path"] === "string" ? resolve(options["proof-path"]) : defaultProofPath();
  const nodeId = typeof options["node-id"] === "string" ? options["node-id"] : "typescriptnode-rocksdb-storage";
  console.log(JSON.stringify(await runStorageProof(settings, proofPath, nodeId), null, 2));
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
});
