import type { Settings } from "../config/settings.js";
import { packUint64Le, unpackUint64Le } from "../wire/serialize.js";

/** BIP133 feefilter: minimum fee rate in satoshis per 1000 virtual bytes (sat/kvB). */
export class FeeFilterMessageCodec {
  static readonly COMMAND = "feefilter";

  static serialize(feerateSatKvb: number): Buffer {
    const value = BigInt(Math.max(0, Math.trunc(feerateSatKvb))) & ((1n << 64n) - 1n);
    return packUint64Le(value);
  }

  static deserialize(payload: Buffer): number {
    if (payload.length !== 8) {
      throw new Error(`feefilter expects 8 bytes, got ${payload.length}`);
    }
    const [value] = unpackUint64Le(payload, 0);
    return Number(value);
  }
}

export function feefilterWireSatKvbFromSettings(settings: Settings): number {
  return Math.max(0, settings.minRelayFeerateSatVb) * 1000;
}

export const FEEFILTER_MIN_VERSION = 70_013;
