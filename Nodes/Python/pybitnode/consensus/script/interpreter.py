from __future__ import annotations

import struct
from collections.abc import Sequence

import hashlib

from pybitnode.consensus.hash import hash160, hash256, sha256_digest
from pybitnode.consensus.script.opcodes import (
    OP_0,
    OP_1,
    OP_16,
    OP_1NEGATE,
    OP_0NOTEQUAL,
    OP_2OVER,
    OP_2SWAP,
    OP_2DUP,
    OP_3DUP,
    OP_ABS,
    OP_ADD,
    OP_BOOLAND,
    OP_BOOLOR,
    OP_CHECKLOCKTIMEVERIFY,
    OP_CHECKSEQUENCEVERIFY,
    OP_CHECKSIG,
    OP_CHECKSIGADD,
    OP_CHECKSIGVERIFY,
    OP_DROP,
    OP_DUP,
    OP_SIZE,
    OP_EQUAL,
    OP_EQUALVERIFY,
    OP_FROMALTSTACK,
    OP_DEPTH,
    OP_HASH160,
    OP_HASH256,
    OP_IFDUP,
    OP_NIP,
    OP_NOP,
    OP_NOT,
    OP_MAX,
    OP_MIN,
    OP_OVER,
    OP_PICK,
    OP_RIPEMD160,
    OP_ROLL,
    OP_ROT,
    OP_SHA1,
    OP_SHA256,
    OP_PUSHDATA1,
    OP_PUSHDATA2,
    OP_PUSHDATA4,
    OP_VERIFY,
    OP_SWAP,
    OP_TOALTSTACK,
    OP_TUCK,
    OP_WITHIN,
    SCRIPT_VERIFY_CHECKLOCKTIMEVERIFY,
    SCRIPT_VERIFY_CHECKSEQUENCEVERIFY,
    SCRIPT_VERIFY_DEFAULT,
)
from pybitnode.consensus.script.sighash import (
    TAPROOT_SIGHASH_DEFAULT,
    bip143_sighash,
    legacy_sighash,
    tapleaf_hash,
    taproot_merkle_root_from_branch,
    taproot_tweak_pubkey_hash,
    taproot_signature_hash,
    serialized_witness_stack_bytes,
)
from pybitnode.consensus.secp256k1 import (
    Gx,
    Gy,
    N,
    lift_x_only_pubkey,
    verify_der_signature,
    verify_schnorr_signature,
    _point_add,
    _scalar_mult,
)


class ScriptError(ValueError):
    pass


MAX_P2SH_REDEEM_PUSH = 520
MAX_CONSENSUS_SCRIPT_SIZE = 10000
MAX_TAPSCRIPT_STACK_ELEMENTS = 1000
MAX_SCRIPT_ELEMENT_SIZE_CONSENSUS = 520
WITNESS_V1_TAPROOT_XONLY_PK_LEN = 32
ANNEX_TAG = 0x50
TAPROOT_LEAF_VERSION_TAPSCRIPT = 0xC0
VALIDATION_WEIGHT_OFFSET = 50
VALIDATION_WEIGHT_PER_SIGOP = 50

OP_DROP = 0x75
OP_2DROP = 0x6D
OP_NIP = 0x77
OP_1SUB = 0x8C
OP_ADD = 0x93
OP_SUB = 0x94
OP_NUMEQUAL = 0x9C
OP_NUMNOTEQUAL = 0x9D
OP_LESSTHAN = 0x9F
OP_GREATERTHAN = 0xA0
OP_LESSTHANOREQUAL = 0xA1
OP_GREATERTHANOREQUAL = 0xA2
OP_IF = 0x63
OP_NOTIF = 0x64
OP_ELSE = 0x67
OP_ENDIF = 0x68
OP_CODESEPARATOR = 0xAB
OP_CHECKMULTISIG = 0xAE
OP_CHECKMULTISIGVERIFY = 0xAF
MAX_PUBKEYS_PER_MULTISIG = 20
LOCKTIME_THRESHOLD = 500_000_000
SEQUENCE_FINAL = 0xFFFFFFFF
SEQUENCE_LOCKTIME_DISABLE_FLAG = 1 << 31
SEQUENCE_LOCKTIME_TYPE_FLAG = 1 << 22
SEQUENCE_LOCKTIME_MASK = 0x0000_FFFF
MAX_SCRIPTNUM_SIZE_LOCKTIME = 5


class Stack(list):
    def pop_item(self) -> bytes:
        if not self:
            raise ScriptError("stack underflow")
        return self.pop()

    def push_item(self, item: bytes) -> None:
        self.append(item)


def _read_push(data: bytes, offset: int) -> tuple[bytes, int]:
    opcode = data[offset]
    offset += 1
    if opcode == OP_0:
        return b"", offset
    if OP_1 <= opcode <= OP_16:
        return bytes([opcode - OP_1 + 1]), offset
    if opcode == OP_1NEGATE:
        return b"\x81", offset
    if 1 <= opcode <= 75:
        end = offset + opcode
        return data[offset:end], offset + opcode
    if opcode == OP_PUSHDATA1:
        (size,) = struct.unpack_from("<B", data, offset)
        offset += 1
        end = offset + size
        return data[offset:end], end
    if opcode == OP_PUSHDATA2:
        (size,) = struct.unpack_from("<H", data, offset)
        offset += 2
        end = offset + size
        return data[offset:end], end
    if opcode == OP_PUSHDATA4:
        (size,) = struct.unpack_from("<I", data, offset)
        offset += 4
        end = offset + size
        return data[offset:end], end
    raise ScriptError(f"unsupported push opcode {opcode:#x}")


def _cast_to_bool(item: bytes) -> bool:
    for index, byte in enumerate(item):
        if byte != 0:
            if index == len(item) - 1 and byte == 0x80:
                return False
            return True
    return False


def _encode_op_n(value: int) -> bytes:
    if value == 0:
        return b""
    if 1 <= value <= 16:
        return bytes([value])
    raise ScriptError(f"cannot encode numeric {value}")


def _encode_script_num(value: int, *, max_len: int = 4) -> bytes:
    if value == 0:
        return b""
    negative = value < 0
    absvalue = -value if negative else value
    result = bytearray(absvalue.to_bytes((absvalue.bit_length() + 7) // 8 or 1, "little"))
    if result[-1] & 0x80:
        result.append(0x00)
    if negative:
        result[-1] |= 0x80
    if len(result) > max_len:
        raise ScriptError("script number overflow")
    return bytes(result)


def _decode_script_num(item: bytes, *, max_len: int = 4) -> int:
    if len(item) > max_len:
        raise ScriptError("script number overflow")
    if not item:
        return 0
    if item[-1] & 0x80:
        magnitude = bytearray(item)
        magnitude[-1] &= 0x7F
        if all(byte == 0 for byte in magnitude):
            return 0
        return -int.from_bytes(magnitude, "little")
    return int.from_bytes(item, "little")


def _stack_item(stack: Stack, depth_from_top: int) -> bytes:
    if len(stack) < depth_from_top:
        raise ScriptError("stack underflow")
    return stack[-depth_from_top]


def _legacy_find_and_delete(script_code: bytes, target: bytes) -> bytes:
    """Remove push-only occurrences of a legacy signature from scriptCode."""
    output = bytearray()
    offset = 0
    while offset < len(script_code):
        start = offset
        opcode = script_code[offset]
        offset += 1
        if opcode == OP_0:
            item = b""
        elif OP_1 <= opcode <= OP_16:
            item = bytes([opcode - OP_1 + 1])
        elif opcode == OP_1NEGATE:
            item = b"\x81"
        elif 1 <= opcode <= 75 or opcode in (OP_PUSHDATA1, OP_PUSHDATA2, OP_PUSHDATA4):
            offset = start
            try:
                item, offset = _read_push(script_code, offset)
            except ScriptError:
                output.extend(script_code[start:])
                break
        else:
            output.extend(script_code[start:offset])
            continue
        if item != target:
            output.extend(script_code[start:offset])
    return bytes(output)


def _check_ecdsa_signature(
    *,
    signature: bytes,
    pubkey: bytes,
    tx,
    input_index: int,
    script_code: bytes,
    amount: int,
    witness: bool,
) -> bool:
    if not signature:
        return False
    sighash_type = signature[-1]
    sig_der = signature[:-1]
    if witness:
        digest = bip143_sighash(
            tx,
            input_index,
            script_code,
            amount=amount,
            sighash_type=sighash_type,
        )
    else:
        script_code = _legacy_find_and_delete(script_code, signature)
        digest = legacy_sighash(
            tx,
            input_index,
            script_code,
            sighash_type=sighash_type,
        )
    return verify_der_signature(pubkey, digest, sig_der)


def _exec_checkmultisig(
    stack: Stack,
    opcode: int,
    *,
    tx,
    input_index: int,
    script_code: bytes,
    amount: int,
    witness: bool,
) -> None:
    i = 1
    if len(stack) < i:
        raise ScriptError("CHECKMULTISIG stack underflow")

    n_keys_count = _decode_script_num(_stack_item(stack, i))
    if n_keys_count < 0 or n_keys_count > MAX_PUBKEYS_PER_MULTISIG:
        raise ScriptError("pubkey count out of range")

    ikey = i + 1
    i = ikey + n_keys_count
    if len(stack) < i:
        raise ScriptError("CHECKMULTISIG stack underflow")

    n_sigs_count = _decode_script_num(_stack_item(stack, i))
    if n_sigs_count < 0 or n_sigs_count > n_keys_count:
        raise ScriptError("signature count out of range")

    isig = i + 1
    i = isig + n_sigs_count
    if len(stack) < i:
        raise ScriptError("CHECKMULTISIG stack underflow")

    success = True
    sig_offset = 0
    key_offset = 0
    remaining_sigs = n_sigs_count
    remaining_keys = n_keys_count
    active_script_code = script_code
    if not witness:
        for offset in range(n_sigs_count):
            active_script_code = _legacy_find_and_delete(active_script_code, _stack_item(stack, isig + offset))
    while success and remaining_sigs > 0:
        sig = _stack_item(stack, isig + sig_offset)
        pubkey = _stack_item(stack, ikey + key_offset)
        if _check_ecdsa_signature(
            signature=sig,
            pubkey=pubkey,
            tx=tx,
            input_index=input_index,
            script_code=active_script_code,
            amount=amount,
            witness=witness,
        ):
            sig_offset += 1
            remaining_sigs -= 1
        key_offset += 1
        remaining_keys -= 1
        if remaining_sigs > remaining_keys:
            success = False

    while i > 1:
        stack.pop_item()
        i -= 1

    if not stack:
        raise ScriptError("CHECKMULTISIG missing dummy")
    stack.pop_item()

    if opcode == OP_CHECKMULTISIG:
        stack.push_item(_encode_op_n(int(success)))
    elif not success:
        raise ScriptError("CHECKMULTISIGVERIFY failed")


def _tx_is_final_for_cltv(tx) -> bool:
    """BIP65: CLTV is inactive when nLockTime is unset or all inputs are final."""
    if tx.lock_time == 0:
        return True
    return all(tx_in.sequence == SEQUENCE_FINAL for tx_in in tx.inputs)


def _exec_checklocktimeverify(stack: Stack, *, tx) -> None:
    if not stack:
        raise ScriptError("CHECKLOCKTIMEVERIFY stack empty")
    # BIP65: CLTV is a no-op when nVersion < 2 (legacy txs may still set nLockTime).
    if tx.version < 2:
        return
    if _tx_is_final_for_cltv(tx):
        raise ScriptError("CHECKLOCKTIMEVERIFY on final tx")

    locktime_value = _decode_script_num(stack[-1], max_len=MAX_SCRIPTNUM_SIZE_LOCKTIME)
    if locktime_value < 0:
        raise ScriptError("CHECKLOCKTIMEVERIFY negative locktime")

    n_lock_time = tx.lock_time
    if (n_lock_time < LOCKTIME_THRESHOLD) != (locktime_value < LOCKTIME_THRESHOLD):
        raise ScriptError("CHECKLOCKTIMEVERIFY locktime type mismatch")
    if locktime_value > n_lock_time:
        raise ScriptError("CHECKLOCKTIMEVERIFY unsatisfied locktime")


def _exec_checksequenceverify(stack: Stack, *, tx, input_index: int) -> None:
    if not stack:
        raise ScriptError("CHECKSEQUENCEVERIFY stack empty")
    # BIP112: CSV is a no-op when nVersion < 2.
    if tx.version < 2:
        return

    n_sequence = tx.inputs[input_index].sequence
    if n_sequence == SEQUENCE_FINAL:
        raise ScriptError("CHECKSEQUENCEVERIFY on final sequence")
    if n_sequence & SEQUENCE_LOCKTIME_DISABLE_FLAG:
        raise ScriptError("CHECKSEQUENCEVERIFY disabled sequence")

    seq_value = _decode_script_num(stack[-1], max_len=MAX_SCRIPTNUM_SIZE_LOCKTIME)
    if seq_value < 0:
        raise ScriptError("CHECKSEQUENCEVERIFY negative locktime")

    stack_type = bool(seq_value & SEQUENCE_LOCKTIME_TYPE_FLAG)
    seq_type = bool(n_sequence & SEQUENCE_LOCKTIME_TYPE_FLAG)
    if stack_type != seq_type:
        raise ScriptError("CHECKSEQUENCEVERIFY locktime type mismatch")
    if (seq_value & SEQUENCE_LOCKTIME_MASK) > (n_sequence & SEQUENCE_LOCKTIME_MASK):
        raise ScriptError("CHECKSEQUENCEVERIFY unsatisfied locktime")


def _legacy_f_exec(vf_exec: list[bool]) -> bool:
    return all(vf_exec)


def evaluate_script(
    script: bytes,
    stack: Stack,
    *,
    tx,
    input_index: int,
    script_code: bytes,
    amount: int,
    witness: bool,
    verify_flags: int = SCRIPT_VERIFY_DEFAULT,
) -> None:
    offset = 0
    codeseparator_offset = 0
    vf_exec: list[bool] = []
    altstack: list[bytes] = []
    while offset < len(script):
        opcode = script[offset]
        f_exec = _legacy_f_exec(vf_exec)

        if opcode in (OP_IF, OP_NOTIF):
            if f_exec:
                if not stack:
                    raise ScriptError("OP_IF stack empty")
                branch = _cast_to_bool(stack.pop_item())
                if opcode == OP_NOTIF:
                    branch = not branch
                vf_exec.append(branch)
            else:
                vf_exec.append(False)
            offset += 1
            continue
        if opcode == OP_ELSE:
            if not vf_exec:
                raise ScriptError("unbalanced conditional")
            vf_exec[-1] = not vf_exec[-1]
            offset += 1
            continue
        if opcode == OP_ENDIF:
            if not vf_exec:
                raise ScriptError("unbalanced conditional")
            vf_exec.pop()
            offset += 1
            continue

        if not f_exec:
            offset = _tapscript_advance_opcode(script, offset)
            continue

        offset += 1
        if opcode == OP_0:
            stack.push_item(b"")
        elif OP_1 <= opcode <= OP_16:
            stack.push_item(_encode_op_n(opcode - OP_1 + 1))
        elif opcode == OP_1NEGATE:
            stack.push_item(b"\x81")
        elif 1 <= opcode <= 75 or opcode in (OP_PUSHDATA1, OP_PUSHDATA2, OP_PUSHDATA4):
            offset -= 1
            item, offset = _read_push(script, offset)
            stack.push_item(item)
        elif opcode == OP_DUP:
            item = stack.pop_item()
            stack.push_item(item)
            stack.push_item(item)
        elif opcode == OP_DROP:
            stack.pop_item()
        elif opcode == OP_2DROP:
            stack.pop_item()
            stack.pop_item()
        elif opcode == OP_2DUP:
            if len(stack) < 2:
                raise ScriptError("stack underflow")
            stack.extend(stack[-2:])
        elif opcode == OP_3DUP:
            if len(stack) < 3:
                raise ScriptError("stack underflow")
            stack.extend(stack[-3:])
        elif opcode == OP_2OVER:
            if len(stack) < 4:
                raise ScriptError("stack underflow")
            stack.extend(stack[-4:-2])
        elif opcode == OP_2SWAP:
            if len(stack) < 4:
                raise ScriptError("stack underflow")
            stack[-4], stack[-3], stack[-2], stack[-1] = stack[-2], stack[-1], stack[-4], stack[-3]
        elif opcode == OP_IFDUP:
            if not stack:
                raise ScriptError("stack underflow")
            if _cast_to_bool(stack[-1]):
                stack.push_item(stack[-1])
        elif opcode == OP_NIP:
            if len(stack) < 2:
                raise ScriptError("stack underflow")
            del stack[-2]
        elif opcode == OP_OVER:
            if len(stack) < 2:
                raise ScriptError("stack underflow")
            stack.push_item(stack[-2])
        elif opcode == OP_ROT:
            if len(stack) < 3:
                raise ScriptError("stack underflow")
            stack.append(stack.pop(-3))
        elif opcode == OP_TUCK:
            if len(stack) < 2:
                raise ScriptError("stack underflow")
            stack.insert(len(stack) - 2, stack[-1])
        elif opcode == OP_TOALTSTACK:
            altstack.append(stack.pop_item())
        elif opcode == OP_FROMALTSTACK:
            if not altstack:
                raise ScriptError("altstack underflow")
            stack.push_item(altstack.pop())
        elif opcode == OP_DEPTH:
            stack.push_item(_encode_script_num(len(stack)))
        elif opcode == OP_PICK:
            n = _decode_script_num(stack.pop_item())
            if n < 0 or n >= len(stack):
                raise ScriptError("stack underflow")
            stack.push_item(stack[-n - 1])
        elif opcode == OP_ROLL:
            n = _decode_script_num(stack.pop_item())
            if n < 0 or n >= len(stack):
                raise ScriptError("stack underflow")
            stack.push_item(stack.pop(-n - 1))
        elif opcode == OP_SIZE:
            if not stack:
                raise ScriptError("stack underflow")
            stack.push_item(_encode_script_num(len(stack[-1])))
        elif opcode == OP_SWAP:
            top = stack.pop_item()
            second = stack.pop_item()
            stack.push_item(top)
            stack.push_item(second)
        elif opcode == OP_ABS:
            value = _decode_script_num(stack.pop_item())
            stack.push_item(_encode_script_num(abs(value), max_len=5))
        elif opcode == OP_NOT:
            value = _decode_script_num(stack.pop_item())
            stack.push_item(_encode_op_n(int(value == 0)))
        elif opcode == OP_0NOTEQUAL:
            value = _decode_script_num(stack.pop_item())
            stack.push_item(_encode_op_n(int(value != 0)))
        elif opcode == OP_ADD:
            b_val = _decode_script_num(stack.pop_item())
            a_val = _decode_script_num(stack.pop_item())
            stack.push_item(_encode_script_num(a_val + b_val, max_len=5))
        elif opcode == OP_SUB:
            b_val = _decode_script_num(stack.pop_item())
            a_val = _decode_script_num(stack.pop_item())
            stack.push_item(_encode_script_num(a_val - b_val))
        elif opcode == OP_LESSTHAN:
            b_val = _decode_script_num(stack.pop_item())
            a_val = _decode_script_num(stack.pop_item())
            stack.push_item(_encode_op_n(int(a_val < b_val)))
        elif opcode == OP_GREATERTHAN:
            b_val = _decode_script_num(stack.pop_item())
            a_val = _decode_script_num(stack.pop_item())
            stack.push_item(_encode_op_n(int(a_val > b_val)))
        elif opcode == OP_LESSTHANOREQUAL:
            b_val = _decode_script_num(stack.pop_item())
            a_val = _decode_script_num(stack.pop_item())
            stack.push_item(_encode_op_n(int(a_val <= b_val)))
        elif opcode == OP_GREATERTHANOREQUAL:
            b_val = _decode_script_num(stack.pop_item())
            a_val = _decode_script_num(stack.pop_item())
            stack.push_item(_encode_op_n(int(a_val >= b_val)))
        elif opcode == OP_BOOLAND:
            b_val = _decode_script_num(stack.pop_item())
            a_val = _decode_script_num(stack.pop_item())
            stack.push_item(_encode_op_n(int(a_val != 0 and b_val != 0)))
        elif opcode == OP_BOOLOR:
            b_val = _decode_script_num(stack.pop_item())
            a_val = _decode_script_num(stack.pop_item())
            stack.push_item(_encode_op_n(int(a_val != 0 or b_val != 0)))
        elif opcode == OP_MIN:
            b_val = _decode_script_num(stack.pop_item())
            a_val = _decode_script_num(stack.pop_item())
            stack.push_item(_encode_script_num(min(a_val, b_val), max_len=5))
        elif opcode == OP_MAX:
            b_val = _decode_script_num(stack.pop_item())
            a_val = _decode_script_num(stack.pop_item())
            stack.push_item(_encode_script_num(max(a_val, b_val), max_len=5))
        elif opcode == OP_WITHIN:
            max_val = _decode_script_num(stack.pop_item())
            min_val = _decode_script_num(stack.pop_item())
            x_val = _decode_script_num(stack.pop_item())
            stack.push_item(_encode_op_n(int(min_val <= x_val < max_val)))
        elif opcode == OP_RIPEMD160:
            stack.push_item(hashlib.new("ripemd160", stack.pop_item()).digest())
        elif opcode == OP_SHA1:
            stack.push_item(hashlib.sha1(stack.pop_item()).digest())
        elif opcode == OP_SHA256:
            stack.push_item(sha256_digest(stack.pop_item()))
        elif opcode == OP_HASH160:
            stack.push_item(hash160(stack.pop_item()))
        elif opcode == OP_HASH256:
            stack.push_item(hash256(stack.pop_item()))
        elif opcode == OP_EQUAL:
            b_val = stack.pop_item()
            a_val = stack.pop_item()
            stack.push_item(_encode_op_n(int(a_val == b_val)))
        elif opcode == OP_EQUALVERIFY:
            b_val = stack.pop_item()
            a_val = stack.pop_item()
            if a_val != b_val:
                raise ScriptError("EQUALVERIFY failed")
        elif opcode == OP_VERIFY:
            if not _cast_to_bool(stack.pop_item()):
                raise ScriptError("VERIFY failed")
        elif opcode == OP_NOP:
            pass
        elif opcode == OP_CODESEPARATOR:
            codeseparator_offset = offset
        elif opcode in (OP_CHECKSIG, OP_CHECKSIGVERIFY):
            pubkey = stack.pop_item()
            signature = stack.pop_item()
            active_script_code = script_code[codeseparator_offset:]
            valid = _check_ecdsa_signature(
                signature=signature,
                pubkey=pubkey,
                tx=tx,
                input_index=input_index,
                script_code=active_script_code,
                amount=amount,
                witness=witness,
            )
            if opcode == OP_CHECKSIG:
                stack.push_item(_encode_op_n(int(valid)))
            elif not valid:
                raise ScriptError("CHECKSIGVERIFY failed")
        elif opcode in (OP_CHECKMULTISIG, OP_CHECKMULTISIGVERIFY):
            active_script_code = script_code[codeseparator_offset:]
            _exec_checkmultisig(
                stack,
                opcode,
                tx=tx,
                input_index=input_index,
                script_code=active_script_code,
                amount=amount,
                witness=witness,
            )
        elif opcode == OP_CHECKLOCKTIMEVERIFY:
            if verify_flags & SCRIPT_VERIFY_CHECKLOCKTIMEVERIFY:
                _exec_checklocktimeverify(stack, tx=tx)
        elif opcode == OP_CHECKSEQUENCEVERIFY:
            if verify_flags & SCRIPT_VERIFY_CHECKSEQUENCEVERIFY:
                _exec_checksequenceverify(stack, tx=tx, input_index=input_index)
        else:
            raise ScriptError(f"unsupported opcode {opcode:#x}")


def p2pkh_script_code(pubkey_hash: bytes) -> bytes:
    return bytes([OP_DUP, OP_HASH160, len(pubkey_hash)]) + pubkey_hash + bytes([0x88, OP_CHECKSIG])


def parse_push_only_script_sig(script_sig: bytes) -> list[bytes]:
    """scriptSig for P2SH must contain only push opcodes (BIP16)."""
    offset = 0
    pushes: list[bytes] = []
    while offset < len(script_sig):
        opcode = script_sig[offset]
        offset += 1
        if opcode == OP_0:
            pushes.append(b"")
        elif OP_1 <= opcode <= OP_16:
            pushes.append(bytes([opcode - OP_1 + 1]))
        elif opcode == OP_1NEGATE:
            pushes.append(b"\x81")
        elif 1 <= opcode <= 75 or opcode in (OP_PUSHDATA1, OP_PUSHDATA2, OP_PUSHDATA4):
            offset -= 1
            item, offset = _read_push(script_sig, offset)
            pushes.append(item)
        else:
            raise ScriptError("non-push opcode in P2SH scriptSig")
    return pushes


def is_p2pkh(script_pubkey: bytes) -> bool:
    return (
        len(script_pubkey) == 25
        and script_pubkey[0] == OP_DUP
        and script_pubkey[1] == OP_HASH160
        and script_pubkey[2] == 0x14
        and script_pubkey[23] == OP_EQUALVERIFY
        and script_pubkey[24] == OP_CHECKSIG
    )


def is_p2pk(script_pubkey: bytes) -> bool:
    """Pay-to-pubkey: <pubKey> OP_CHECKSIG (historical miner coinbases and early txs)."""
    if len(script_pubkey) == 35:
        return script_pubkey[0] == 33 and script_pubkey[-1] == OP_CHECKSIG
    if len(script_pubkey) == 67:
        return script_pubkey[0] == 65 and script_pubkey[-1] == OP_CHECKSIG
    return False


def is_bare_op_n(script_pubkey: bytes) -> bool:
    """Bare legacy output: single OP_1..OP_16 / OP_1NEGATE (truthy with empty scriptSig)."""
    return len(script_pubkey) == 1 and (
        OP_1 <= script_pubkey[0] <= OP_16 or script_pubkey[0] == OP_1NEGATE
    )


def _is_ecdsa_pubkey(item: bytes) -> bool:
    if len(item) == 33:
        return item[0] in (0x02, 0x03)
    if len(item) == 65:
        return item[0] == 0x04
    return False


def is_bare_multisig(script_pubkey: bytes) -> bool:
    """Bare m-of-n multisig: OP_m <pubkeys...> OP_n OP_CHECKMULTISIG (legacy, pre-P2SH)."""
    if len(script_pubkey) < 4:
        return False
    offset = 0
    m_opcode = script_pubkey[offset]
    if not (OP_1 <= m_opcode <= OP_16):
        return False
    required = m_opcode - OP_1 + 1
    offset += 1

    pubkeys: list[bytes] = []
    try:
        while offset < len(script_pubkey):
            opcode = script_pubkey[offset]
            if OP_1 <= opcode <= OP_16:
                break
            item, offset = _read_push(script_pubkey, offset)
            if not _is_ecdsa_pubkey(item):
                return False
            pubkeys.append(item)
            if len(pubkeys) > MAX_PUBKEYS_PER_MULTISIG:
                return False
    except ScriptError:
        return False

    if len(pubkeys) < required or not pubkeys:
        return False
    if offset >= len(script_pubkey):
        return False

    n_opcode = script_pubkey[offset]
    if not (OP_1 <= n_opcode <= OP_16):
        return False
    if n_opcode - OP_1 + 1 != len(pubkeys):
        return False
    offset += 1
    if offset >= len(script_pubkey) or script_pubkey[offset] != OP_CHECKMULTISIG:
        return False
    offset += 1
    return offset == len(script_pubkey)


def is_p2wpkh(script_pubkey: bytes) -> bool:
    return len(script_pubkey) == 22 and script_pubkey[0] == 0x00 and script_pubkey[1] == 0x14


def is_p2sh(script_pubkey: bytes) -> bool:
    return (
        len(script_pubkey) == 23
        and script_pubkey[0] == OP_HASH160
        and script_pubkey[1] == 0x14
        and script_pubkey[22] == OP_EQUAL
    )


def is_p2wsh(script_pubkey: bytes) -> bool:
    return len(script_pubkey) == 34 and script_pubkey[0] == 0x00 and script_pubkey[1] == 0x20


def is_p2tr(script_pubkey: bytes) -> bool:
    """BIP341 P2TR: OP_1 + push 32 (x-only output key)."""
    return (
        len(script_pubkey) == 2 + WITNESS_V1_TAPROOT_XONLY_PK_LEN
        and script_pubkey[0] == OP_1
        and script_pubkey[1] == WITNESS_V1_TAPROOT_XONLY_PK_LEN
    )


def is_bare_legacy_script(script_pubkey: bytes) -> bool:
    """Bounded bare legacy script fallback for historical consensus-valid outputs."""
    return (
        bool(script_pubkey)
        and len(script_pubkey) > MAX_SCRIPT_ELEMENT_SIZE_CONSENSUS
        and len(script_pubkey) <= MAX_CONSENSUS_SCRIPT_SIZE
        and witness_program_version(script_pubkey) is None
        and not (
            is_p2pk(script_pubkey)
            or is_p2pkh(script_pubkey)
            or is_p2sh(script_pubkey)
            or is_p2wpkh(script_pubkey)
            or is_p2wsh(script_pubkey)
            or is_p2tr(script_pubkey)
            or is_bare_op_n(script_pubkey)
            or is_bare_multisig(script_pubkey)
        )
    )


def witness_program_version(script_pubkey: bytes) -> int | None:
    """
    BIP141 witness program version if scriptPubKey is a well-formed program, else None.

    Recognizes OP_0..OP_16 version byte followed by a single push of 2..40 bytes that
    consumes the remainder of the script.
    """
    if len(script_pubkey) < 4:
        return None
    version_byte = script_pubkey[0]
    if version_byte == OP_0:
        version = 0
    elif OP_1 <= version_byte <= OP_16:
        version = version_byte - OP_1 + 1
    else:
        return None

    pc = 1
    if pc >= len(script_pubkey):
        return None
    opcode = script_pubkey[pc]
    if 1 <= opcode <= 75:
        push_len = opcode
        data_start = pc + 1
    elif opcode == OP_PUSHDATA1:
        if pc + 1 >= len(script_pubkey):
            return None
        push_len = script_pubkey[pc + 1]
        data_start = pc + 2
    elif opcode == OP_PUSHDATA2:
        if pc + 2 >= len(script_pubkey):
            return None
        push_len = struct.unpack_from("<H", script_pubkey, pc + 1)[0]
        data_start = pc + 3
    elif opcode == OP_PUSHDATA4:
        if pc + 4 >= len(script_pubkey):
            return None
        push_len = struct.unpack_from("<I", script_pubkey, pc + 1)[0]
        data_start = pc + 5
    else:
        return None

    if not (2 <= push_len <= 40):
        return None
    if data_start + push_len != len(script_pubkey):
        return None
    return version


def _taproot_tweak_pubkey_xonly(internal_xonly: bytes, merkle_root: bytes) -> tuple[int, bytes]:
    """
    BIP341 taproot_tweak_pubkey for 32-byte x-only internal key and merkle root (32 bytes or empty).
    Returns (output_key_y_parity_bit, output_xonly_32) where y_parity is 0 if Q has even y else 1.
    """
    if len(internal_xonly) != 32:
        raise ValueError("internal key must be 32 bytes")
    tweak = taproot_tweak_pubkey_hash(internal_xonly, merkle_root)
    t = int.from_bytes(tweak, "big")
    if t >= N:
        raise ValueError("TapTweak out of range")
    x_int = int.from_bytes(internal_xonly, "big")
    p_pt = lift_x_only_pubkey(x_int)
    if p_pt is None:
        raise ValueError("invalid internal x-only key")
    q_pt = _point_add(p_pt, _scalar_mult(t, (Gx, Gy)))
    if q_pt is None:
        raise ValueError("taproot tweak failed")
    xq, yq = q_pt
    parity = 0 if (yq % 2 == 0) else 1
    return parity, xq.to_bytes(32, "big")


def _tapscript_opcode_is_success(opcode: int) -> bool:
    if opcode in (80, 98):
        return True
    if 126 <= opcode <= 129:
        return True
    if 131 <= opcode <= 134:
        return True
    if 137 <= opcode <= 138:
        return True
    if 141 <= opcode <= 142:
        return True
    if 149 <= opcode <= 153:
        return True
    if 187 <= opcode <= 254:
        return True
    return False


def _tapscript_f_exec(vf_exec: list[bool]) -> bool:
    return all(vf_exec)


def _tapscript_advance_opcode(script: bytes, offset: int) -> int:
    opcode = script[offset]
    if opcode == OP_0 or (OP_1 <= opcode <= OP_16) or opcode == OP_1NEGATE:
        return offset + 1
    if 1 <= opcode <= 75:
        return offset + 1 + opcode
    if opcode in (OP_PUSHDATA1, OP_PUSHDATA2, OP_PUSHDATA4):
        _, new_offset = _read_push(script, offset)
        return new_offset
    return offset + 1


def _tapscript_prescan_op_success(script: bytes) -> bool:
    pc = 0
    while pc < len(script):
        opcode = script[pc]
        if opcode == OP_0:
            pc += 1
            continue
        if OP_1 <= opcode <= OP_16 or opcode == OP_1NEGATE:
            pc += 1
            continue
        if 1 <= opcode <= 75:
            pc += 1 + opcode
            continue
        if opcode in (OP_PUSHDATA1, OP_PUSHDATA2, OP_PUSHDATA4):
            try:
                _, pc = _read_push(script, pc)
            except ScriptError:
                return False
            continue
        if _tapscript_opcode_is_success(opcode):
            return True
        pc += 1
    return False


def _tapscript_verify_schnorr_signature(
    *,
    pubkey: bytes,
    signature: bytes,
    tx,
    input_index: int,
    spent_prevouts: Sequence[tuple[int, bytes]],
    annex: bytes | None,
    tapleaf_digest: bytes,
    codeseparator_pos: int,
) -> bool:
    if not signature:
        return False
    hash_type = TAPROOT_SIGHASH_DEFAULT
    sig64 = signature
    if len(signature) == 65:
        hash_type = signature[64]
        if hash_type == TAPROOT_SIGHASH_DEFAULT:
            raise ScriptError("invalid tap hashtype byte")
        sig64 = signature[:64]
    elif len(signature) != 64:
        raise ScriptError("invalid Schnorr signature length")
    try:
        digest = taproot_signature_hash(
            tx,
            input_index,
            spent_prevouts,
            hash_type=hash_type,
            annex=annex,
            ext_flag=1,
            tapleaf_hash=tapleaf_digest,
            tapscript_codeseparator_pos=codeseparator_pos,
        )
    except ValueError as exc:
        raise ScriptError(str(exc)) from exc
    return verify_schnorr_signature(pubkey, digest, sig64)


def _evaluate_tapscript(
    script: bytes,
    stack: Stack,
    *,
    tx,
    input_index: int,
    tapleaf_digest: bytes,
    spent_prevouts: Sequence[tuple[int, bytes]],
    annex: bytes | None,
    validation_budget_left: list[int],
) -> None:
    if _tapscript_prescan_op_success(script):
        return

    codeseparator_pos = 0xFFFFFFFF
    instruction_pos = 0
    offset = 0
    vf_exec: list[bool] = []
    while offset < len(script):
        instr_at = instruction_pos
        opcode = script[offset]
        f_exec = _tapscript_f_exec(vf_exec)

        if opcode in (OP_IF, OP_NOTIF):
            if f_exec:
                if not stack:
                    raise ScriptError("OP_IF stack empty")
                branch = _cast_to_bool(stack.pop_item())
                if opcode == OP_NOTIF:
                    branch = not branch
                vf_exec.append(branch)
            else:
                vf_exec.append(False)
            offset += 1
            instruction_pos += 1
            continue
        if opcode == OP_ELSE:
            if not vf_exec:
                raise ScriptError("unbalanced conditional")
            vf_exec[-1] = not vf_exec[-1]
            offset += 1
            instruction_pos += 1
            continue
        if opcode == OP_ENDIF:
            if not vf_exec:
                raise ScriptError("unbalanced conditional")
            vf_exec.pop()
            offset += 1
            instruction_pos += 1
            continue

        if not f_exec:
            offset = _tapscript_advance_opcode(script, offset)
            instruction_pos += 1
            continue

        if opcode == OP_0:
            stack.push_item(b"")
            offset += 1
            instruction_pos += 1
        elif OP_1 <= opcode <= OP_16:
            stack.push_item(_encode_op_n(opcode - OP_1 + 1))
            offset += 1
            instruction_pos += 1
        elif opcode == OP_1NEGATE:
            stack.push_item(b"\x81")
            offset += 1
            instruction_pos += 1
        elif 1 <= opcode <= 75 or opcode in (OP_PUSHDATA1, OP_PUSHDATA2, OP_PUSHDATA4):
            item, offset = _read_push(script, offset)
            stack.push_item(item)
            instruction_pos += 1
        elif opcode == OP_DROP:
            stack.pop_item()
            offset += 1
            instruction_pos += 1
        elif opcode == OP_NIP:
            if len(stack) < 2:
                raise ScriptError("stack underflow")
            del stack[-2]
            offset += 1
            instruction_pos += 1
        elif opcode == OP_2DROP:
            stack.pop_item()
            stack.pop_item()
            offset += 1
            instruction_pos += 1
        elif opcode == OP_SWAP:
            a = stack.pop_item()
            b = stack.pop_item()
            stack.push_item(a)
            stack.push_item(b)
            offset += 1
            instruction_pos += 1
        elif opcode == OP_DUP:
            item = stack.pop_item()
            stack.push_item(item)
            stack.push_item(item)
            offset += 1
            instruction_pos += 1
        elif opcode == OP_SIZE:
            if not stack:
                raise ScriptError("stack underflow")
            stack.push_item(_encode_script_num(len(stack[-1])))
            offset += 1
            instruction_pos += 1
        elif opcode == OP_HASH160:
            stack.push_item(hash160(stack.pop_item()))
            offset += 1
            instruction_pos += 1
        elif opcode == OP_SHA256:
            stack.push_item(sha256_digest(stack.pop_item()))
            offset += 1
            instruction_pos += 1
        elif opcode == OP_EQUAL:
            b_val = stack.pop_item()
            a_val = stack.pop_item()
            stack.push_item(_encode_op_n(int(a_val == b_val)))
            offset += 1
            instruction_pos += 1
        elif opcode == OP_EQUALVERIFY:
            b_val = stack.pop_item()
            a_val = stack.pop_item()
            if a_val != b_val:
                raise ScriptError("EQUALVERIFY failed")
            offset += 1
            instruction_pos += 1
        elif opcode == OP_VERIFY:
            if not _cast_to_bool(stack.pop_item()):
                raise ScriptError("VERIFY failed")
            offset += 1
            instruction_pos += 1
        elif opcode == OP_CODESEPARATOR:
            codeseparator_pos = instr_at
            offset += 1
            instruction_pos += 1
        elif opcode in (OP_CHECKMULTISIG, OP_CHECKMULTISIGVERIFY):
            raise ScriptError("CHECKMULTISIG disabled in tapscript")
        elif opcode == 0x61:  # OP_NOP
            offset += 1
            instruction_pos += 1
        elif opcode in (OP_CHECKSIG, OP_CHECKSIGVERIFY):
            pubkey = stack.pop_item()
            signature = stack.pop_item()
            if len(pubkey) == 0:
                raise ScriptError("empty pubkey in tapscript checksig")

            def _consume_sigop_if_nonempty() -> None:
                if signature:
                    validation_budget_left[0] -= VALIDATION_WEIGHT_PER_SIGOP
                    if validation_budget_left[0] < 0:
                        raise ScriptError("tapscript validation weight exceeded")

            if len(pubkey) != 32:
                if not signature:
                    if opcode == OP_CHECKSIGVERIFY:
                        raise ScriptError("CHECKSIGVERIFY failed")
                    stack.push_item(b"")
                else:
                    _consume_sigop_if_nonempty()
                    if opcode == OP_CHECKSIG:
                        stack.push_item(bytes([1]))
                offset += 1
                instruction_pos += 1
                continue

            if not signature:
                valid = False
            else:
                _consume_sigop_if_nonempty()
                valid = _tapscript_verify_schnorr_signature(
                    pubkey=pubkey,
                    signature=signature,
                    tx=tx,
                    input_index=input_index,
                    spent_prevouts=spent_prevouts,
                    annex=annex,
                    tapleaf_digest=tapleaf_digest,
                    codeseparator_pos=codeseparator_pos,
                )

            if opcode == OP_CHECKSIG:
                stack.push_item(_encode_op_n(int(valid)))
            elif not valid:
                raise ScriptError("CHECKSIGVERIFY failed")
            offset += 1
            instruction_pos += 1
        elif opcode == OP_CHECKSIGADD:
            pubkey = stack.pop_item()
            n_item = stack.pop_item()
            signature = stack.pop_item()
            if len(pubkey) == 0:
                raise ScriptError("empty pubkey in tapscript checksigadd")
            n = _decode_script_num(n_item)

            def _consume_sigop_if_nonempty_csadd() -> None:
                if signature:
                    validation_budget_left[0] -= VALIDATION_WEIGHT_PER_SIGOP
                    if validation_budget_left[0] < 0:
                        raise ScriptError("tapscript validation weight exceeded")

            if len(pubkey) != 32:
                if signature:
                    _consume_sigop_if_nonempty_csadd()
                    stack.push_item(_encode_script_num(n + 1))
                else:
                    stack.push_item(_encode_script_num(n))
                offset += 1
                instruction_pos += 1
                continue

            if not signature:
                stack.push_item(_encode_script_num(n))
            else:
                _consume_sigop_if_nonempty_csadd()
                valid = _tapscript_verify_schnorr_signature(
                    pubkey=pubkey,
                    signature=signature,
                    tx=tx,
                    input_index=input_index,
                    spent_prevouts=spent_prevouts,
                    annex=annex,
                    tapleaf_digest=tapleaf_digest,
                    codeseparator_pos=codeseparator_pos,
                )
                stack.push_item(_encode_script_num(n + 1 if valid else n))
            offset += 1
            instruction_pos += 1
        elif opcode in (OP_LESSTHAN, OP_GREATERTHAN, OP_LESSTHANOREQUAL, OP_GREATERTHANOREQUAL):
            b_val = _decode_script_num(stack.pop_item())
            a_val = _decode_script_num(stack.pop_item())
            if opcode == OP_LESSTHAN:
                result = a_val < b_val
            elif opcode == OP_GREATERTHAN:
                result = a_val > b_val
            elif opcode == OP_LESSTHANOREQUAL:
                result = a_val <= b_val
            else:
                result = a_val >= b_val
            stack.push_item(_encode_op_n(int(result)))
            offset += 1
            instruction_pos += 1
        elif opcode in (OP_NUMEQUAL, OP_NUMNOTEQUAL):
            b_val = _decode_script_num(stack.pop_item())
            a_val = _decode_script_num(stack.pop_item())
            result = a_val == b_val if opcode == OP_NUMEQUAL else a_val != b_val
            stack.push_item(_encode_op_n(int(result)))
            offset += 1
            instruction_pos += 1
        elif opcode == OP_CHECKLOCKTIMEVERIFY:
            _exec_checklocktimeverify(stack, tx=tx)
            offset += 1
            instruction_pos += 1
        elif opcode == OP_CHECKSEQUENCEVERIFY:
            _exec_checksequenceverify(stack, tx=tx, input_index=input_index)
            offset += 1
            instruction_pos += 1
        else:
            raise ScriptError(f"unsupported tapscript opcode {opcode:#x}")


def _verify_p2tr_script_path(
    *,
    script_pubkey: bytes,
    witness_items_without_annex: list[bytes],
    annex: bytes | None,
    tx,
    input_index: int,
    spent_prevouts: Sequence[tuple[int, bytes]],
    serialized_witness_for_weight: bytes,
) -> bool:
    if spent_prevouts is None or len(spent_prevouts) != len(tx.inputs):
        return False

    if len(witness_items_without_annex) < 2:
        return False
    script_bytes = witness_items_without_annex[-2]
    control = witness_items_without_annex[-1]
    stack_items = witness_items_without_annex[:-2]

    # BIP342: the legacy 10_000-byte script size cap does not apply to tapscript leaves.
    if not script_bytes:
        return False
    ctl_len = len(control)
    if ctl_len < 33 or ctl_len > 33 + 128 * 32 or (ctl_len - 33) % 32 != 0:
        return False

    leaf_masked = control[0] & 0xFE
    if leaf_masked == ANNEX_TAG:
        return False

    internal_x = control[1:33]
    merkle_branch = [control[i : i + 32] for i in range(33, ctl_len, 32)]

    try:
        leaf_digest = tapleaf_hash(leaf_masked, script_bytes)
        merkle_root = taproot_merkle_root_from_branch(merkle_branch, leaf_digest)
        parity_out, out_x = _taproot_tweak_pubkey_xonly(internal_x, merkle_root)
    except ValueError:
        return False

    if out_x != script_pubkey[2:] or control[0] != (leaf_masked | parity_out):
        return False

    if leaf_masked != TAPROOT_LEAF_VERSION_TAPSCRIPT:
        return True

    if _tapscript_prescan_op_success(script_bytes):
        return True

    if len(stack_items) > MAX_TAPSCRIPT_STACK_ELEMENTS:
        return False
    for elem in stack_items:
        if len(elem) > MAX_SCRIPT_ELEMENT_SIZE_CONSENSUS:
            return False

    budget = [VALIDATION_WEIGHT_OFFSET + len(serialized_witness_for_weight)]

    exec_stack = Stack(list(stack_items))
    try:
        _evaluate_tapscript(
            script_bytes,
            exec_stack,
            tx=tx,
            input_index=input_index,
            tapleaf_digest=leaf_digest,
            spent_prevouts=spent_prevouts,
            annex=annex,
            validation_budget_left=budget,
        )
    except ScriptError:
        return False

    return _terminal_success_strict(exec_stack)


def _terminal_success_strict(stack: Stack) -> bool:
    """Witness v0 consensus uses clean-stack semantics (exactly one true item)."""
    return len(stack) == 1 and _cast_to_bool(stack[0])


def _terminal_success_relaxed(stack: Stack) -> bool:
    """Legacy script final stack must be nonempty with a true top (BIP16 P2SH leaves junk below)."""
    return bool(stack) and _cast_to_bool(stack[-1])


def verify_script(
    script_sig: bytes,
    script_pubkey: bytes,
    *,
    tx,
    input_index: int,
    amount: int,
    witness: tuple[bytes, ...] = (),
    spent_prevouts: Sequence[tuple[int, bytes]] | None = None,
) -> bool:
    witness_version = witness_program_version(script_pubkey)
    if witness_version == 1 and not is_p2tr(script_pubkey):
        return not script_sig

    if is_p2pk(script_pubkey):
        if witness:
            return False
        try:
            p2pk_pushes = parse_push_only_script_sig(script_sig)
        except ScriptError:
            return False
        if len(p2pk_pushes) != 1 or not p2pk_pushes[0]:
            return False

        stack_sig = Stack()
        try:
            evaluate_script(
                script_sig,
                stack_sig,
                tx=tx,
                input_index=input_index,
                script_code=script_pubkey,
                amount=amount,
                witness=False,
            )
        except ScriptError:
            return False

        stack = Stack(list(stack_sig))
        try:
            evaluate_script(
                script_pubkey,
                stack,
                tx=tx,
                input_index=input_index,
                script_code=script_pubkey,
                amount=amount,
                witness=False,
            )
        except ScriptError:
            return False

        return _terminal_success_strict(stack)

    if is_p2wpkh(script_pubkey):
        pubkey_hash = script_pubkey[2:]
        if script_sig:
            return False
        if len(witness) != 2:
            return False
        script_code = p2pkh_script_code(pubkey_hash)
        stack = Stack(list(witness))
        try:
            evaluate_script(
                script_code,
                stack,
                tx=tx,
                input_index=input_index,
                script_code=script_code,
                amount=amount,
                witness=True,
            )
        except ScriptError:
            return False
        return _terminal_success_strict(stack)

    if is_p2wsh(script_pubkey):
        if script_sig:
            return False
        if len(witness) < 1:
            return False
        witness_program = script_pubkey[2:]
        witness_script = witness[-1]
        if not witness_script or len(witness_script) > MAX_CONSENSUS_SCRIPT_SIZE:
            return False
        if sha256_digest(witness_script) != witness_program:
            return False
        stack = Stack(list(witness[:-1]))
        try:
            evaluate_script(
                witness_script,
                stack,
                tx=tx,
                input_index=input_index,
                script_code=witness_script,
                amount=amount,
                witness=True,
            )
        except ScriptError:
            return False
        return _terminal_success_strict(stack)

    if is_p2tr(script_pubkey):
        if script_sig:
            return False
        output_key_x = script_pubkey[2:]
        wit = list(witness)
        wit_serialized_for_weight = serialized_witness_stack_bytes(witness)
        annex: bytes | None = None
        if len(wit) >= 2 and wit[-1] and wit[-1][0] == ANNEX_TAG:
            annex = wit.pop()
        if len(wit) >= 2:
            if spent_prevouts is None:
                return False
            return _verify_p2tr_script_path(
                script_pubkey=script_pubkey,
                witness_items_without_annex=wit,
                annex=annex,
                tx=tx,
                input_index=input_index,
                spent_prevouts=spent_prevouts,
                serialized_witness_for_weight=wit_serialized_for_weight,
            )
        if spent_prevouts is None:
            return False
        if len(wit) != 1:
            return False
        sigblob = wit[0]
        if len(sigblob) not in (64, 65):
            return False
        hash_type = TAPROOT_SIGHASH_DEFAULT
        sig64 = sigblob
        if len(sigblob) == 65:
            hash_type = sigblob[64]
            if hash_type == TAPROOT_SIGHASH_DEFAULT:
                return False
            sig64 = sigblob[:64]
        try:
            msg = taproot_signature_hash(
                tx,
                input_index,
                spent_prevouts,
                hash_type=hash_type,
                annex=annex,
            )
        except ValueError:
            return False
        return verify_schnorr_signature(output_key_x, msg, sig64)

    redeem_candidate: bytes | None = None
    if is_p2sh(script_pubkey):
        try:
            p2sh_pushes = parse_push_only_script_sig(script_sig)
        except ScriptError:
            return False
        if not p2sh_pushes or len(p2sh_pushes[-1]) > MAX_P2SH_REDEEM_PUSH:
            return False
        redeem_candidate = p2sh_pushes[-1]

    stack_sig = Stack()
    try:
        evaluate_script(
            script_sig,
            stack_sig,
            tx=tx,
            input_index=input_index,
            script_code=script_pubkey,
            amount=amount,
            witness=False,
        )
    except ScriptError:
        return False

    if redeem_candidate is not None and (not stack_sig or stack_sig[-1] != redeem_candidate):
        return False

    stack = Stack(list(stack_sig))
    try:
        evaluate_script(
            script_pubkey,
            stack,
            tx=tx,
            input_index=input_index,
            script_code=script_pubkey,
            amount=amount,
            witness=False,
        )
    except ScriptError:
        return False

    if redeem_candidate is None:
        return _terminal_success_relaxed(stack)

    if not _terminal_success_relaxed(stack):
        return False

    expected_h160 = script_pubkey[2:22]
    if hash160(redeem_candidate) != expected_h160:
        return False

    if is_p2wpkh(redeem_candidate):
        pubkey_hash = redeem_candidate[2:]
        if len(witness) != 2:
            return False
        script_code = p2pkh_script_code(pubkey_hash)
        stack = Stack(list(witness))
        try:
            evaluate_script(
                script_code,
                stack,
                tx=tx,
                input_index=input_index,
                script_code=script_code,
                amount=amount,
                witness=True,
            )
        except ScriptError:
            return False
        return _terminal_success_strict(stack)

    if is_p2wsh(redeem_candidate):
        if len(witness) < 1:
            return False
        witness_program = redeem_candidate[2:]
        witness_script = witness[-1]
        if not witness_script or len(witness_script) > MAX_CONSENSUS_SCRIPT_SIZE:
            return False
        if sha256_digest(witness_script) != witness_program:
            return False
        stack = Stack(list(witness[:-1]))
        try:
            evaluate_script(
                witness_script,
                stack,
                tx=tx,
                input_index=input_index,
                script_code=witness_script,
                amount=amount,
                witness=True,
            )
        except ScriptError:
            return False
        return _terminal_success_strict(stack)

    inner = Stack(stack_sig[:-1])
    try:
        evaluate_script(
            redeem_candidate,
            inner,
            tx=tx,
            input_index=input_index,
            script_code=redeem_candidate,
            amount=amount,
            witness=False,
        )
    except ScriptError:
        return False
    return _terminal_success_relaxed(inner)
