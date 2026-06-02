import { packUint64Le, unpackUint64Le } from "../wire/serialize.js";

/** BIP152 compact block relay version (Core uses 2). */
export const SENDCMPCT_VERSION = 2;

export interface SendCmpctMessage {
  announce: boolean;
  version: number;
}

export class SendCmpctMessageCodec {
  static readonly COMMAND = "sendcmpct";

  static serialize(message: SendCmpctMessage): Buffer {
    return Buffer.concat([Buffer.from([message.announce ? 1 : 0]), packUint64Le(message.version)]);
  }

  static deserialize(payload: Buffer): SendCmpctMessage {
    if (payload.length < 9) {
      throw new Error("sendcmpct payload too short");
    }
    const announce = payload[0] !== 0;
    const [version] = unpackUint64Le(payload, 1);
    if (payload.length !== 9) {
      throw new Error("trailing bytes after sendcmpct");
    }
    return { announce, version: Number(version) };
  }
}
