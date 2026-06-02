/** BIP35 mempool request — empty payload; peers reply with inv vectors. */
export class MempoolRequestMessageCodec {
  static readonly COMMAND = "mempool";

  static serialize(): Buffer {
    return Buffer.alloc(0);
  }
}
