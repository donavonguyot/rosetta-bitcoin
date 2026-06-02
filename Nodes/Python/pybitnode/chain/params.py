from __future__ import annotations

from dataclasses import dataclass

from pybitnode.chain.genesis import REGTEST_GENESIS, TESTNET4_GENESIS


@dataclass(frozen=True)
class ChainParams:
    name: str
    magic: bytes  # 4-byte network magic (message start)
    default_port: int
    genesis_hash: str
    dns_seeds: tuple[str, ...]
    protocol_version: int = 70016


TESTNET4 = ChainParams(
    name="testnet4",
    magic=bytes.fromhex("1c163f28"),
    default_port=48333,
    genesis_hash=TESTNET4_GENESIS.block_hash_hex(),
    dns_seeds=(
        "seed.testnet4.bitcoin.sprovoost.nl",
        "seed.testnet4.wiz.biz",
    ),
)

REGTEST = ChainParams(
    name="regtest",
    magic=bytes.fromhex("fabfb5da"),
    default_port=18444,
    genesis_hash=REGTEST_GENESIS.block_hash_hex(),
    dns_seeds=(),
)

CHAINS: dict[str, ChainParams] = {
    "testnet4": TESTNET4,
    "regtest": REGTEST,
}


def get_chain(name: str) -> ChainParams:
    key = name.lower()
    if key not in CHAINS:
        raise ValueError(f"Unknown chain {name!r}; choose from {sorted(CHAINS)}")
    return CHAINS[key]
