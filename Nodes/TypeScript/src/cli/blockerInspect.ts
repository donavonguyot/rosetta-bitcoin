#!/usr/bin/env node
import { pathToFileURL } from "node:url";

import { getChain } from "../chain/params.js";
import { ChainstateSession } from "../chainstate/chainstateSession.js";
import { Settings } from "../config/settings.js";
import { blockDeserialize } from "../consensus/block.js";
import { transactionTxid } from "../consensus/merkle.js";
import { transactionIsCoinbase } from "../messages/transaction.js";
import { VERSION } from "../version.js";
import { parseCli, parseOptionalInt } from "./args.js";

type TaprootWitnessKind =
  | "none"
  | "p2tr_key_path_candidate"
  | "p2tr_script_path_candidate"
  | "non_taproot_or_unknown";

function blockFileName(fileNumber: number): string {
  return `blk${String(fileNumber).padStart(5, "0")}.dat`;
}

function displayHash(internalHash: Buffer): string {
  return Buffer.from(internalHash).reverse().toString("hex");
}

function classifyTaprootWitness(stack: readonly Buffer[]): TaprootWitnessKind {
  if (stack.length === 0) {
    return "none";
  }
  if (stack.length === 1 && (stack[0]!.length === 64 || stack[0]!.length === 65)) {
    return "p2tr_key_path_candidate";
  }
  const controlBlock = stack[stack.length - 1]!;
  if (stack.length >= 2 && controlBlock.length >= 33 && (controlBlock[0]! & 0xfe) === 0xc0) {
    return "p2tr_script_path_candidate";
  }
  return "non_taproot_or_unknown";
}

export async function blockerInspectDocument(settings: Settings, requestedHeight?: number): Promise<Record<string, unknown>> {
  const chain = getChain(settings.chain);
  const session = await ChainstateSession.openNative(settings.dataDir, chain, { acquireLock: false });
  try {
    const height = requestedHeight ?? await session.store.maxStoredBlockHeight(chain.name);
    const record = await session.store.getBlock(chain.name, height);
    const currentBlocker = await session.store.currentBlocker(chain.name);
    if (record === null) {
      return {
        implementation: "TypeScriptNode",
        category: "blocker_inspect",
        runtime_surface: "native",
        chain: chain.name,
        datadir: session.dataDir,
        height,
        result: "missing_block",
        current_blocker: currentBlocker,
      };
    }

    const payload = session.blockStore.read(blockFileName(record.fileNumber), record.fileOffset, record.blockSize);
    const block = blockDeserialize(payload);
    const transactions = block.transactions.map((tx, txIndex) => ({
      tx_index: txIndex,
      txid: displayHash(transactionTxid(tx)),
      coinbase: transactionIsCoinbase(tx),
      inputs: tx.inputs.map((input, inputIndex) => ({
        input_index: inputIndex,
        prev_txid: displayHash(input.previousOutput.hash),
        prev_vout: input.previousOutput.index,
        witness_stack_depth: tx.witness[inputIndex]?.length ?? 0,
        witness_item_lengths: (tx.witness[inputIndex] ?? []).map((item) => item.length),
        taproot_witness_kind: classifyTaprootWitness(tx.witness[inputIndex] ?? []),
      })),
    }));

    return {
      implementation: "TypeScriptNode",
      category: "blocker_inspect",
      runtime_surface: "native",
      chain: chain.name,
      datadir: session.dataDir,
      height,
      block_hash: record.blockHash,
      block_file_number: record.fileNumber,
      block_file_offset: record.fileOffset,
      block_size: record.blockSize,
      current_blocker: currentBlocker,
      p2tr_key_path_candidates: transactions.reduce(
        (count, tx) => count + tx.inputs.filter((input) => input.taproot_witness_kind === "p2tr_key_path_candidate").length,
        0,
      ),
      p2tr_script_path_candidates: transactions.reduce(
        (count, tx) => count + tx.inputs.filter((input) => input.taproot_witness_kind === "p2tr_script_path_candidate").length,
        0,
      ),
      transactions,
      result: "ok",
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
      height: { type: "string" },
    },
    { name: "tsbitnode-blocker-inspect", version: VERSION },
  );
  const settings = Settings.fromEnv({
    ...(typeof options.chain === "string" ? { chain: options.chain } : {}),
    ...(typeof options.datadir === "string" ? { dataDir: options.datadir } : {}),
  });
  console.log(JSON.stringify(await blockerInspectDocument(settings, parseOptionalInt(options.height)), null, 2));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  });
}
