import { readCompactSize, writeCompactSize } from "../wire/serialize.js";

export const REJECT_MALFORMED = 0x01;
export const REJECT_INVALID = 0x10;
export const REJECT_OBSOLETE = 0x11;
export const REJECT_DUPLICATE = 0x12;
export const REJECT_NONSTANDARD = 0x40;
export const REJECT_DUST = 0x41;
export const REJECT_INSUFFICIENTFEE = 0x42;

function readCompactString(payload: Buffer, offset: number): [Buffer, number] {
  const [length, next] = readCompactSize(payload, offset);
  const end = next + length;
  if (end > payload.length) {
    throw new Error("truncated compact-string in reject");
  }
  return [payload.subarray(next, end), end];
}

function writeCompactString(data: Buffer): Buffer {
  return Buffer.concat([writeCompactSize(data.length), data]);
}

export interface RejectMessage {
  message: string;
  ccode: number;
  reason: string;
  data: Buffer;
}

export class RejectMessageCodec {
  static readonly COMMAND = "reject";

  static serialize(message: RejectMessage): Buffer {
    const messageBytes = Buffer.from(message.message, "ascii");
    const reasonBytes = Buffer.from(message.reason, "utf8");
    if (message.ccode < 0 || message.ccode > 0xff) {
      throw new Error("ccode out of uint8 range");
    }
    return Buffer.concat([
      writeCompactString(messageBytes),
      Buffer.from([message.ccode]),
      writeCompactString(reasonBytes),
      message.data,
    ]);
  }

  static deserialize(payload: Buffer): RejectMessage {
    if (payload.length === 0) {
      throw new Error("empty reject payload");
    }
    let offset = 0;
    const [messageRaw, afterMessage] = readCompactString(payload, offset);
    offset = afterMessage;
    if (offset >= payload.length) {
      throw new Error("truncated reject (missing code)");
    }
    const ccode = payload[offset]!;
    offset += 1;
    const [reasonRaw, afterReason] = readCompactString(payload, offset);
    return {
      message: messageRaw.toString("ascii"),
      ccode,
      reason: reasonRaw.toString("utf8"),
      data: payload.subarray(afterReason),
    };
  }
}
