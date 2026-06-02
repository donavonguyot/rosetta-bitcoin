import { createServer, type Server, type Socket } from "node:net";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";

import { TESTNET4 } from "../src/chain/params.js";
import { Settings } from "../src/config/settings.js";
import { ProjectTracker } from "../src/db/tracker.js";
import {
  buildVersionMessage,
  deserializeVersion,
  NODE_NETWORK,
  NODE_WITNESS,
  serializeSendHeaders,
  serializeVerAck,
  serializeVersion,
  VERACK_COMMAND,
  VERSION_COMMAND,
} from "../src/messages/handshake.js";
import { PeerConnection } from "../src/p2p/peer.js";
import { buildMessage, HEADER_SIZE, parseHeader, verifyChecksum } from "../src/wire/frame.js";

async function readFrame(socket: Socket): Promise<[string, Buffer]> {
  let buffer = Buffer.alloc(0);
  while (true) {
    if (buffer.length >= HEADER_SIZE) {
      const header = parseHeader(buffer.subarray(0, HEADER_SIZE));
      const total = HEADER_SIZE + header.length;
      if (buffer.length >= total) {
        const frame = buffer.subarray(0, total);
        const payload = frame.subarray(HEADER_SIZE);
        if (!verifyChecksum(payload, header.checksum)) {
          throw new Error(`bad checksum for ${header.command}`);
        }
        return [header.command, payload];
      }
    }
    const chunk = await new Promise<Buffer>((resolve, reject) => {
      socket.once("data", resolve);
      socket.once("error", reject);
    });
    buffer = Buffer.concat([buffer, chunk]);
  }
}

async function writeFrame(socket: Socket, command: string, payload: Buffer): Promise<void> {
  const frame = buildMessage(TESTNET4.magic, command, payload);
  await new Promise<void>((resolve, reject) => {
    socket.write(frame, (error) => (error ? reject(error) : resolve()));
  });
}

function startMockPeer(): Promise<{ server: Server; port: number }> {
  return new Promise((resolve, reject) => {
    const server = createServer((socket) => {
      void (async () => {
        const [command, payload] = await readFrame(socket);
        expect(command).toBe(VERSION_COMMAND);
        const peerVersion = deserializeVersion(payload);
        expect(peerVersion.version).toBe(70_016);

        const reply = buildVersionMessage({
          protocolVersion: 70_016,
          services: BigInt(NODE_NETWORK | NODE_WITNESS),
          addrRecv: peerVersion.addrRecv,
          addrFrom: peerVersion.addrFrom,
          userAgent: "/mock-peer:0.1.0/",
          startHeight: 42,
        });
        await writeFrame(socket, VERSION_COMMAND, serializeVersion(reply));

        const [verackCommand] = await readFrame(socket);
        expect(verackCommand).toBe(VERACK_COMMAND);
        await writeFrame(socket, VERACK_COMMAND, serializeVerAck());

        const [sendheadersCommand] = await readFrame(socket);
        expect(sendheadersCommand).toBe("sendheaders");
        expect(serializeSendHeaders().length).toBe(0);
      })().catch(() => socket.destroy());
    });
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      if (!address || typeof address === "string") {
        reject(new Error("failed to bind mock peer"));
        return;
      }
      resolve({ server, port: address.port });
    });
  });
}

describe("PeerConnection handshake", () => {
  let tempDir = "";
  let mock: { server: Server; port: number } | null = null;

  afterEach(async () => {
    if (mock) {
      await new Promise<void>((resolve) => mock!.server.close(() => resolve()));
      mock = null;
    }
    if (tempDir) {
      rmSync(tempDir, { recursive: true, force: true });
      tempDir = "";
    }
  });

  it("completes outbound version/verack/sendheaders against a mock peer", async () => {
    mock = await startMockPeer();
    tempDir = mkdtempSync(join(tmpdir(), "tsbitnode-peer-"));
    const tracker = new ProjectTracker(join(tempDir, "peer.db"));
    const settings = Settings.fromEnv({ userAgent: "/tsbitnode:0.1.0/" });

    const peer = new PeerConnection({
      host: "127.0.0.1",
      port: mock.port,
      chain: TESTNET4,
      tracker,
      protocolVersion: 70_016,
      userAgent: settings.userAgent,
      settings,
    });

    await peer.connect();
    expect(peer.isConnected).toBe(true);
    expect(peer.remoteVersion?.userAgent).toBe("/mock-peer:0.1.0/");
    expect(peer.remoteVersion?.startHeight).toBe(42);
    expect(tracker.connectedPeerCount()).toBe(1);

    await peer.close();
    tracker.close();
  });

  it("defers feefilter and mempool until completeDeferredHandshake", async () => {
    mock = await startMockPeer();
    tempDir = mkdtempSync(join(tmpdir(), "tsbitnode-peer-defer-"));
    const tracker = new ProjectTracker(join(tempDir, "peer-defer.db"));
    const settings = Settings.fromEnv({ userAgent: "/tsbitnode:0.1.0/" });

    const peer = new PeerConnection({
      host: "127.0.0.1",
      port: mock.port,
      chain: TESTNET4,
      tracker,
      protocolVersion: 70_016,
      userAgent: settings.userAgent,
      settings,
    });
    const sendSpy = vi.spyOn(peer, "send");

    await peer.connect();
    const initialCommands = sendSpy.mock.calls.map(([command]) => command);
    expect(initialCommands).toEqual([VERSION_COMMAND, VERACK_COMMAND, "sendheaders"]);
    expect(initialCommands).not.toContain("feefilter");
    expect(initialCommands).not.toContain("mempool");

    tracker.upsertSyncState(TESTNET4.name, { syncStatus: "headers_current" });
    await peer.completeDeferredHandshake();
    const allCommands = sendSpy.mock.calls.map(([command]) => command);
    expect(allCommands).toContain("feefilter");
    expect(allCommands).toContain("mempool");

    await peer.close();
    tracker.close();
  });
});
