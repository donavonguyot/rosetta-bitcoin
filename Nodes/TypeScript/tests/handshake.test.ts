import { describe, expect, it } from "vitest";

import { TESTNET4 } from "../src/chain/params.js";
import {
  buildVersionMessage,
  deserializeVersion,
  NODE_NETWORK,
  NODE_WITNESS,
  SENDHEADERS_COMMAND,
  serializeSendHeaders,
  serializeVerAck,
  serializeVersion,
  VERACK_COMMAND,
  VERSION_COMMAND,
  type NetworkAddress,
} from "../src/messages/handshake.js";
import { buildMessage, HEADER_SIZE, parseHeader, verifyChecksum } from "../src/wire/frame.js";

describe("handshake messages", () => {
  const addr: NetworkAddress = {
    services: BigInt(NODE_NETWORK | NODE_WITNESS),
    ip: "127.0.0.1",
    port: 48_333,
  };

  it("round-trips version message serialization", () => {
    const version = buildVersionMessage({
      protocolVersion: 70_016,
      services: BigInt(NODE_NETWORK | NODE_WITNESS),
      addrRecv: addr,
      addrFrom: addr,
      userAgent: "/tsbitnode:0.1.0/",
      startHeight: 0,
    });
    const payload = serializeVersion(version);
    const restored = deserializeVersion(payload);
    expect(restored.version).toBe(70_016);
    expect(restored.userAgent).toBe("/tsbitnode:0.1.0/");
    expect(restored.startHeight).toBe(0);
    expect(restored.addrRecv.ip).toBe("127.0.0.1");
    expect(restored.addrRecv.port).toBe(48_333);
    expect(restored.relay).toBe(true);
  });

  it("frames handshake messages with empty payloads", () => {
    const verack = buildMessage(TESTNET4.magic, VERACK_COMMAND, serializeVerAck());
    const verackHeader = parseHeader(verack.subarray(0, HEADER_SIZE));
    expect(verackHeader.command).toBe("verack");
    expect(verackHeader.length).toBe(0);
    expect(verifyChecksum(Buffer.alloc(0), verackHeader.checksum)).toBe(true);

    const sendheaders = buildMessage(
      TESTNET4.magic,
      SENDHEADERS_COMMAND,
      serializeSendHeaders(),
    );
    const sendheadersHeader = parseHeader(sendheaders.subarray(0, HEADER_SIZE));
    expect(sendheadersHeader.command).toBe("sendheaders");
    expect(sendheadersHeader.length).toBe(0);
  });

  it("frames version payload with checksum", () => {
    const version = buildVersionMessage({
      protocolVersion: 70_016,
      services: BigInt(NODE_NETWORK | NODE_WITNESS),
      addrRecv: addr,
      addrFrom: addr,
      userAgent: "/tsbitnode:0.1.0/",
    });
    const payload = serializeVersion(version);
    const frame = buildMessage(TESTNET4.magic, VERSION_COMMAND, payload);
    const header = parseHeader(frame.subarray(0, HEADER_SIZE));
    const body = frame.subarray(HEADER_SIZE);
    expect(header.command).toBe("version");
    expect(header.length).toBe(payload.length);
    expect(verifyChecksum(body, header.checksum)).toBe(true);
    expect(deserializeVersion(body).version).toBe(70_016);
  });
});
