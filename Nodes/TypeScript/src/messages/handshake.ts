import { randomBytes } from "node:crypto";

import {
  packInt32Le,
  packInt64Le,
  packUint64Le,
  unpackInt32Le,
  unpackInt64Le,
  unpackUint32Le,
  unpackUint64Le,
} from "../wire/serialize.js";

/** Bitcoin P2P service flags (subset used in Phase 0). */
export const NODE_NETWORK = 1 << 0;
export const NODE_WITNESS = 1 << 3;

export interface NetworkAddress {
  services: bigint;
  ip: string;
  port: number;
}

export interface VersionMessage {
  version: number;
  services: bigint;
  timestamp: bigint;
  addrRecv: NetworkAddress;
  addrFrom: NetworkAddress;
  nonce: bigint;
  userAgent: string;
  startHeight: number;
  relay: boolean;
}

export const VERSION_COMMAND = "version";
export const VERACK_COMMAND = "verack";
export const SENDHEADERS_COMMAND = "sendheaders";
export const PING_COMMAND = "ping";
export const PONG_COMMAND = "pong";

function packUint16Be(value: number): Buffer {
  const buf = Buffer.allocUnsafe(2);
  buf.writeUInt16BE(value, 0);
  return buf;
}

function unpackUint16Be(data: Buffer, offset = 0): [number, number] {
  return [data.readUInt16BE(offset), offset + 2];
}

function ipToBytes(ip: string): Buffer {
  if (ip.includes(":")) {
    const groups = ip.split(":");
    const buf = Buffer.alloc(16);
    let offset = 0;
    let emptyIndex = -1;
    for (let i = 0; i < groups.length; i++) {
      const group = groups[i] ?? "";
      if (group === "") {
        emptyIndex = i;
        break;
      }
      buf.writeUInt16BE(Number.parseInt(group, 16), offset);
      offset += 2;
    }
    if (emptyIndex >= 0) {
      const tailGroups = groups.slice(emptyIndex + 1).filter((g) => g !== "");
      const zeros = 16 - offset - tailGroups.length * 2;
      offset += zeros;
      for (const group of tailGroups) {
        buf.writeUInt16BE(Number.parseInt(group, 16), offset);
        offset += 2;
      }
    }
    return buf;
  }

  const parts = ip.split(".").map((part) => Number.parseInt(part, 10));
  if (parts.length !== 4 || parts.some((part) => !Number.isFinite(part) || part < 0 || part > 255)) {
    throw new Error(`Invalid IPv4 address ${ip}`);
  }
  const mapped = Buffer.alloc(16);
  mapped.fill(0xff, 0, 10);
  mapped[10] = 0xff;
  mapped[11] = 0xff;
  mapped.writeUInt8(parts[0]!, 12);
  mapped.writeUInt8(parts[1]!, 13);
  mapped.writeUInt8(parts[2]!, 14);
  mapped.writeUInt8(parts[3]!, 15);
  return mapped;
}

function bytesToIp(raw: Buffer): string {
  const ipv4MappedPrefix = Buffer.from([
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
  ]);
  if (raw.length === 16 && raw.subarray(0, 12).equals(ipv4MappedPrefix)) {
    return `${raw[12]}.${raw[13]}.${raw[14]}.${raw[15]}`;
  }
  const parts: string[] = [];
  for (let offset = 0; offset < 16; offset += 2) {
    parts.push(raw.readUInt16BE(offset).toString(16));
  }
  return parts.join(":");
}

export function serializeNetworkAddress(
  address: NetworkAddress,
  withTimestamp = true,
): Buffer {
  const parts: Buffer[] = [];
  if (withTimestamp) {
    parts.push(packInt64Le(BigInt(Math.floor(Date.now() / 1000))));
  }
  parts.push(packUint64Le(address.services));
  parts.push(ipToBytes(address.ip));
  parts.push(packUint16Be(address.port));
  return Buffer.concat(parts);
}

export function deserializeNetworkAddress(
  data: Buffer,
  offset = 0,
  withTimestamp = true,
): [NetworkAddress, number] {
  const required = (withTimestamp ? 8 : 0) + 8 + 16 + 2;
  if (offset + required > data.length) {
    throw new Error("truncated network address");
  }
  if (withTimestamp) {
    [, offset] = unpackInt64Le(data, offset);
  }
  const [services, servicesOffset] = unpackUint64Le(data, offset);
  offset = servicesOffset;
  const ipBytes = data.subarray(offset, offset + 16);
  offset += 16;
  const [port, portOffset] = unpackUint16Be(data, offset);
  return [{ services, ip: bytesToIp(ipBytes), port }, portOffset];
}

export function serializeVersion(message: VersionMessage): Buffer {
  const ua = Buffer.from(message.userAgent, "ascii");
  return Buffer.concat([
    packInt32Le(message.version),
    packUint64Le(message.services),
    packInt64Le(message.timestamp),
    serializeNetworkAddress(message.addrRecv, false),
    serializeNetworkAddress(message.addrFrom, false),
    packUint64Le(message.nonce),
    Buffer.from([ua.length]),
    ua,
    packInt32Le(message.startHeight),
    Buffer.from([message.relay ? 1 : 0]),
  ]);
}

export function deserializeVersion(payload: Buffer): VersionMessage {
  let offset = 0;
  const [version, versionOffset] = unpackInt32Le(payload, offset);
  offset = versionOffset;
  const [services, servicesOffset] = unpackUint64Le(payload, offset);
  offset = servicesOffset;
  const [timestamp, timestampOffset] = unpackInt64Le(payload, offset);
  offset = timestampOffset;
  const [addrRecv, addrRecvOffset] = deserializeNetworkAddress(payload, offset, false);
  offset = addrRecvOffset;
  const [addrFrom, addrFromOffset] = deserializeNetworkAddress(payload, offset, false);
  offset = addrFromOffset;
  const [nonce, nonceOffset] = unpackUint64Le(payload, offset);
  offset = nonceOffset;
  const uaLen = payload[offset];
  if (uaLen === undefined) throw new Error("truncated version user agent length");
  offset += 1;
  const userAgent = payload.subarray(offset, offset + uaLen).toString("ascii");
  offset += uaLen;
  const [startHeight, startHeightOffset] = unpackInt32Le(payload, offset);
  offset = startHeightOffset;
  const relay = offset < payload.length ? payload[offset] !== 0 : true;
  return {
    version,
    services,
    timestamp,
    addrRecv,
    addrFrom,
    nonce,
    userAgent,
    startHeight,
    relay,
  };
}

export function buildVersionMessage(options: {
  protocolVersion: number;
  services: bigint;
  addrRecv: NetworkAddress;
  addrFrom: NetworkAddress;
  userAgent: string;
  startHeight?: number;
  relay?: boolean;
}): VersionMessage {
  return {
    version: options.protocolVersion,
    services: options.services,
    timestamp: BigInt(Math.floor(Date.now() / 1000)),
    addrRecv: options.addrRecv,
    addrFrom: options.addrFrom,
    nonce: randomBytes(8).readBigUInt64LE(0),
    userAgent: options.userAgent,
    startHeight: options.startHeight ?? 0,
    relay: options.relay ?? true,
  };
}

export function serializeVerAck(): Buffer {
  return Buffer.alloc(0);
}

export function serializeSendHeaders(): Buffer {
  return Buffer.alloc(0);
}

export function serializePing(nonce: bigint): Buffer {
  return packUint64Le(nonce);
}

export function deserializePing(payload: Buffer): bigint {
  const [nonce] = unpackUint64Le(payload, 0);
  return nonce;
}

export function serializePong(nonce: bigint): Buffer {
  return packUint64Le(nonce);
}

export function deserializePong(payload: Buffer): bigint {
  const [nonce] = unpackUint64Le(payload, 0);
  return nonce;
}

/** @deprecated Use module-level serialize/deserialize helpers. */
export class HandshakeMessages {
  static readonly VERSION_COMMAND = VERSION_COMMAND;
  static readonly VERACK_COMMAND = VERACK_COMMAND;

  static serializeVersion(message: VersionMessage): Buffer {
    return serializeVersion(message);
  }

  static deserializeVersion(payload: Buffer): VersionMessage {
    return deserializeVersion(payload);
  }
}
