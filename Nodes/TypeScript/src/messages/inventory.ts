import { readCompactSize, writeCompactSize } from "../wire/serialize.js";

export const MSG_TX = 1;
export const MSG_BLOCK = 2;
export const MSG_WITNESS_TX = MSG_TX | (1 << 30);
export const MSG_WITNESS_BLOCK = MSG_BLOCK | (1 << 30);

export const BLOCK_INVENTORY_TYPES = new Set<number>([MSG_BLOCK, MSG_WITNESS_BLOCK]);
export const TX_INVENTORY_TYPES = new Set<number>([MSG_TX, MSG_WITNESS_TX]);

export interface InventoryVector {
  type: number;
  hash: Buffer;
}

export interface InvMessage {
  inventory: InventoryVector[];
}

export class InventoryVectorCodec {
  static serialize(item: InventoryVector): Buffer {
    if (item.hash.length !== 32) {
      throw new Error("inventory hash must be 32 bytes");
    }
    const buf = Buffer.allocUnsafe(36);
    buf.writeUInt32LE(item.type >>> 0, 0);
    item.hash.copy(buf, 4);
    return buf;
  }

  static deserialize(data: Buffer, offset = 0): [InventoryVector, number] {
    const type = data.readUInt32LE(offset);
    const hash = data.subarray(offset + 4, offset + 36);
    return [{ type, hash }, offset + 36];
  }
}

export class InvMessageCodec {
  static readonly COMMAND = "inv";

  static serialize(message: InvMessage): Buffer {
    const parts = [writeCompactSize(message.inventory.length)];
    for (const item of message.inventory) {
      parts.push(InventoryVectorCodec.serialize(item));
    }
    return Buffer.concat(parts);
  }

  static deserialize(payload: Buffer): InvMessage {
    const [count, offset] = readCompactSize(payload, 0);
    const inventory: InventoryVector[] = [];
    let next = offset;
    for (let index = 0; index < count; index += 1) {
      const [item, after] = InventoryVectorCodec.deserialize(payload, next);
      inventory.push(item);
      next = after;
    }
    return { inventory };
  }
}

export class GetDataMessageCodec {
  static readonly COMMAND = "getdata";

  static serialize(message: InvMessage): Buffer {
    return InvMessageCodec.serialize(message);
  }

  static deserialize(payload: Buffer): InvMessage {
    return InvMessageCodec.deserialize(payload);
  }
}

export class NotFoundMessageCodec {
  static readonly COMMAND = "notfound";

  static serialize(message: InvMessage): Buffer {
    return InvMessageCodec.serialize(message);
  }

  static deserialize(payload: Buffer): InvMessage {
    return InvMessageCodec.deserialize(payload);
  }
}

export function hasBlockInventory(message: InvMessage): boolean {
  return message.inventory.some((item) => BLOCK_INVENTORY_TYPES.has(item.type));
}

export function hasTransactionInventory(message: InvMessage): boolean {
  return message.inventory.some((item) => TX_INVENTORY_TYPES.has(item.type));
}

export function blockInventoryHashes(message: InvMessage): Buffer[] {
  return message.inventory
    .filter((item) => BLOCK_INVENTORY_TYPES.has(item.type))
    .map((item) => item.hash);
}
