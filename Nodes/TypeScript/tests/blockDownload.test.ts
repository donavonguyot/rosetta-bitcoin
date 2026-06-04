import { createServer, type Server, type Socket } from "node:net";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";

import { TESTNET4 } from "../src/chain/params.js";
import { Settings } from "../src/config/settings.js";
import { NativeNodeState } from "../src/runtime/nodeState.js";
import {
  buildVersionMessage,
  deserializeVersion,
  NODE_NETWORK,
  NODE_WITNESS,
  serializeVerAck,
  serializeVersion,
  VERACK_COMMAND,
  VERSION_COMMAND,
} from "../src/messages/handshake.js";
import { BlockHeaderCodec } from "../src/messages/headers.js";
import { GetDataMessageCodec } from "../src/messages/inventory.js";
import { BlockMessageCodec } from "../src/messages/block.js";
import { PeerConnection } from "../src/p2p/peer.js";
import { buildMessage, HEADER_SIZE, parseHeader, verifyChecksum } from "../src/wire/frame.js";

function createFrameReader(socket: Socket) {
  let buffer = Buffer.alloc(0);
  return async function readFrame(): Promise<[string, Buffer]> {
    while (true) {
      if (buffer.length >= HEADER_SIZE) {
        const header = parseHeader(buffer.subarray(0, HEADER_SIZE));
        const total = HEADER_SIZE + header.length;
        if (buffer.length >= total) {
          const frame = buffer.subarray(0, total);
          buffer = buffer.subarray(total);
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
  };
}

async function writeFrame(socket: Socket, command: string, payload: Buffer): Promise<void> {
  const frame = buildMessage(TESTNET4.magic, command, payload);
  await new Promise<void>((resolve, reject) => {
    socket.write(frame, (error) => (error ? reject(error) : resolve()));
  });
}

function syntheticBlockPayload(prevHashHex: string): Buffer {
  const header = {
    version: 1,
    prevBlock: Buffer.from(prevHashHex, "hex").reverse(),
    merkleRoot: Buffer.alloc(32, 0x11),
    timestamp: 1_714_777_861,
    bits: 0x1d00ffff,
    nonce: 1,
  };
  const headerBytes = BlockHeaderCodec.serialize(header);
  return Buffer.concat([headerBytes, Buffer.from([1, 0])]);
}

function startBlockServingPeer(blockPayload: Buffer): Promise<{ server: Server; port: number }> {
  return new Promise((resolve, reject) => {
    const server = createServer((socket) => {
      void (async () => {
        const readFrame = createFrameReader(socket);
        const [command, payload] = await readFrame();
        if (command !== VERSION_COMMAND) {
          throw new Error(`expected version, got ${command}`);
        }
        const peerVersion = deserializeVersion(payload);
        const reply = buildVersionMessage({
          protocolVersion: 70_016,
          services: BigInt(NODE_NETWORK | NODE_WITNESS),
          addrRecv: peerVersion.addrRecv,
          addrFrom: peerVersion.addrFrom,
          userAgent: "/mock-block-peer:0.1.0/",
          startHeight: 42,
        });
        await writeFrame(socket, VERSION_COMMAND, serializeVersion(reply));

        while (true) {
          const [nextCommand] = await readFrame();
          if (nextCommand === VERACK_COMMAND) {
            await writeFrame(socket, VERACK_COMMAND, serializeVerAck());
            continue;
          }
          if (nextCommand === "sendheaders") {
            continue;
          }
          if (nextCommand === GetDataMessageCodec.COMMAND) {
            await writeFrame(socket, BlockMessageCodec.COMMAND, blockPayload);
            return;
          }
        }
      })().catch((error) => {
        socket.destroy(error instanceof Error ? error : undefined);
      });
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

describe("PeerConnection block download", () => {
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

  it("downloads a block via getdata/block", async () => {
    const blockPayload = syntheticBlockPayload(TESTNET4.genesisHash);
    mock = await startBlockServingPeer(blockPayload);
    tempDir = mkdtempSync(join(tmpdir(), "tsbitnode-block-peer-"));
    const tracker = new NativeNodeState(join(tempDir, "peer.stateDir"));
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
    const blockHash = BlockHeaderCodec.blockHash(BlockHeaderCodec.deserialize(blockPayload, 0)[0]);
    const downloaded = await peer.requestBlock(blockHash, 10);
    expect(downloaded?.equals(blockPayload)).toBe(true);
    expect(tracker.wireCapabilityMap()["blocks.getdata.send"]).toBe(1);
    expect(tracker.wireCapabilityMap()["blocks.block.recv"]).toBe(1);

    await peer.close();
    tracker.close();
  });
});
