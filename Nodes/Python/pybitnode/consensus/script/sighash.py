from __future__ import annotations

import hashlib
import struct

from typing import Sequence

from pybitnode.messages.transaction import Transaction, TxOut
from pybitnode.wire.serialize import double_sha256, write_varint


def bitcoin_tagged_hash(tag: str, msg: bytes) -> bytes:
    tag_digest = hashlib.sha256(tag.encode()).digest()
    return hashlib.sha256(tag_digest + tag_digest + msg).digest()


def tapleaf_hash(leaf_version: int, tapscript_bytes: bytes) -> bytes:
    """BIP341 TapLeaf TaggedHash(leaf_version_byte || CompactSize(script) || script)."""
    msg = bytes([leaf_version & 0xFF]) + write_varint(len(tapscript_bytes)) + tapscript_bytes
    return bitcoin_tagged_hash("TapLeaf", msg)


def tapbranch_hash(left: bytes, right: bytes) -> bytes:
    """BIP341 sibling branch TaggedHash(sorted pair)."""
    pair = left + right if left < right else right + left
    return bitcoin_tagged_hash("TapBranch", pair)


def taproot_tweak_pubkey_hash(internal_pubkey_xonly: bytes, merkle_root: bytes) -> bytes:
    """TaggedHash(\"TapTweak\", internal_x || merkle_root)."""
    return bitcoin_tagged_hash("TapTweak", internal_pubkey_xonly + merkle_root)


def taproot_merkle_root_from_branch(branch_nodes: Sequence[bytes], leaf_hash: bytes) -> bytes:
    k = leaf_hash
    for sibling in branch_nodes:
        k = tapbranch_hash(k, sibling)
    return k


def serialized_witness_stack_bytes(stack: Sequence[bytes]) -> bytes:
    blob = write_varint(len(stack))
    for item in stack:
        blob += write_varint(len(item)) + item
    return blob


# BIP341 sighash hashtype bytes (distinct from legacy SIGHASH_*).
TAPROOT_SIGHASH_DEFAULT = 0
TAPROOT_SIGHASH_ALL = 1
TAPROOT_SIGHASH_NONE = 2
TAPROOT_SIGHASH_SINGLE = 3


def _taproot_allowed_hashtypes(hash_type: int) -> bool:
    """Allowed BIP341 8-bit hash types (matching Bitcoin Core)."""
    return hash_type <= 0x03 or (0x81 <= hash_type <= 0x83)


def _taproot_annex_digest(annex: bytes) -> bytes:
    return hashlib.sha256(write_varint(len(annex)) + annex).digest()


def _sha256_concat(parts: Sequence[bytes]) -> bytes:
    return hashlib.sha256(b"".join(parts)).digest()


def taproot_signature_hash(
    transaction: Transaction,
    input_index: int,
    spent_prevouts: Sequence[tuple[int, bytes]],
    *,
    hash_type: int,
    annex: bytes | None = None,
    ext_flag: int = 0,
    tapleaf_hash: bytes | None = None,
    tapscript_codeseparator_pos: int = 0xFFFFFFFF,
) -> bytes:
    """
    BIP341 tagged TapSchnorr sighash preimage.
    Key path: ext_flag=0. Tapscript: ext_flag=1 with tapleaf digest + CODESEPARATOR position (BIP342).
    """
    if len(spent_prevouts) != len(transaction.inputs):
        raise ValueError("spent_prevouts length mismatch")
    if not _taproot_allowed_hashtypes(hash_type):
        raise ValueError("unsupported taproot sighash type")
    annex_present = annex is not None
    if ext_flag not in (0, 1):
        raise ValueError("invalid taproot ext_flag")
    if ext_flag == 1 and (tapleaf_hash is None or len(tapleaf_hash) != 32):
        raise ValueError("tapscript sighash requires 32-byte tapleaf_hash")

    epoch = bytes([0])
    output_mode = TAPROOT_SIGHASH_ALL if hash_type == TAPROOT_SIGHASH_DEFAULT else (hash_type & 0x03)
    anyone_can_pay = bool(hash_type & 0x80)

    body = bytes([hash_type])
    body += struct.pack("<i", transaction.version)
    body += struct.pack("<I", transaction.lock_time)

    if not anyone_can_pay:
        prev_blob = b"".join(inp.previous_output.serialize() for inp in transaction.inputs)
        amounts_blob = b"".join(struct.pack("<q", amt) for amt, _ in spent_prevouts)
        script_blob = b"".join(write_varint(len(pk)) + pk for _, pk in spent_prevouts)
        sequences_blob = b"".join(struct.pack("<I", inp.sequence) for inp in transaction.inputs)
        body += _sha256_concat((prev_blob,))
        body += _sha256_concat((amounts_blob,))
        body += _sha256_concat((script_blob,))
        body += _sha256_concat((sequences_blob,))
    else:
        if input_index >= len(transaction.inputs):
            raise ValueError("input_index out of range")

    if output_mode == TAPROOT_SIGHASH_ALL:
        outs_blob = b"".join(out.serialize() for out in transaction.outputs)
        body += _sha256_concat((outs_blob,))
    elif output_mode == TAPROOT_SIGHASH_SINGLE:
        if input_index >= len(transaction.outputs):
            raise ValueError("SIGHASH_SINGLE without matching output")

    spend_type = (ext_flag << 1) + (1 if annex_present else 0)
    body += bytes([spend_type])

    if anyone_can_pay:
        tin = transaction.inputs[input_index]
        amt, spk = spent_prevouts[input_index]
        utxo_blob = TxOut(value=amt, script_pubkey=spk).serialize()
        body += tin.previous_output.serialize()
        body += utxo_blob
        body += struct.pack("<I", tin.sequence)
    else:
        body += struct.pack("<I", input_index)

    if annex_present:
        body += _taproot_annex_digest(annex or b"")

    if output_mode == TAPROOT_SIGHASH_SINGLE:
        body += hashlib.sha256(transaction.outputs[input_index].serialize()).digest()

    if ext_flag == 1:
        assert tapleaf_hash is not None
        body += tapleaf_hash
        body += bytes([0])
        body += struct.pack("<I", tapscript_codeseparator_pos & 0xFFFFFFFF)

    sigmsg = epoch + body
    return bitcoin_tagged_hash("TapSighash", sigmsg)


def legacy_sighash(
    transaction: Transaction,
    input_index: int,
    script_code: bytes,
    *,
    sighash_type: int = 1,
) -> bytes:
    if input_index >= len(transaction.inputs):
        raise ValueError("input_index out of range")

    base_type = sighash_type & 0x1F
    anyone_can_pay = bool(sighash_type & 0x80)

    if base_type == 3 and input_index >= len(transaction.outputs):
        return (b"\x00" * 31) + b"\x01"

    if anyone_can_pay:
        inputs = [transaction.inputs[input_index]]
    else:
        inputs = list(transaction.inputs)

    serialized = struct.pack("<i", transaction.version)
    serialized += write_varint(len(inputs))

    for index, tx_in in enumerate(inputs):
        source_index = input_index if anyone_can_pay else index
        serialized += tx_in.previous_output.serialize()
        if source_index == input_index:
            serialized += write_varint(len(script_code))
            serialized += script_code
        else:
            serialized += b"\x00"
        # SIGHASH_NONE/SINGLE: only non-signing inputs get sequence 0 (Core RawSignatureHash).
        if anyone_can_pay or base_type == 1 or source_index == input_index:
            serialized += struct.pack("<I", transaction.inputs[source_index].sequence)
        else:
            serialized += b"\x00" * 4

    if base_type == 2:
        serialized += write_varint(0)
    elif base_type == 3:
        serialized += write_varint(input_index + 1)
        for _ in range(input_index):
            serialized += TxOut(value=0, script_pubkey=b"").serialize()
        serialized += transaction.outputs[input_index].serialize()
    else:
        serialized += write_varint(len(transaction.outputs))
        for output in transaction.outputs:
            serialized += output.serialize()

    serialized += struct.pack("<I", transaction.lock_time)
    serialized += struct.pack("<I", sighash_type)
    return double_sha256(serialized)


def bip143_sighash(
    transaction: Transaction,
    input_index: int,
    script_code: bytes,
    *,
    amount: int,
    sighash_type: int = 1,
) -> bytes:
    if input_index >= len(transaction.inputs):
        raise ValueError("input_index out of range")

    anyone_can_pay = bool(sighash_type & 0x80)
    base_type = sighash_type & 0x1F

    hash_prevouts = b"\x00" * 32
    if not anyone_can_pay:
        prevouts = b"".join(tx_in.previous_output.serialize() for tx_in in transaction.inputs)
        hash_prevouts = double_sha256(prevouts)

    hash_sequence = b"\x00" * 32
    if not anyone_can_pay and base_type not in (2, 3):
        sequences = b"".join(struct.pack("<I", tx_in.sequence) for tx_in in transaction.inputs)
        hash_sequence = double_sha256(sequences)

    hash_outputs = b"\x00" * 32
    if base_type == 3:
        if input_index < len(transaction.outputs):
            hash_outputs = double_sha256(transaction.outputs[input_index].serialize())
    elif base_type != 2:
        outputs = b"".join(output.serialize() for output in transaction.outputs)
        hash_outputs = double_sha256(outputs)

    tx_in = transaction.inputs[input_index]
    payload = struct.pack("<i", transaction.version)
    payload += hash_prevouts
    payload += hash_sequence
    payload += tx_in.previous_output.serialize()
    payload += write_varint(len(script_code))
    payload += script_code
    payload += struct.pack("<q", amount)
    payload += struct.pack("<I", tx_in.sequence)
    payload += hash_outputs
    payload += struct.pack("<I", transaction.lock_time)
    payload += struct.pack("<I", sighash_type)
    return double_sha256(payload)
