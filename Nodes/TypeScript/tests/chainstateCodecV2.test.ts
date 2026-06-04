import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

import {
  blockIndexKey,
  decodeBlockIndex,
  decodeHeader,
  decodeMetadataValue,
  decodeTip,
  decodeUndo,
  decodeUtxo,
  encodeBlockIndex,
  encodeHeader,
  encodeTip,
  encodeUndo,
  encodeUtxo,
  headerKey,
  metadataKey,
  metadataValue,
  tipKey,
  undoKey,
  utxoKey,
} from "../src/storage/chainstateCodecV2.js";

interface ChainstateCodecFixture {
  chain: string;
  txid_internal_hex: string;
  block_hash_internal_hex: string;
  script_pubkey_hex: string;
  utxo: {
    height: number;
    vout: number;
    value_sats: number;
    coinbase: boolean;
    key_hex: string;
    value_hex: string;
  };
  undo: {
    height: number;
    key_hex: string;
    value_hex: string;
  };
  tip: {
    height: number;
    key_hex: string;
    value_hex: string;
  };
  block_index: {
    height: number;
    file_number: number;
    file_offset: number;
    block_size: number;
    key_hex: string;
    value_hex: string;
  };
  header: {
    height: number;
    serialized_header_hex: string;
    key_hex: string;
    value_hex: string;
  };
  metadata: {
    name: string;
    value: string;
    key_hex: string;
    value_hex: string;
  };
}

function loadFixture(): ChainstateCodecFixture {
  const path = join(
    import.meta.dirname,
    "..",
    "..",
    "Shared",
    "conformance",
    "fixtures",
    "chainstate_codec_v2_vectors.json",
  );
  return JSON.parse(readFileSync(path, "utf8")) as ChainstateCodecFixture;
}

describe("Chainstate Codec v2", () => {
  const fixture = loadFixture();
  const txidInternal = Buffer.from(fixture.txid_internal_hex, "hex");
  const blockHashInternal = Buffer.from(fixture.block_hash_internal_hex, "hex");
  const scriptPubkey = Buffer.from(fixture.script_pubkey_hex, "hex");

  it("matches UTXO key and value vectors", () => {
    expect(utxoKey(fixture.chain, txidInternal, fixture.utxo.vout).toString("hex")).toBe(
      fixture.utxo.key_hex,
    );
    const encoded = encodeUtxo({
      height: fixture.utxo.height,
      valueSats: BigInt(fixture.utxo.value_sats),
      scriptPubkey,
      coinbase: fixture.utxo.coinbase,
    });
    expect(encoded.toString("hex")).toBe(fixture.utxo.value_hex);
    expect(decodeUtxo(encoded)).toEqual({
      height: fixture.utxo.height,
      valueSats: BigInt(fixture.utxo.value_sats),
      scriptPubkey,
      coinbase: fixture.utxo.coinbase,
    });
  });

  it("matches undo key and value vectors", () => {
    expect(undoKey(fixture.chain, fixture.undo.height).toString("hex")).toBe(fixture.undo.key_hex);
    const encoded = encodeUndo([
      {
        txidInternal,
        vout: fixture.utxo.vout,
        height: fixture.utxo.height,
        valueSats: BigInt(fixture.utxo.value_sats),
        scriptPubkey,
        coinbase: fixture.utxo.coinbase,
      },
    ]);
    expect(encoded.toString("hex")).toBe(fixture.undo.value_hex);
    expect(decodeUndo(encoded)).toEqual([
      {
        txidInternal,
        vout: fixture.utxo.vout,
        height: fixture.utxo.height,
        valueSats: BigInt(fixture.utxo.value_sats),
        scriptPubkey,
        coinbase: fixture.utxo.coinbase,
      },
    ]);
  });

  it("matches tip vectors", () => {
    expect(tipKey(fixture.chain).toString("hex")).toBe(fixture.tip.key_hex);
    const encoded = encodeTip({ height: fixture.tip.height, blockHashInternal });
    expect(encoded.toString("hex")).toBe(fixture.tip.value_hex);
    expect(decodeTip(encoded)).toEqual({ height: fixture.tip.height, blockHashInternal });
  });

  it("matches block index vectors", () => {
    expect(blockIndexKey(fixture.chain, fixture.block_index.height).toString("hex")).toBe(
      fixture.block_index.key_hex,
    );
    const encoded = encodeBlockIndex({
      blockHashInternal,
      fileNumber: fixture.block_index.file_number,
      fileOffset: fixture.block_index.file_offset,
      blockSize: fixture.block_index.block_size,
    });
    expect(encoded.toString("hex")).toBe(fixture.block_index.value_hex);
    expect(decodeBlockIndex(encoded)).toEqual({
      blockHashInternal,
      fileNumber: fixture.block_index.file_number,
      fileOffset: fixture.block_index.file_offset,
      blockSize: fixture.block_index.block_size,
    });
  });

  it("matches header vectors", () => {
    expect(headerKey(fixture.chain, fixture.header.height).toString("hex")).toBe(
      fixture.header.key_hex,
    );
    const encoded = encodeHeader(Buffer.from(fixture.header.serialized_header_hex, "hex"));
    expect(encoded.toString("hex")).toBe(fixture.header.value_hex);
    expect(decodeHeader(encoded).toString("hex")).toBe(fixture.header.serialized_header_hex);
  });

  it("matches metadata vectors", () => {
    expect(metadataKey(fixture.metadata.name).toString("hex")).toBe(fixture.metadata.key_hex);
    const encoded = metadataValue(fixture.metadata.value);
    expect(encoded.toString("hex")).toBe(fixture.metadata.value_hex);
    expect(decodeMetadataValue(encoded)).toBe(fixture.metadata.value);
  });
});
