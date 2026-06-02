import { REGTEST_GENESIS, TESTNET4_GENESIS } from "./genesis.js";
import { blockHeaderHashHex } from "../consensus/hash.js";

export interface ChainParams {
  readonly name: string;
  /** 4-byte network magic (message start). */
  readonly magic: Buffer;
  readonly defaultPort: number;
  readonly genesisHash: string;
  readonly dnsSeeds: readonly string[];
  readonly protocolVersion: number;
}

export const TESTNET4: ChainParams = {
  name: "testnet4",
  magic: Buffer.from("1c163f28", "hex"),
  defaultPort: 48_333,
  genesisHash: blockHeaderHashHex(TESTNET4_GENESIS),
  dnsSeeds: ["seed.testnet4.bitcoin.sprovoost.nl", "seed.testnet4.wiz.biz"],
  protocolVersion: 70_016,
};

export const REGTEST: ChainParams = {
  name: "regtest",
  magic: Buffer.from("fabfb5da", "hex"),
  defaultPort: 18_444,
  genesisHash: blockHeaderHashHex(REGTEST_GENESIS),
  dnsSeeds: [],
  protocolVersion: 70_016,
};

export const CHAINS: Readonly<Record<string, ChainParams>> = {
  testnet4: TESTNET4,
  regtest: REGTEST,
};

export function getChain(name: string): ChainParams {
  const key = name.toLowerCase();
  const chain = CHAINS[key];
  if (!chain) {
    throw new Error(`Unknown chain ${name}; choose from ${Object.keys(CHAINS).sort().join(", ")}`);
  }
  return chain;
}
