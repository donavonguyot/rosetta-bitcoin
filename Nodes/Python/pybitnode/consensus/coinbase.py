from __future__ import annotations

from pybitnode.messages.transaction import Transaction


class CoinbaseError(ValueError):
    pass


def decode_bip34_height(script_sig: bytes) -> int | None:
    if not script_sig:
        return None
    offset = 0
    opcode = script_sig[offset]
    if opcode == 0:
        return 0
    if 0x51 <= opcode <= 0x60:
        return opcode - 0x50
    if 1 <= opcode <= 75:
        offset += 1
        data = script_sig[offset : offset + opcode]
        if not data:
            return None
        return int.from_bytes(data, "little")
    return None


def validate_bip34_height(coinbase: Transaction, height: int) -> None:
    if height == 0:
        return
    encoded = decode_bip34_height(coinbase.inputs[0].script_sig)
    if encoded != height:
        raise CoinbaseError(
            f"BIP34 height mismatch: expected {height}, got {encoded!r} in coinbase scriptSig"
        )


def is_op_return(script_pubkey: bytes) -> bool:
    return len(script_pubkey) >= 1 and script_pubkey[0] == 0x6A


def is_spendable_output(script_pubkey: bytes) -> bool:
    return bool(script_pubkey) and not is_op_return(script_pubkey)
