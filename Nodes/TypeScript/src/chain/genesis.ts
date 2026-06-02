import type { BlockHeader } from "../types/index.js";

/** testnet4 genesis from Bitcoin Core v29 chainparams.cpp */
export const TESTNET4_GENESIS: BlockHeader = {
  version: 1,
  prevBlock: Buffer.alloc(32, 0),
  merkleRoot: Buffer.from(
    "7aa0a7ae1e223414cb807e40cd57e667b718e42aaf9306db9102fe28912b7b4e",
    "hex",
  ).reverse(),
  timestamp: 1_714_777_860,
  bits: 0x1d00ffff,
  nonce: 393_743_547,
};

/** regtest genesis from Bitcoin Core chainparams */
export const REGTEST_GENESIS: BlockHeader = {
  version: 1,
  prevBlock: Buffer.alloc(32, 0),
  merkleRoot: Buffer.from(
    "4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77a4cbf3bf478902f9c",
    "hex",
  ).reverse(),
  timestamp: 1_296_688_602,
  bits: 0x207fffff,
  nonce: 2,
};

export function genesisHeaderFor(chainName: string): BlockHeader {
  const key = chainName.toLowerCase();
  if (key === "testnet4") return TESTNET4_GENESIS;
  if (key === "regtest") return REGTEST_GENESIS;
  throw new Error(`No genesis header defined for chain ${chainName}`);
}
