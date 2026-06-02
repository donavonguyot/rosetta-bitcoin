import { messageChecksum } from "./serialize.js";

export const HEADER_SIZE = 24;

export interface MessageHeader {
  magic: Buffer;
  command: string;
  length: number;
  checksum: Buffer;
}

export function parseHeader(data: Buffer): MessageHeader {
  if (data.length < HEADER_SIZE) {
    throw new Error(`header requires ${HEADER_SIZE} bytes, got ${data.length}`);
  }
  const magic = data.subarray(0, 4);
  const command = data.subarray(4, 16).toString("ascii").replace(/\0+$/, "");
  const length = data.readUInt32LE(16);
  const checksum = data.subarray(20, 24);
  return { magic, command, length, checksum };
}

export function headerToBytes(header: MessageHeader): Buffer {
  const buf = Buffer.allocUnsafe(HEADER_SIZE);
  header.magic.copy(buf, 0);
  const cmd = Buffer.alloc(12, 0);
  cmd.write(header.command.slice(0, 12), 0, "ascii");
  cmd.copy(buf, 4);
  buf.writeUInt32LE(header.length, 16);
  header.checksum.copy(buf, 20);
  return buf;
}

export function buildMessage(magic: Buffer, command: string, payload: Buffer): Buffer {
  const header = headerToBytes({
    magic,
    command,
    length: payload.length,
    checksum: messageChecksum(payload),
  });
  return Buffer.concat([header, payload]);
}

export function verifyChecksum(payload: Buffer, checksum: Buffer): boolean {
  return messageChecksum(payload).equals(checksum);
}
