import type { BlockHeader } from "../types/index.js";
import {
  blockHeaderHashHex,
  doubleSha256,
  packInt32Le,
  readCompactSize,
  serializeBlockHeader,
  unpackInt32Le,
  unpackUint32Le,
  writeCompactSize,
} from "../wire/serialize.js";

export const HEADER_SIZE = 80;

export interface HeadersMessage {
  headers: BlockHeader[];
}

export interface GetHeadersMessage {
  version: number;
  locatorHashes: Buffer[];
  hashStop: Buffer;
}

export class BlockHeaderCodec {
  static serialize(header: BlockHeader): Buffer {
    return serializeBlockHeader(header);
  }

  static deserialize(data: Buffer, offset = 0): [BlockHeader, number] {
    const [version, next] = unpackInt32Le(data, offset);
    const prevBlock = data.subarray(next, next + 32);
    const merkleRoot = data.subarray(next + 32, next + 64);
    const [timestamp, afterTimestamp] = unpackUint32Le(data, next + 64);
    const [bits, afterBits] = unpackUint32Le(data, afterTimestamp);
    const [nonce, end] = unpackUint32Le(data, afterBits);
    return [{ version, prevBlock, merkleRoot, timestamp, bits, nonce }, end];
  }

  static blockHash(header: BlockHeader): Buffer {
    return doubleSha256(serializeBlockHeader(header));
  }

  static blockHashHex(header: BlockHeader): string {
    return blockHeaderHashHex(header);
  }
}

export class GetHeadersMessageCodec {
  static readonly COMMAND = "getheaders";

  static serialize(message: GetHeadersMessage): Buffer {
    const parts: Buffer[] = [packInt32Le(message.version), writeCompactSize(message.locatorHashes.length)];
    for (const hash of message.locatorHashes) {
      parts.push(hash);
    }
    parts.push(message.hashStop);
    return Buffer.concat(parts);
  }

  static deserialize(payload: Buffer): GetHeadersMessage {
    const [version, offsetAfterVersion] = unpackInt32Le(payload, 0);
    const [count, offsetAfterCount] = readCompactSize(payload, offsetAfterVersion);
    let offset = offsetAfterCount;
    const locatorHashes: Buffer[] = [];
    for (let index = 0; index < count; index += 1) {
      locatorHashes.push(payload.subarray(offset, offset + 32));
      offset += 32;
    }
    if (offset + 32 !== payload.length) {
      throw new Error("invalid getheaders payload length");
    }
    return {
      version,
      locatorHashes,
      hashStop: payload.subarray(offset, offset + 32),
    };
  }
}

export class HeadersMessageCodec {
  static readonly COMMAND = "headers";

  static serialize(message: HeadersMessage): Buffer {
    const parts: Buffer[] = [writeCompactSize(message.headers.length)];
    for (const header of message.headers) {
      parts.push(BlockHeaderCodec.serialize(header));
      parts.push(Buffer.from([0x00]));
    }
    return Buffer.concat(parts);
  }

  static deserialize(payload: Buffer): HeadersMessage {
    const [count, offsetAfterCount] = readCompactSize(payload, 0);
    let offset = offsetAfterCount;
    const headers: BlockHeader[] = [];
    for (let index = 0; index < count; index += 1) {
      const [header, afterHeader] = BlockHeaderCodec.deserialize(payload, offset);
      offset = afterHeader;
      const [, afterTxCount] = readCompactSize(payload, offset);
      offset = afterTxCount;
      headers.push(header);
    }
    return { headers };
  }
}
