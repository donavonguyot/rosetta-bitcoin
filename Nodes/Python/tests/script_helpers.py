from __future__ import annotations

from pybitnode.consensus.hash import hash160, sha256_digest
from pybitnode.consensus.script.opcodes import (
    OP_CHECKLOCKTIMEVERIFY,
    OP_CHECKMULTISIG,
    OP_CHECKSEQUENCEVERIFY,
    OP_CHECKSIG,
    OP_DUP,
    OP_EQUAL,
    OP_EQUALVERIFY,
    OP_HASH160,
)
from pybitnode.consensus.script.sighash import bip143_sighash, legacy_sighash
from pybitnode.messages.transaction import OutPoint, Transaction, TxIn, TxOut


def p2pkh_script_pubkey(pubkey_hash: bytes) -> bytes:
    return bytes([OP_DUP, OP_HASH160, 0x14]) + pubkey_hash + bytes([OP_EQUALVERIFY, OP_CHECKSIG])


def p2sh_script_pubkey(script_hash160: bytes) -> bytes:
    return bytes([OP_HASH160, 0x14]) + script_hash160 + bytes([OP_EQUAL])


def p2pk_script_pubkey(pubkey: bytes) -> bytes:
    return push_data(pubkey) + bytes([OP_CHECKSIG])


def push_data(data: bytes) -> bytes:
    if len(data) < 0x4C:
        return bytes([len(data)]) + data
    return bytes([0x4C, len(data)]) + data


def _op_n(value: int) -> int:
    if 1 <= value <= 16:
        return 0x50 + value
    raise ValueError(f"OP_n out of range: {value}")


def push_script_num(value: int) -> bytes:
    """Minimal script-number push for small timelock operands."""
    if value == 0:
        return b"\x00"
    if 1 <= value <= 16:
        return bytes([_op_n(value)])
    encoded = value.to_bytes((value.bit_length() + 7) // 8, "little")
    return push_data(encoded)


def cltv_redeem_script(locktime_value: int, pubkey: bytes) -> bytes:
    """P2SH/P2WSH redeem script: locktime OP_CLTV OP_DROP <pubkey> OP_CHECKSIG."""
    return (
        push_script_num(locktime_value)
        + bytes([OP_CHECKLOCKTIMEVERIFY, 0x75])
        + push_data(pubkey)
        + bytes([OP_CHECKSIG])
    )


def csv_redeem_script(sequence_value: int, pubkey: bytes) -> bytes:
    """P2SH/P2WSH redeem script: sequence OP_CSV OP_DROP <pubkey> OP_CHECKSIG."""
    return (
        push_script_num(sequence_value)
        + bytes([OP_CHECKSEQUENCEVERIFY, 0x75])
        + push_data(pubkey)
        + bytes([OP_CHECKSIG])
    )


def make_signed_p2sh_cltv_spend(
    *,
    private_key: int,
    pubkey: bytes,
    locktime_value: int,
    tx_lock_time: int,
    input_sequence: int,
    prev_txid: bytes,
    prev_vout: int,
    prev_amount: int,
    output_value: int,
) -> tuple[Transaction, bytes]:
    """P2SH spend with CLTV-gated redeem script (BIP65)."""
    from pybitnode.consensus.secp256k1 import sign_der

    redeem_script = cltv_redeem_script(locktime_value, pubkey)
    script_pubkey = p2sh_script_pubkey(hash160(redeem_script))
    unsigned = Transaction(
        version=2,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=prev_txid, index=prev_vout),
                script_sig=b"",
                sequence=input_sequence,
            ),
        ),
        outputs=(TxOut(value=output_value, script_pubkey=b"\x51"),),
        lock_time=tx_lock_time,
    )
    sighash = legacy_sighash(unsigned, 0, redeem_script, sighash_type=1)
    signature = sign_der(private_key, sighash) + bytes([1])
    script_sig = push_data(signature) + push_data(redeem_script)
    signed = Transaction(
        version=unsigned.version,
        inputs=(
            TxIn(
                previous_output=unsigned.inputs[0].previous_output,
                script_sig=script_sig,
                sequence=unsigned.inputs[0].sequence,
            ),
        ),
        outputs=unsigned.outputs,
        lock_time=unsigned.lock_time,
    )
    return signed, script_pubkey


def make_signed_p2wsh_cltv_spend(
    *,
    private_key: int,
    pubkey: bytes,
    locktime_value: int,
    tx_lock_time: int,
    input_sequence: int,
    prev_txid: bytes,
    prev_vout: int,
    prev_amount: int,
    output_value: int,
) -> tuple[Transaction, bytes]:
    """Native v0 P2WSH spend with CLTV-gated witness script (BIP65)."""
    from pybitnode.consensus.secp256k1 import sign_der

    witness_script = cltv_redeem_script(locktime_value, pubkey)
    script_pubkey = bytes([0x00, 0x20]) + sha256_digest(witness_script)
    unsigned = Transaction(
        version=2,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=prev_txid, index=prev_vout),
                script_sig=b"",
                sequence=input_sequence,
            ),
        ),
        outputs=(TxOut(value=output_value, script_pubkey=b"\x51"),),
        lock_time=tx_lock_time,
        witness=((),),
    )
    sighash = bip143_sighash(unsigned, 0, witness_script, amount=prev_amount, sighash_type=1)
    signature = sign_der(private_key, sighash) + bytes([1])
    signed = Transaction(
        version=unsigned.version,
        inputs=unsigned.inputs,
        outputs=unsigned.outputs,
        lock_time=unsigned.lock_time,
        witness=((signature, witness_script),),
    )
    return signed, script_pubkey


def make_signed_p2sh_csv_spend(
    *,
    private_key: int,
    pubkey: bytes,
    csv_operand: int,
    input_sequence: int,
    prev_txid: bytes,
    prev_vout: int,
    prev_amount: int,
    output_value: int,
) -> tuple[Transaction, bytes]:
    """P2SH spend with CSV-gated redeem script (BIP112)."""
    from pybitnode.consensus.secp256k1 import sign_der

    redeem_script = csv_redeem_script(csv_operand, pubkey)
    script_pubkey = p2sh_script_pubkey(hash160(redeem_script))
    unsigned = Transaction(
        version=2,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=prev_txid, index=prev_vout),
                script_sig=b"",
                sequence=input_sequence,
            ),
        ),
        outputs=(TxOut(value=output_value, script_pubkey=b"\x51"),),
        lock_time=0,
    )
    sighash = legacy_sighash(unsigned, 0, redeem_script, sighash_type=1)
    signature = sign_der(private_key, sighash) + bytes([1])
    script_sig = push_data(signature) + push_data(redeem_script)
    signed = Transaction(
        version=unsigned.version,
        inputs=(
            TxIn(
                previous_output=unsigned.inputs[0].previous_output,
                script_sig=script_sig,
                sequence=unsigned.inputs[0].sequence,
            ),
        ),
        outputs=unsigned.outputs,
        lock_time=unsigned.lock_time,
    )
    return signed, script_pubkey


def make_signed_p2wsh_csv_spend(
    *,
    private_key: int,
    pubkey: bytes,
    csv_operand: int,
    input_sequence: int,
    prev_txid: bytes,
    prev_vout: int,
    prev_amount: int,
    output_value: int,
) -> tuple[Transaction, bytes]:
    """Native v0 P2WSH spend with CSV-gated witness script (BIP112)."""
    from pybitnode.consensus.secp256k1 import sign_der

    witness_script = csv_redeem_script(csv_operand, pubkey)
    script_pubkey = bytes([0x00, 0x20]) + sha256_digest(witness_script)
    unsigned = Transaction(
        version=2,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=prev_txid, index=prev_vout),
                script_sig=b"",
                sequence=input_sequence,
            ),
        ),
        outputs=(TxOut(value=output_value, script_pubkey=b"\x51"),),
        lock_time=0,
        witness=((),),
    )
    sighash = bip143_sighash(unsigned, 0, witness_script, amount=prev_amount, sighash_type=1)
    signature = sign_der(private_key, sighash) + bytes([1])
    signed = Transaction(
        version=unsigned.version,
        inputs=unsigned.inputs,
        outputs=unsigned.outputs,
        lock_time=unsigned.lock_time,
        witness=((signature, witness_script),),
    )
    return signed, script_pubkey


def multisig_redeem_script(required: int, pubkeys: tuple[bytes, ...]) -> bytes:
    """Classic m-of-n redeem script ending in OP_CHECKMULTISIG."""
    script = bytes([_op_n(required)])
    for pubkey in pubkeys:
        script += push_data(pubkey)
    script += bytes([_op_n(len(pubkeys)), OP_CHECKMULTISIG])
    return script


def make_signed_p2sh_multisig_spend(
    *,
    private_keys: tuple[int, ...],
    pubkeys: tuple[bytes, ...],
    required: int,
    prev_txid: bytes,
    prev_vout: int,
    prev_amount: int,
    output_value: int,
) -> tuple[Transaction, bytes]:
    """P2SH wrapping an m-of-n multisig redeem script (BIP16 + CHECKMULTISIG dummy)."""
    from pybitnode.consensus.secp256k1 import sign_der

    redeem_script = multisig_redeem_script(required, pubkeys)
    script_pubkey = p2sh_script_pubkey(hash160(redeem_script))
    unsigned = Transaction(
        version=1,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=prev_txid, index=prev_vout),
                script_sig=b"",
                sequence=0xFFFFFFFF,
            ),
        ),
        outputs=(TxOut(value=output_value, script_pubkey=b"\x51"),),
        lock_time=0,
    )
    signatures: list[bytes] = []
    for priv in private_keys[:required]:
        sighash = legacy_sighash(unsigned, 0, redeem_script, sighash_type=1)
        signatures.append(sign_der(priv, sighash) + bytes([1]))
    script_sig = b"\x00" + b"".join(push_data(sig) for sig in signatures) + push_data(redeem_script)
    signed = Transaction(
        version=unsigned.version,
        inputs=(
            TxIn(
                previous_output=unsigned.inputs[0].previous_output,
                script_sig=script_sig,
                sequence=unsigned.inputs[0].sequence,
            ),
        ),
        outputs=unsigned.outputs,
        lock_time=unsigned.lock_time,
    )
    return signed, script_pubkey


def make_signed_p2wsh_multisig_spend(
    *,
    private_keys: tuple[int, ...],
    pubkeys: tuple[bytes, ...],
    required: int,
    prev_txid: bytes,
    prev_vout: int,
    prev_amount: int,
    output_value: int,
) -> tuple[Transaction, bytes]:
    """Native v0 P2WSH m-of-n multisig (witness includes OP_0 dummy + sigs + script)."""
    from pybitnode.consensus.secp256k1 import sign_der

    witness_script = multisig_redeem_script(required, pubkeys)
    script_pubkey = bytes([0x00, 0x20]) + sha256_digest(witness_script)
    unsigned = Transaction(
        version=1,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=prev_txid, index=prev_vout),
                script_sig=b"",
                sequence=0xFFFFFFFF,
            ),
        ),
        outputs=(TxOut(value=output_value, script_pubkey=b"\x51"),),
        lock_time=0,
        witness=((),),
    )
    signatures: list[bytes] = []
    for priv in private_keys[:required]:
        sighash = bip143_sighash(unsigned, 0, witness_script, amount=prev_amount, sighash_type=1)
        signatures.append(sign_der(priv, sighash) + bytes([1]))
    witness_items = (b"", *signatures, witness_script)
    signed = Transaction(
        version=unsigned.version,
        inputs=unsigned.inputs,
        outputs=unsigned.outputs,
        lock_time=unsigned.lock_time,
        witness=(witness_items,),
    )
    return signed, script_pubkey


def build_p2pkh_script_sig(signature: bytes, pubkey: bytes) -> bytes:
    return push_data(signature) + push_data(pubkey)


def make_signed_p2pkh_spend(
    *,
    private_key: int,
    prev_txid: bytes,
    prev_vout: int,
    prev_amount: int,
    pubkey: bytes,
    output_value: int,
    output_script_pubkey: bytes | None = None,
) -> tuple[Transaction, bytes]:
    from pybitnode.consensus.secp256k1 import sign_der

    script_pubkey = p2pkh_script_pubkey(hash160(pubkey))
    out_spk = output_script_pubkey if output_script_pubkey is not None else b"\x51"
    unsigned = Transaction(
        version=1,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=prev_txid, index=prev_vout),
                script_sig=b"",
                sequence=0xFFFFFFFF,
            ),
        ),
        outputs=(TxOut(value=output_value, script_pubkey=out_spk),),
        lock_time=0,
    )
    sighash = legacy_sighash(unsigned, 0, script_pubkey, sighash_type=1)
    signature = sign_der(private_key, sighash) + bytes([1])
    script_sig = build_p2pkh_script_sig(signature, pubkey)
    signed = Transaction(
        version=unsigned.version,
        inputs=(
            TxIn(
                previous_output=unsigned.inputs[0].previous_output,
                script_sig=script_sig,
                sequence=unsigned.inputs[0].sequence,
            ),
        ),
        outputs=unsigned.outputs,
        lock_time=unsigned.lock_time,
    )
    return signed, script_pubkey


def make_signed_p2pk_spend(
    *,
    private_key: int,
    prev_txid: bytes,
    prev_vout: int,
    prev_amount: int,
    pubkey: bytes,
    output_value: int,
) -> tuple[Transaction, bytes]:
    from pybitnode.consensus.secp256k1 import sign_der

    script_pubkey = p2pk_script_pubkey(pubkey)
    unsigned = Transaction(
        version=1,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=prev_txid, index=prev_vout),
                script_sig=b"",
                sequence=0xFFFFFFFF,
            ),
        ),
        outputs=(TxOut(value=output_value, script_pubkey=b"\x51"),),
        lock_time=0,
    )
    sighash = legacy_sighash(unsigned, 0, script_pubkey, sighash_type=1)
    signature = sign_der(private_key, sighash) + bytes([1])
    script_sig = push_data(signature)
    signed = Transaction(
        version=unsigned.version,
        inputs=(
            TxIn(
                previous_output=unsigned.inputs[0].previous_output,
                script_sig=script_sig,
                sequence=unsigned.inputs[0].sequence,
            ),
        ),
        outputs=unsigned.outputs,
        lock_time=unsigned.lock_time,
    )
    return signed, script_pubkey


def make_signed_p2sh_p2pkh_spend(
    *,
    private_key: int,
    prev_txid: bytes,
    prev_vout: int,
    prev_amount: int,
    pubkey: bytes,
    output_value: int,
) -> tuple[Transaction, bytes]:
    """P2SH paying a redeem script that is classic P2PKH."""
    from pybitnode.consensus.secp256k1 import sign_der

    redeem_script = p2pkh_script_pubkey(hash160(pubkey))
    script_pubkey = p2sh_script_pubkey(hash160(redeem_script))
    unsigned = Transaction(
        version=1,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=prev_txid, index=prev_vout),
                script_sig=b"",
                sequence=0xFFFFFFFF,
            ),
        ),
        outputs=(TxOut(value=output_value, script_pubkey=b"\x51"),),
        lock_time=0,
    )
    sighash = legacy_sighash(unsigned, 0, redeem_script, sighash_type=1)
    signature = sign_der(private_key, sighash) + bytes([1])
    script_sig = push_data(signature) + push_data(pubkey) + push_data(redeem_script)
    signed = Transaction(
        version=unsigned.version,
        inputs=(
            TxIn(
                previous_output=unsigned.inputs[0].previous_output,
                script_sig=script_sig,
                sequence=unsigned.inputs[0].sequence,
            ),
        ),
        outputs=unsigned.outputs,
        lock_time=unsigned.lock_time,
    )
    return signed, script_pubkey


def make_signed_p2wsh_p2pkh_spend(
    *,
    private_key: int,
    prev_txid: bytes,
    prev_vout: int,
    prev_amount: int,
    pubkey: bytes,
    output_value: int,
) -> tuple[Transaction, bytes]:
    """Native v0 P2WSH with a P2PKH-shaped witness script."""
    from pybitnode.consensus.secp256k1 import sign_der

    witness_script = p2pkh_script_pubkey(hash160(pubkey))
    script_pubkey = bytes([0x00, 0x20]) + sha256_digest(witness_script)
    unsigned = Transaction(
        version=1,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=prev_txid, index=prev_vout),
                script_sig=b"",
                sequence=0xFFFFFFFF,
            ),
        ),
        outputs=(TxOut(value=output_value, script_pubkey=b"\x51"),),
        lock_time=0,
        witness=((),),
    )
    sighash = bip143_sighash(unsigned, 0, witness_script, amount=prev_amount, sighash_type=1)
    signature = sign_der(private_key, sighash) + bytes([1])
    signed = Transaction(
        version=unsigned.version,
        inputs=unsigned.inputs,
        outputs=unsigned.outputs,
        lock_time=unsigned.lock_time,
        witness=((signature, pubkey, witness_script),),
    )
    return signed, script_pubkey


def make_signed_p2wpkh_spend(
    *,
    private_key: int,
    prev_txid: bytes,
    prev_vout: int,
    prev_amount: int,
    pubkey: bytes,
    output_value: int,
) -> tuple[Transaction, bytes]:
    from pybitnode.consensus.script.interpreter import p2pkh_script_code
    from pybitnode.consensus.secp256k1 import sign_der

    pubkey_hash = hash160(pubkey)
    script_pubkey = bytes([0x00, 0x14]) + pubkey_hash
    script_code = p2pkh_script_code(pubkey_hash)
    unsigned = Transaction(
        version=1,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=prev_txid, index=prev_vout),
                script_sig=b"",
                sequence=0xFFFFFFFF,
            ),
        ),
        outputs=(TxOut(value=output_value, script_pubkey=b"\x51"),),
        lock_time=0,
        witness=((),),
    )
    sighash = bip143_sighash(unsigned, 0, script_code, amount=prev_amount, sighash_type=1)
    signature = sign_der(private_key, sighash) + bytes([1])
    signed = Transaction(
        version=unsigned.version,
        inputs=unsigned.inputs,
        outputs=unsigned.outputs,
        lock_time=unsigned.lock_time,
        witness=((signature, pubkey),),
    )
    return signed, script_pubkey
