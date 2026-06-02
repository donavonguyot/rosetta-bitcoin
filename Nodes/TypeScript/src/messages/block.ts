import { BlockHeaderCodec } from "./headers.js";

export class BlockMessageCodec {
  static readonly COMMAND = "block";

  static serialize(payload: Buffer): Buffer {
    return payload;
  }

  static deserialize(payload: Buffer): Buffer {
    return payload;
  }
}

export function blockHashFromPayload(payload: Buffer): Buffer {
  const [header] = BlockHeaderCodec.deserialize(payload, 0);
  return BlockHeaderCodec.blockHash(header);
}

export function blockHashHexFromPayload(payload: Buffer): string {
  return Buffer.from(blockHashFromPayload(payload)).reverse().toString("hex");
}
