from __future__ import annotations

from pybitnode.messages.headers import BlockHeader

# testnet4 genesis from Bitcoin Core v29 chainparams.cpp
TESTNET4_GENESIS = BlockHeader(
    version=1,
    prev_block=b"\x00" * 32,
    merkle_root=bytes.fromhex("7aa0a7ae1e223414cb807e40cd57e667b718e42aaf9306db9102fe28912b7b4e")[::-1],
    timestamp=1714777860,
    bits=0x1D00FFFF,
    nonce=393743547,
)

REGTEST_GENESIS = BlockHeader(
    version=1,
    prev_block=b"\x00" * 32,
    merkle_root=bytes.fromhex("4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77a4cbf3bf478902f9c")[::-1],
    timestamp=1296688602,
    bits=0x207FFFFF,
    nonce=2,
)


def genesis_header_for(chain_name: str) -> BlockHeader:
    if chain_name == "testnet4":
        return TESTNET4_GENESIS
    if chain_name == "regtest":
        return REGTEST_GENESIS
    raise ValueError(f"No genesis header defined for chain {chain_name!r}")
