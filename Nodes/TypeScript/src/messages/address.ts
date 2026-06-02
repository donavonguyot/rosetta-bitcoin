import {
  deserializeNetworkAddress,
  serializeNetworkAddress,
  type NetworkAddress,
} from "./handshake.js";
import { readCompactSize, writeCompactSize } from "../wire/serialize.js";

export const GETADDR_COMMAND = "getaddr";
export const ADDR_COMMAND = "addr";

export interface AddrMessage {
  addresses: NetworkAddress[];
}

export class GetAddrMessageCodec {
  static readonly COMMAND = GETADDR_COMMAND;

  static serialize(): Buffer {
    return Buffer.alloc(0);
  }
}

export class AddrMessageCodec {
  static readonly COMMAND = ADDR_COMMAND;

  static serialize(message: AddrMessage): Buffer {
    const parts: Buffer[] = [writeCompactSize(message.addresses.length)];
    for (const address of message.addresses) {
      parts.push(serializeNetworkAddress(address, true));
    }
    return Buffer.concat(parts);
  }

  static deserialize(payload: Buffer): AddrMessage {
    const addresses: NetworkAddress[] = [];
    let offset = 0;
    const [count, nextOffset] = readCompactSize(payload, offset);
    offset = nextOffset;
    for (let index = 0; index < count; index++) {
      try {
        const [address, newOffset] = deserializeNetworkAddress(payload, offset, true);
        addresses.push(address);
        offset = newOffset;
      } catch {
        break;
      }
    }
    return { addresses };
  }
}
