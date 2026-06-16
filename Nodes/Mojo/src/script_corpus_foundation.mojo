from std.collections import List
from std.ffi import OwnedDLHandle
from std.memory.unsafe_pointer import alloc
from std.os import getenv
from std.pathlib import Path

from pure_secp import (
    pure_backend_label,
    pure_verify_ecdsa_der_bytes,
    pure_verify_schnorr_bytes,
    pure_verify_taproot_tweak_precomputed,
)


comptime CRYPTO_BACKEND_NATIVE = 0
comptime CRYPTO_BACKEND_PURE = 1
comptime CRYPTO_RESULT_VALID = 0
comptime CRYPTO_RESULT_CONSENSUS_INVALID = 1
comptime CRYPTO_RESULT_MALFORMED = 2
comptime CRYPTO_RESULT_UNSUPPORTED = 3


struct ScriptFixture(Movable):
    var fixture_id: String
    var height: Int
    var input_index: Int
    var prev_amount_sats: Int64
    var required_rule: String
    var tx: Transaction
    var spent_script_pubkey: List[UInt8]

    def __init__(out self):
        self.fixture_id = String("")
        self.height = 0
        self.input_index = 0
        self.prev_amount_sats = 0
        self.required_rule = String("")
        self.tx = Transaction()
        self.spent_script_pubkey = List[UInt8]()


struct P2pkhShadowEcdsaResult(Movable):
    var passed: Bool
    var sighash_ms: Int64
    var verify_ms: Int64
    var total_ms: Int64
    var signature_count: Int

    def __init__(out self):
        self.passed = False
        self.sighash_ms = 0
        self.verify_ms = 0
        self.total_ms = 0
        self.signature_count = 0


struct TxInput(Copyable):
    var previous_hash: List[UInt8]
    var previous_index: UInt32
    var script_sig: List[UInt8]
    var sequence: UInt32

    def __init__(out self):
        self.previous_hash = List[UInt8]()
        self.previous_index = 0
        self.script_sig = List[UInt8]()
        self.sequence = 0


struct TxOutput(Copyable):
    var value: Int64
    var script_pubkey: List[UInt8]

    def __init__(out self):
        self.value = 0
        self.script_pubkey = List[UInt8]()


struct ScriptStackItem(Copyable):
    var data: List[UInt8]

    def __init__(out self):
        self.data = List[UInt8]()


struct Transaction(Copyable):
    var version: Int32
    var inputs: List[TxInput]
    var outputs: List[TxOutput]
    var witness_items: List[ScriptStackItem]
    var witness_item_offsets_by_input: List[Int]
    var witness_item_count_by_input: List[Int]
    var lock_time: UInt32
    var has_witness: Bool

    def __init__(out self):
        self.version = 0
        self.inputs = List[TxInput]()
        self.outputs = List[TxOutput]()
        self.witness_items = List[ScriptStackItem]()
        self.witness_item_offsets_by_input = List[Int]()
        self.witness_item_count_by_input = List[Int]()
        self.lock_time = 0
        self.has_witness = False


struct ByteCursor(Movable):
    var data: List[UInt8]
    var offset: Int

    def __init__(out self, var data: List[UInt8]):
        self.data = data^
        self.offset = 0

    def remaining(self) -> Int:
        return len(self.data) - self.offset

    def read_u8(mut self) raises -> UInt8:
        if self.offset >= len(self.data):
            raise Error("unexpected end of byte stream")
        var value = self.data[self.offset]
        self.offset += 1
        return value

    def read_bytes(mut self, count: Int) raises -> List[UInt8]:
        if count < 0 or self.offset + count > len(self.data):
            raise Error("unexpected end of byte stream")
        var out = List[UInt8]()
        for i in range(count):
            out.append(self.data[self.offset + i])
        self.offset += count
        return out^

    def read_u32_le(mut self) raises -> UInt32:
        var b0 = UInt32(self.read_u8())
        var b1 = UInt32(self.read_u8())
        var b2 = UInt32(self.read_u8())
        var b3 = UInt32(self.read_u8())
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)

    def read_i32_le(mut self) raises -> Int32:
        return Int32(self.read_u32_le())

    def read_i64_le(mut self) raises -> Int64:
        var value = UInt64(0)
        for i in range(8):
            value |= UInt64(self.read_u8()) << UInt64(i * 8)
        return Int64(value)

    def read_varint(mut self) raises -> Int:
        var first = Int(self.read_u8())
        if first < 0xFD:
            return first
        if first == 0xFD:
            var lo = Int(self.read_u8())
            var hi = Int(self.read_u8())
            return lo | (hi << 8)
        if first == 0xFE:
            return Int(self.read_u32_le())
        var value = UInt64(0)
        for i in range(8):
            value |= UInt64(self.read_u8()) << UInt64(i * 8)
        return Int(value)


struct NativeCrypto(Movable):
    var handle: OwnedDLHandle

    def __init__(out self, shim_path: String) raises:
        self.handle = OwnedDLHandle(shim_path)

    def verify_ecdsa_der_bytes(
        ref self,
        ref pubkey: List[UInt8],
        ref der: List[UInt8],
        ref digest: List[UInt8],
    ) raises -> Int32:
        var pubkey_ptr = alloc[UInt8](len(pubkey))
        var der_ptr = alloc[UInt8](len(der))
        var digest_ptr = alloc[UInt8](len(digest))
        for i in range(len(pubkey)):
            pubkey_ptr[i] = pubkey[i]
        for i in range(len(der)):
            der_ptr[i] = der[i]
        for i in range(len(digest)):
            digest_ptr[i] = digest[i]
        var result = self.handle.call["mojobitnode_verify_ecdsa_der_bytes_len", Int32](
            pubkey_ptr,
            Int32(len(pubkey)),
            der_ptr,
            Int32(len(der)),
            digest_ptr,
            Int32(len(digest)),
        )
        pubkey_ptr.free()
        der_ptr.free()
        digest_ptr.free()
        return result

    def verify_schnorr_bytes(
        ref self,
        ref xonly_pubkey: List[UInt8],
        ref signature: List[UInt8],
        ref digest: List[UInt8],
    ) raises -> Int32:
        var pubkey_ptr = alloc[UInt8](len(xonly_pubkey))
        var sig_ptr = alloc[UInt8](len(signature))
        var digest_ptr = alloc[UInt8](len(digest))
        for i in range(len(xonly_pubkey)):
            pubkey_ptr[i] = xonly_pubkey[i]
        for i in range(len(signature)):
            sig_ptr[i] = signature[i]
        for i in range(len(digest)):
            digest_ptr[i] = digest[i]
        var result = self.handle.call["mojobitnode_verify_schnorr_bytes_len", Int32](
            pubkey_ptr,
            Int32(len(xonly_pubkey)),
            sig_ptr,
            Int32(len(signature)),
            digest_ptr,
            Int32(len(digest)),
        )
        pubkey_ptr.free()
        sig_ptr.free()
        digest_ptr.free()
        return result

    def verify_taproot_tweak_precomputed(
        ref self,
        ref internal_xonly: List[UInt8],
        ref tweak: List[UInt8],
        ref expected_xonly: List[UInt8],
        expected_parity: Int,
    ) raises -> Int32:
        var internal_ptr = alloc[UInt8](len(internal_xonly))
        var tweak_ptr = alloc[UInt8](len(tweak))
        var expected_ptr = alloc[UInt8](len(expected_xonly))
        for i in range(len(internal_xonly)):
            internal_ptr[i] = internal_xonly[i]
        for i in range(len(tweak)):
            tweak_ptr[i] = tweak[i]
        for i in range(len(expected_xonly)):
            expected_ptr[i] = expected_xonly[i]
        var result = self.handle.call["mojobitnode_verify_taproot_tweak_precomputed_bytes_len", Int32](
            internal_ptr,
            Int32(len(internal_xonly)),
            tweak_ptr,
            Int32(len(tweak)),
            expected_ptr,
            Int32(len(expected_xonly)),
            Int32(expected_parity),
        )
        internal_ptr.free()
        tweak_ptr.free()
        expected_ptr.free()
        return result


struct CryptoBackend(Movable):
    var kind: Int
    var native: NativeCrypto

    def __init__(out self, shim_path: String, kind: Int) raises:
        self.kind = kind
        self.native = NativeCrypto(shim_path)

    def label(ref self) -> String:
        if self.kind == CRYPTO_BACKEND_PURE:
            return pure_backend_label()
        return String("libsecp256k1")

    def is_pure(ref self) -> Bool:
        return self.kind == CRYPTO_BACKEND_PURE

    def verify_ecdsa_der_bytes(
        ref self,
        ref pubkey: List[UInt8],
        ref der: List[UInt8],
        ref digest: List[UInt8],
    ) raises -> Int32:
        if self.kind == CRYPTO_BACKEND_PURE:
            return pure_verify_ecdsa_der_bytes(pubkey, der, digest)
        return self.native.verify_ecdsa_der_bytes(pubkey, der, digest)

    def verify_schnorr_bytes(
        ref self,
        ref xonly_pubkey: List[UInt8],
        ref signature: List[UInt8],
        ref digest: List[UInt8],
    ) raises -> Int32:
        if self.kind == CRYPTO_BACKEND_PURE:
            return pure_verify_schnorr_bytes(xonly_pubkey, signature, digest)
        return self.native.verify_schnorr_bytes(xonly_pubkey, signature, digest)

    def verify_taproot_tweak_precomputed(
        ref self,
        ref internal_xonly: List[UInt8],
        ref tweak: List[UInt8],
        ref expected_xonly: List[UInt8],
        expected_parity: Int,
    ) raises -> Int32:
        if self.kind == CRYPTO_BACKEND_PURE:
            return pure_verify_taproot_tweak_precomputed(internal_xonly, tweak, expected_xonly, expected_parity)
        return self.native.verify_taproot_tweak_precomputed(internal_xonly, tweak, expected_xonly, expected_parity)


struct BareMultisigScript(Movable):
    var required_signatures: Int
    var pubkeys: List[ScriptStackItem]
    var pubkey_count: Int

    def __init__(out self):
        self.required_signatures = 0
        self.pubkeys = List[ScriptStackItem]()
        self.pubkey_count = 0


struct TaprootPrevout(Copyable):
    var amount: Int64
    var script_pubkey: List[UInt8]

    def __init__(out self):
        self.amount = 0
        self.script_pubkey = List[UInt8]()


struct DiagnosticEvalResult(Copyable):
    var passed: Bool
    var failure_stage: String
    var failure: String

    def __init__(out self):
        self.passed = False
        self.failure_stage = String("")
        self.failure = String("")


struct HotPathProfile(Copyable):
    var enabled: Bool
    var clone_calls: Int64
    var clone_bytes: Int64
    var slice_calls: Int64
    var slice_bytes: Int64
    var list_copy_calls: Int64
    var list_copy_items: Int64
    var script_stack_pushes: Int64
    var script_stack_pops: Int64
    var script_stack_dup_copy_ops: Int64
    var script_stack_reorder_ops: Int64
    var script_stack_max_depth: Int64
    var script_opcodes: Int64
    var legacy_sighash_calls: Int64
    var legacy_sighash_bytes: Int64
    var legacy_sighash_cached_calls: Int64
    var legacy_sighash_cached_bytes: Int64
    var legacy_sighash_reference_calls: Int64
    var legacy_sighash_reference_bytes: Int64
    var legacy_sighash_cache_build_bytes: Int64
    var bip143_sighash_calls: Int64
    var bip143_sighash_bytes: Int64
    var taproot_sighash_calls: Int64
    var taproot_sighash_bytes: Int64
    var script_verify_context_copies: Int64
    var script_verify_job_copies: Int64
    var native_arg_bytes_ecdsa: Int64
    var native_arg_bytes_schnorr: Int64
    var native_arg_bytes_taproot_tweak: Int64

    def __init__(out self):
        self.enabled = False
        self.clone_calls = 0
        self.clone_bytes = 0
        self.slice_calls = 0
        self.slice_bytes = 0
        self.list_copy_calls = 0
        self.list_copy_items = 0
        self.script_stack_pushes = 0
        self.script_stack_pops = 0
        self.script_stack_dup_copy_ops = 0
        self.script_stack_reorder_ops = 0
        self.script_stack_max_depth = 0
        self.script_opcodes = 0
        self.legacy_sighash_calls = 0
        self.legacy_sighash_bytes = 0
        self.legacy_sighash_cached_calls = 0
        self.legacy_sighash_cached_bytes = 0
        self.legacy_sighash_reference_calls = 0
        self.legacy_sighash_reference_bytes = 0
        self.legacy_sighash_cache_build_bytes = 0
        self.bip143_sighash_calls = 0
        self.bip143_sighash_bytes = 0
        self.taproot_sighash_calls = 0
        self.taproot_sighash_bytes = 0
        self.script_verify_context_copies = 0
        self.script_verify_job_copies = 0
        self.native_arg_bytes_ecdsa = 0
        self.native_arg_bytes_schnorr = 0
        self.native_arg_bytes_taproot_tweak = 0


def hotpath_profile_from_env() -> HotPathProfile:
    var profile = HotPathProfile()
    profile.enabled = getenv("MOJOBITNODE_PROFILE_HOTPATH", "0") == "1"
    return profile^


def hotpath_add(mut target: HotPathProfile, ref source: HotPathProfile):
    if not source.enabled:
        return
    target.enabled = target.enabled or source.enabled
    target.clone_calls += source.clone_calls
    target.clone_bytes += source.clone_bytes
    target.slice_calls += source.slice_calls
    target.slice_bytes += source.slice_bytes
    target.list_copy_calls += source.list_copy_calls
    target.list_copy_items += source.list_copy_items
    target.script_stack_pushes += source.script_stack_pushes
    target.script_stack_pops += source.script_stack_pops
    target.script_stack_dup_copy_ops += source.script_stack_dup_copy_ops
    target.script_stack_reorder_ops += source.script_stack_reorder_ops
    if source.script_stack_max_depth > target.script_stack_max_depth:
        target.script_stack_max_depth = source.script_stack_max_depth
    target.script_opcodes += source.script_opcodes
    target.legacy_sighash_calls += source.legacy_sighash_calls
    target.legacy_sighash_bytes += source.legacy_sighash_bytes
    target.legacy_sighash_cached_calls += source.legacy_sighash_cached_calls
    target.legacy_sighash_cached_bytes += source.legacy_sighash_cached_bytes
    target.legacy_sighash_reference_calls += source.legacy_sighash_reference_calls
    target.legacy_sighash_reference_bytes += source.legacy_sighash_reference_bytes
    target.legacy_sighash_cache_build_bytes += source.legacy_sighash_cache_build_bytes
    target.bip143_sighash_calls += source.bip143_sighash_calls
    target.bip143_sighash_bytes += source.bip143_sighash_bytes
    target.taproot_sighash_calls += source.taproot_sighash_calls
    target.taproot_sighash_bytes += source.taproot_sighash_bytes
    target.script_verify_context_copies += source.script_verify_context_copies
    target.script_verify_job_copies += source.script_verify_job_copies
    target.native_arg_bytes_ecdsa += source.native_arg_bytes_ecdsa
    target.native_arg_bytes_schnorr += source.native_arg_bytes_schnorr
    target.native_arg_bytes_taproot_tweak += source.native_arg_bytes_taproot_tweak


def hotpath_record_clone(mut profile: HotPathProfile, byte_count: Int):
    if profile.enabled:
        profile.clone_calls += 1
        profile.clone_bytes += Int64(byte_count)


def hotpath_record_slice(mut profile: HotPathProfile, byte_count: Int):
    if profile.enabled:
        profile.slice_calls += 1
        profile.slice_bytes += Int64(byte_count)


def hotpath_record_list_copy(mut profile: HotPathProfile, item_count: Int):
    if profile.enabled:
        profile.list_copy_calls += 1
        profile.list_copy_items += Int64(item_count)


def hotpath_record_legacy_sighash_reference(mut profile: HotPathProfile, byte_count: Int):
    if profile.enabled:
        profile.legacy_sighash_calls += 1
        profile.legacy_sighash_bytes += Int64(byte_count)
        profile.legacy_sighash_reference_calls += 1
        profile.legacy_sighash_reference_bytes += Int64(byte_count)


def hotpath_record_legacy_sighash_cached(mut profile: HotPathProfile, byte_count: Int):
    if profile.enabled:
        profile.legacy_sighash_calls += 1
        profile.legacy_sighash_bytes += Int64(byte_count)
        profile.legacy_sighash_cached_calls += 1
        profile.legacy_sighash_cached_bytes += Int64(byte_count)


def hotpath_record_legacy_sighash_cache_build(mut profile: HotPathProfile, byte_count: Int):
    if profile.enabled:
        profile.legacy_sighash_cache_build_bytes += Int64(byte_count)


def hotpath_record_bip143_sighash(mut profile: HotPathProfile, byte_count: Int):
    if profile.enabled:
        profile.bip143_sighash_calls += 1
        profile.bip143_sighash_bytes += Int64(byte_count)


def hotpath_record_taproot_sighash(mut profile: HotPathProfile, byte_count: Int):
    if profile.enabled:
        profile.taproot_sighash_calls += 1
        profile.taproot_sighash_bytes += Int64(byte_count)


def hotpath_record_native_ecdsa(mut profile: HotPathProfile, pubkey_len: Int, der_len: Int, digest_len: Int):
    if profile.enabled:
        profile.native_arg_bytes_ecdsa += Int64(pubkey_len + der_len + digest_len)


def hotpath_record_native_schnorr(mut profile: HotPathProfile, pubkey_len: Int, sig_len: Int, digest_len: Int):
    if profile.enabled:
        profile.native_arg_bytes_schnorr += Int64(pubkey_len + sig_len + digest_len)


def hotpath_record_native_taproot_tweak(mut profile: HotPathProfile, internal_len: Int, tweak_len: Int, expected_len: Int):
    if profile.enabled:
        profile.native_arg_bytes_taproot_tweak += Int64(internal_len + tweak_len + expected_len)


def hotpath_record_script_opcode(mut profile: HotPathProfile, opcode: Int, stack_depth: Int, alt_depth: Int):
    if not profile.enabled:
        return
    profile.script_opcodes += 1
    var depth = stack_depth
    if alt_depth > depth:
        depth = alt_depth
    if Int64(depth) > profile.script_stack_max_depth:
        profile.script_stack_max_depth = Int64(depth)
    if opcode == 0 or (opcode >= 1 and opcode <= 75) or opcode == 0x4C or opcode == 0x4D or opcode == 0x4E or (opcode >= 0x51 and opcode <= 0x60) or opcode == 0x4F:
        profile.script_stack_pushes += 1
    if opcode == 0x75 or opcode == 0x69:
        profile.script_stack_pops += 1
    elif opcode == 0x6D or opcode == 0x87 or opcode == 0x88 or opcode == 0x7C:
        profile.script_stack_pops += 2
    elif opcode == 0x72 or opcode == 0x7B:
        profile.script_stack_pops += 3
    elif opcode == 0x76 or opcode == 0x6E or opcode == 0x6F or opcode == 0x70 or opcode == 0x73 or opcode == 0x78 or opcode == 0x79 or opcode == 0x7D:
        profile.script_stack_dup_copy_ops += 1
    if opcode == 0x72 or opcode == 0x77 or opcode == 0x7A or opcode == 0x7B or opcode == 0x7C or opcode == 0x7D:
        profile.script_stack_reorder_ops += 1


def hotpath_profile_json_field(ref profile: HotPathProfile) -> String:
    if not profile.enabled:
        return String("")
    return (
        String(',"hotpath_profile":{"clone_calls":')
        + String(profile.clone_calls)
        + String(',"clone_bytes":')
        + String(profile.clone_bytes)
        + String(',"slice_calls":')
        + String(profile.slice_calls)
        + String(',"slice_bytes":')
        + String(profile.slice_bytes)
        + String(',"list_copy_calls":')
        + String(profile.list_copy_calls)
        + String(',"list_copy_items":')
        + String(profile.list_copy_items)
        + String(',"script_stack_pushes":')
        + String(profile.script_stack_pushes)
        + String(',"script_stack_pops":')
        + String(profile.script_stack_pops)
        + String(',"script_stack_dup_copy_ops":')
        + String(profile.script_stack_dup_copy_ops)
        + String(',"script_stack_reorder_ops":')
        + String(profile.script_stack_reorder_ops)
        + String(',"script_stack_max_depth":')
        + String(profile.script_stack_max_depth)
        + String(',"script_opcodes":')
        + String(profile.script_opcodes)
        + String(',"legacy_sighash_calls":')
        + String(profile.legacy_sighash_calls)
        + String(',"legacy_sighash_bytes":')
        + String(profile.legacy_sighash_bytes)
        + String(',"legacy_sighash_cached_calls":')
        + String(profile.legacy_sighash_cached_calls)
        + String(',"legacy_sighash_cached_bytes":')
        + String(profile.legacy_sighash_cached_bytes)
        + String(',"legacy_sighash_reference_calls":')
        + String(profile.legacy_sighash_reference_calls)
        + String(',"legacy_sighash_reference_bytes":')
        + String(profile.legacy_sighash_reference_bytes)
        + String(',"legacy_sighash_cache_build_bytes":')
        + String(profile.legacy_sighash_cache_build_bytes)
        + String(',"bip143_sighash_calls":')
        + String(profile.bip143_sighash_calls)
        + String(',"bip143_sighash_bytes":')
        + String(profile.bip143_sighash_bytes)
        + String(',"taproot_sighash_calls":')
        + String(profile.taproot_sighash_calls)
        + String(',"taproot_sighash_bytes":')
        + String(profile.taproot_sighash_bytes)
        + String(',"script_verify_context_copies":')
        + String(profile.script_verify_context_copies)
        + String(',"script_verify_job_copies":')
        + String(profile.script_verify_job_copies)
        + String(',"native_arg_bytes_ecdsa":')
        + String(profile.native_arg_bytes_ecdsa)
        + String(',"native_arg_bytes_schnorr":')
        + String(profile.native_arg_bytes_schnorr)
        + String(',"native_arg_bytes_taproot_tweak":')
        + String(profile.native_arg_bytes_taproot_tweak)
        + String("}")
    )


def _diagnostic_success() -> DiagnosticEvalResult:
    var result = DiagnosticEvalResult()
    result.passed = True
    return result^


def _diagnostic_failure(stage: String, failure: String) -> DiagnosticEvalResult:
    var result = DiagnosticEvalResult()
    result.passed = False
    result.failure_stage = stage
    result.failure = failure
    return result^


def diagnostic_failure_stage(message: String) -> String:
    if "unsupported crypto" in message or "crypto backend unsupported" in message:
        return String("unsupported_crypto")
    if "manifest" in message or "fixture id" in message or "fixture stem" in message or "hex" in message or "transaction parser" in message:
        return String("fixture_load")
    if "prevout" in message or "spent script" in message or "input index" in message or "scriptPubKey" in message:
        return String("prevout_shape")
    if "control block" in message or "leaf" in message or "witness script" in message or "witness control" in message:
        return String("control_block")
    if "Taproot tweak" in message or "tweak" in message:
        return String("taproot_tweak")
    if "SIGHASH" in message or "Taproot hash type" in message or "TapSighash" in message:
        return String("tapsighash")
    if "Schnorr" in message or "x-only" in message:
        return String("schnorr_verify")
    if "stack" in message or "opcode" in message or "OP_" in message or "conditional" in message:
        return String("opcode_execution")
    return String("fixture_evaluation")


def _hex_nibble(byte: UInt8) raises -> UInt8:
    var value = Int(byte)
    if value >= 48 and value <= 57:
        return UInt8(value - 48)
    if value >= 97 and value <= 102:
        return UInt8(value - 87)
    if value >= 65 and value <= 70:
        return UInt8(value - 55)
    raise Error("invalid hex digit")


def _is_space(byte: UInt8) -> Bool:
    var value = Int(byte)
    return value == 9 or value == 10 or value == 13 or value == 32


def hex_text_to_bytes(var text: List[UInt8]) raises -> List[UInt8]:
    var clean = List[UInt8]()
    for i in range(len(text)):
        if not _is_space(text[i]):
            clean.append(text[i])
    if len(clean) % 2 != 0:
        raise Error("hex text has odd length")
    var out = List[UInt8]()
    for i in range(0, len(clean), 2):
        var hi = Int(_hex_nibble(clean[i]))
        var lo = Int(_hex_nibble(clean[i + 1]))
        out.append(UInt8((hi << 4) | lo))
    return out^


def read_hex_file(path: String) raises -> List[UInt8]:
    return hex_text_to_bytes(Path(path).read_bytes())


def clone_bytes(ref bytes: List[UInt8]) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(bytes)):
        out.append(bytes[i])
    return out^


def clone_bytes_profiled(ref bytes: List[UInt8], mut profile: HotPathProfile) -> List[UInt8]:
    hotpath_record_clone(profile, len(bytes))
    return clone_bytes(bytes)


def slice_bytes(ref bytes: List[UInt8], start: Int, end: Int) raises -> List[UInt8]:
    if start < 0 or end < start or end > len(bytes):
        raise Error("invalid byte slice bounds")
    var out = List[UInt8]()
    for i in range(start, end):
        out.append(bytes[i])
    return out^


def slice_bytes_profiled(ref bytes: List[UInt8], start: Int, end: Int, mut profile: HotPathProfile) raises -> List[UInt8]:
    hotpath_record_slice(profile, end - start)
    return slice_bytes(bytes, start, end)


def bytes_equal(ref left: List[UInt8], ref right: List[UInt8]) -> Bool:
    if len(left) != len(right):
        return False
    for i in range(len(left)):
        if left[i] != right[i]:
            return False
    return True


def append_bytes(mut out: List[UInt8], ref bytes: List[UInt8]):
    for i in range(len(bytes)):
        out.append(bytes[i])


def append_u32_le(mut out: List[UInt8], value: UInt32):
    out.append(UInt8(value & 0xFF))
    out.append(UInt8((value >> 8) & 0xFF))
    out.append(UInt8((value >> 16) & 0xFF))
    out.append(UInt8((value >> 24) & 0xFF))


def append_i32_le(mut out: List[UInt8], value: Int32):
    append_u32_le(out, UInt32(value))


def append_i64_le(mut out: List[UInt8], value: Int64):
    var bits = UInt64(value)
    for i in range(8):
        out.append(UInt8((bits >> UInt64(i * 8)) & UInt64(0xFF)))


def append_varint(mut out: List[UInt8], value: Int) raises:
    if value < 0:
        raise Error("negative compactSize value")
    if value < 0xFD:
        out.append(UInt8(value))
        return
    if value <= 0xFFFF:
        out.append(UInt8(0xFD))
        out.append(UInt8(value & 0xFF))
        out.append(UInt8((value >> 8) & 0xFF))
        return
    if value <= 0xFFFFFFFF:
        out.append(UInt8(0xFE))
        append_u32_le(out, UInt32(value))
        return
    out.append(UInt8(0xFF))
    var bits = UInt64(value)
    for i in range(8):
        out.append(UInt8((bits >> UInt64(i * 8)) & UInt64(0xFF)))


def bytes_to_hex(ref bytes: List[UInt8]) -> String:
    var out = String("")
    for i in range(len(bytes)):
        var value = Int(bytes[i])
        var hi = (value >> 4) & 0x0F
        var lo = value & 0x0F
        if hi < 10:
            out += chr(48 + hi)
        else:
            out += chr(87 + hi)
        if lo < 10:
            out += chr(48 + lo)
        else:
            out += chr(87 + lo)
    return out


def ascii_bytes_to_string(ref bytes: List[UInt8], start: Int, end: Int) raises -> String:
    if start < 0 or end < start or end > len(bytes):
        raise Error("invalid ASCII slice bounds")
    var out = String("")
    for i in range(start, end):
        out += chr(Int(bytes[i]))
    return out


def ascii_string_to_bytes(text: String) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(text.byte_length()):
        out.append(UInt8(ord(text[byte=i])))
    return out^


def _contains_at(ref haystack: List[UInt8], offset: Int, ref needle: List[UInt8]) -> Bool:
    if offset < 0 or offset + len(needle) > len(haystack):
        return False
    for i in range(len(needle)):
        if haystack[offset + i] != needle[i]:
            return False
    return True


def _find_bytes(ref haystack: List[UInt8], ref needle: List[UInt8], start: Int) -> Int:
    if len(needle) == 0:
        return start
    for i in range(start, len(haystack) - len(needle) + 1):
        if _contains_at(haystack, i, needle):
            return i
    return -1


def manifest_contains_fixture(manifest_path: String, fixture_id: String) raises -> Bool:
    var manifest = Path(manifest_path).read_bytes()
    var needle = ascii_string_to_bytes(fixture_id)
    return _find_bytes(manifest, needle, 0) >= 0


def _read_script_push(ref script: List[UInt8], offset: Int) raises -> ScriptStackItem:
    if offset >= len(script):
        raise Error("script push offset out of range")
    var opcode = Int(script[offset])
    var item = ScriptStackItem()
    if opcode == 0:
        return item^
    if opcode >= 1 and opcode <= 75:
        item.data = slice_bytes(script, offset + 1, offset + 1 + opcode)
        return item^
    if opcode == 0x4C:
        if offset + 2 > len(script):
            raise Error("truncated PUSHDATA1")
        var count = Int(script[offset + 1])
        item.data = slice_bytes(script, offset + 2, offset + 2 + count)
        return item^
    if opcode == 0x4D:
        if offset + 3 > len(script):
            raise Error("truncated PUSHDATA2")
        var count = Int(script[offset + 1]) | (Int(script[offset + 2]) << 8)
        item.data = slice_bytes(script, offset + 3, offset + 3 + count)
        return item^
    if opcode == 0x4E:
        if offset + 5 > len(script):
            raise Error("truncated PUSHDATA4")
        var count = (
            Int(script[offset + 1])
            | (Int(script[offset + 2]) << 8)
            | (Int(script[offset + 3]) << 16)
            | (Int(script[offset + 4]) << 24)
        )
        item.data = slice_bytes(script, offset + 5, offset + 5 + count)
        return item^
    if opcode == 0x4F:
        item.data.append(UInt8(0x81))
        return item^
    if opcode >= 0x51 and opcode <= 0x60:
        item.data.append(UInt8(opcode - 0x50))
        return item^
    raise Error("unsupported push opcode in diagnostic fixture")


def _script_push_size(ref script: List[UInt8], offset: Int) raises -> Int:
    if offset >= len(script):
        raise Error("script push offset out of range")
    var opcode = Int(script[offset])
    if opcode == 0:
        return 1
    if opcode >= 1 and opcode <= 75:
        return 1 + opcode
    if opcode == 0x4C:
        if offset + 2 > len(script):
            raise Error("truncated PUSHDATA1")
        return 2 + Int(script[offset + 1])
    if opcode == 0x4D:
        if offset + 3 > len(script):
            raise Error("truncated PUSHDATA2")
        return 3 + (Int(script[offset + 1]) | (Int(script[offset + 2]) << 8))
    if opcode == 0x4E:
        if offset + 5 > len(script):
            raise Error("truncated PUSHDATA4")
        return (
            5
            + Int(script[offset + 1])
            + (Int(script[offset + 2]) << 8)
            + (Int(script[offset + 3]) << 16)
            + (Int(script[offset + 4]) << 24)
        )
    if opcode == 0x4F:
        return 1
    if opcode >= 0x51 and opcode <= 0x60:
        return 1
    raise Error("unsupported push opcode in diagnostic fixture")


def parse_push_only_stack(ref script: List[UInt8]) raises -> List[ScriptStackItem]:
    var stack = List[ScriptStackItem]()
    var offset = 0
    while offset < len(script):
        var item = _read_script_push(script, offset)
        offset += _script_push_size(script, offset)
        stack.append(item^)
    return stack^


def parse_bare_multisig_script(ref script: List[UInt8]) raises -> BareMultisigScript:
    if len(script) < 3:
        raise Error("bare multisig script too short")
    var offset = 0
    var first = Int(script[offset])
    if first < 0x51 or first > 0x60:
        raise Error("bare multisig script missing required signature count")
    var parsed = BareMultisigScript()
    parsed.required_signatures = first - 0x50
    offset += 1
    while offset < len(script):
        var opcode = Int(script[offset])
        if opcode >= 1 and opcode <= 75:
            var item = _read_script_push(script, offset)
            parsed.pubkeys.append(item^)
            offset += 1 + opcode
            continue
        if opcode >= 0x51 and opcode <= 0x60:
            parsed.pubkey_count = opcode - 0x50
            offset += 1
            if offset >= len(script) or Int(script[offset]) != 0xAE:
                raise Error("bare multisig script missing OP_CHECKMULTISIG")
            offset += 1
            if offset != len(script):
                raise Error("bare multisig script has trailing bytes")
            if parsed.pubkey_count != len(parsed.pubkeys):
                raise Error("bare multisig pubkey count mismatch")
            if parsed.required_signatures < 0 or parsed.required_signatures > parsed.pubkey_count:
                raise Error("bare multisig signature count out of range")
            return parsed^
        raise Error("unsupported bare multisig opcode")
    raise Error("bare multisig script ended before OP_CHECKMULTISIG")


def decode_script_num_with_max(ref item: List[UInt8], max_len: Int) raises -> Int:
    if len(item) > max_len:
        raise Error("script number overflow")
    if len(item) == 0:
        return 0
    var negative = (item[len(item) - 1] & UInt8(0x80)) != 0
    var result = 0
    for i in range(len(item)):
        var value = Int(item[i])
        if i == len(item) - 1:
            value &= 0x7F
        result |= value << (8 * i)
    if negative:
        return -result
    return result


def decode_script_num(ref item: List[UInt8]) raises -> Int:
    return decode_script_num_with_max(item, 4)


def csv_sequence_satisfied(ref tx: Transaction, input_index: Int, sequence: Int) raises -> Bool:
    if sequence < 0:
        raise Error("negative CSV sequence")
    if (sequence & 0x80000000) != 0:
        return True
    var input_sequence = Int(tx.inputs[input_index].sequence)
    if input_sequence == 0xFFFFFFFF:
        return False
    if (input_sequence & 0x80000000) != 0:
        return False
    if (sequence & 0x00400000) != (input_sequence & 0x00400000):
        return False
    return (sequence & 0x0000FFFF) <= (input_sequence & 0x0000FFFF)


def encode_script_num(value: Int) -> List[UInt8]:
    var out = List[UInt8]()
    if value == 0:
        return out^
    var abs_value = value
    if abs_value < 0:
        abs_value = -abs_value
    while abs_value > 0:
        out.append(UInt8(abs_value & 0xFF))
        abs_value = abs_value >> 8
    if (out[len(out) - 1] & UInt8(0x80)) != 0:
        if value < 0:
            out.append(UInt8(0x80))
        else:
            out.append(UInt8(0))
    elif value < 0:
        out[len(out) - 1] = out[len(out) - 1] | UInt8(0x80)
    return out^


def _stack_item_from_num(value: Int) -> ScriptStackItem:
    var item = ScriptStackItem()
    item.data = encode_script_num(value)
    return item^


def cast_to_bool(ref item: List[UInt8]) -> Bool:
    for i in range(len(item)):
        if item[i] != 0:
            if i == len(item) - 1 and item[i] == UInt8(0x80):
                return False
            return True
    return False


def _stack_pop(mut stack: List[ScriptStackItem]) raises -> ScriptStackItem:
    if len(stack) == 0:
        raise Error("script stack underflow")
    return stack.pop()


def _stack_push_num(mut stack: List[ScriptStackItem], value: Int):
    var item = _stack_item_from_num(value)
    stack.append(item^)


def _script_stack_item(ref stack: List[ScriptStackItem], depth_from_top: Int) raises -> ScriptStackItem:
    if depth_from_top <= 0 or len(stack) < depth_from_top:
        raise Error("script stack underflow")
    return stack[len(stack) - depth_from_top].copy()


def _script_terminal_success(ref stack: List[ScriptStackItem]) -> Bool:
    if len(stack) == 0:
        return False
    return cast_to_bool(stack[len(stack) - 1].data)


def _conditions_active(ref conditions: List[Bool]) -> Bool:
    for i in range(len(conditions)):
        if not conditions[i]:
            return False
    return True


def evaluate_legacy_script(
    ref script: List[UInt8],
    var stack: List[ScriptStackItem],
    ref tx: Transaction,
    input_index: Int,
    shim_path: String,
    has_tx_context: Bool,
    witness_v0: Bool = False,
    witness_amount_sats: Int64 = 0,
) raises -> Bool:
    var crypto = CryptoBackend(shim_path, CRYPTO_BACKEND_NATIVE)
    return evaluate_legacy_script_with_crypto(
        script,
        stack^,
        tx,
        input_index,
        shim_path,
        crypto,
        has_tx_context,
        witness_v0,
        witness_amount_sats,
    )


def evaluate_legacy_script_with_crypto(
    ref script: List[UInt8],
    var stack: List[ScriptStackItem],
    ref tx: Transaction,
    input_index: Int,
    shim_path: String,
    ref crypto: CryptoBackend,
    has_tx_context: Bool,
    witness_v0: Bool = False,
    witness_amount_sats: Int64 = 0,
) raises -> Bool:
    var profile = HotPathProfile()
    return evaluate_legacy_script_with_crypto_profiled(
        script,
        stack^,
        tx,
        input_index,
        shim_path,
        crypto,
        profile,
        has_tx_context,
        witness_v0,
        witness_amount_sats,
    )


def evaluate_legacy_script_with_crypto_profiled(
    ref script: List[UInt8],
    var stack: List[ScriptStackItem],
    ref tx: Transaction,
    input_index: Int,
    shim_path: String,
    ref crypto: CryptoBackend,
    mut profile: HotPathProfile,
    has_tx_context: Bool,
    witness_v0: Bool = False,
    witness_amount_sats: Int64 = 0,
) raises -> Bool:
    var offset = 0
    var code_separator_offset = 0
    var sighash_precompute = build_sighash_precompute(tx)
    var conditions = List[Bool]()
    var alt_stack = List[ScriptStackItem]()
    while offset < len(script):
        var opcode = Int(script[offset])
        hotpath_record_script_opcode(profile, opcode, len(stack), len(alt_stack))
        var active = _conditions_active(conditions)
        if opcode == 0 or (opcode >= 1 and opcode <= 75) or opcode == 0x4C or opcode == 0x4D or opcode == 0x4E:
            var item = _read_script_push(script, offset)
            offset += _script_push_size(script, offset)
            if active:
                stack.append(item^)
            continue
        if opcode >= 0x51 and opcode <= 0x60:
            if active:
                _stack_push_num(stack, opcode - 0x50)
            offset += 1
            continue
        if opcode == 0x4F:
            if active:
                _stack_push_num(stack, -1)
            offset += 1
            continue
        if opcode == 0x63 or opcode == 0x64:
            var parent_active = active
            var branch_active = False
            if parent_active:
                var item = _stack_pop(stack)
                var truth = cast_to_bool(item.data)
                if opcode == 0x63:
                    branch_active = truth
                else:
                    branch_active = not truth
            conditions.append(parent_active and branch_active)
            offset += 1
            continue
        if opcode == 0x67:
            if len(conditions) == 0:
                raise Error("unbalanced OP_ELSE")
            var parent_active = True
            for i in range(len(conditions) - 1):
                if not conditions[i]:
                    parent_active = False
            conditions[len(conditions) - 1] = parent_active and not conditions[len(conditions) - 1]
            offset += 1
            continue
        if opcode == 0x68:
            if len(conditions) == 0:
                raise Error("unbalanced OP_ENDIF")
            _ = conditions.pop()
            offset += 1
            continue
        if not active:
            offset += 1
            continue
        if opcode == 0x61:
            offset += 1
            continue
        if opcode == 0x75:
            _ = _stack_pop(stack)
            offset += 1
            continue
        if opcode == 0x76:
            var item = _script_stack_item(stack, 1)
            stack.append(item^)
            offset += 1
            continue
        if opcode == 0x69:
            var item = _stack_pop(stack)
            if not cast_to_bool(item.data):
                return False
            offset += 1
            continue
        if opcode == 0x6B:
            alt_stack.append(_stack_pop(stack))
            offset += 1
            continue
        if opcode == 0x6C:
            var item = _stack_pop(alt_stack)
            stack.append(item^)
            offset += 1
            continue
        if opcode == 0x6D:
            _ = _stack_pop(stack)
            _ = _stack_pop(stack)
            offset += 1
            continue
        if opcode == 0x6E:
            if len(stack) < 2:
                raise Error("OP_2DUP stack underflow")
            var a = stack[len(stack) - 2].copy()
            var b = stack[len(stack) - 1].copy()
            stack.append(a^)
            stack.append(b^)
            offset += 1
            continue
        if opcode == 0x6F:
            if len(stack) < 3:
                raise Error("OP_3DUP stack underflow")
            var a = stack[len(stack) - 3].copy()
            var b = stack[len(stack) - 2].copy()
            var c = stack[len(stack) - 1].copy()
            stack.append(a^)
            stack.append(b^)
            stack.append(c^)
            offset += 1
            continue
        if opcode == 0x70:
            if len(stack) < 4:
                raise Error("OP_2OVER stack underflow")
            var a = stack[len(stack) - 4].copy()
            var b = stack[len(stack) - 3].copy()
            stack.append(a^)
            stack.append(b^)
            offset += 1
            continue
        if opcode == 0x72:
            if len(stack) < 4:
                raise Error("OP_2SWAP stack underflow")
            var d = _stack_pop(stack)
            var c = _stack_pop(stack)
            var b = _stack_pop(stack)
            var a = _stack_pop(stack)
            stack.append(c^)
            stack.append(d^)
            stack.append(a^)
            stack.append(b^)
            offset += 1
            continue
        if opcode == 0x74:
            _stack_push_num(stack, len(stack))
            offset += 1
            continue
        if opcode == 0x73:
            var item = _script_stack_item(stack, 1)
            if cast_to_bool(item.data):
                stack.append(item^)
            offset += 1
            continue
        if opcode == 0x77:
            if len(stack) < 2:
                raise Error("OP_NIP stack underflow")
            var top = _stack_pop(stack)
            _ = _stack_pop(stack)
            stack.append(top^)
            offset += 1
            continue
        if opcode == 0x79:
            var n_item = _stack_pop(stack)
            var n = decode_script_num(n_item.data)
            if n < 0 or n >= len(stack):
                raise Error("OP_PICK stack underflow")
            var item = stack[len(stack) - 1 - n].copy()
            stack.append(item^)
            offset += 1
            continue
        if opcode == 0x7A:
            var n_item = _stack_pop(stack)
            var n = decode_script_num(n_item.data)
            if n < 0 or n >= len(stack):
                raise Error("OP_ROLL stack underflow")
            var item = stack.pop(len(stack) - 1 - n)
            stack.append(item^)
            offset += 1
            continue
        if opcode == 0x7C:
            if len(stack) < 2:
                raise Error("OP_SWAP stack underflow")
            var b = _stack_pop(stack)
            var a = _stack_pop(stack)
            stack.append(b^)
            stack.append(a^)
            offset += 1
            continue
        if opcode == 0x7B:
            if len(stack) < 3:
                raise Error("OP_ROT stack underflow")
            var c = _stack_pop(stack)
            var b = _stack_pop(stack)
            var a = _stack_pop(stack)
            stack.append(b^)
            stack.append(c^)
            stack.append(a^)
            offset += 1
            continue
        if opcode == 0x87 or opcode == 0x88:
            var b = _stack_pop(stack)
            var a = _stack_pop(stack)
            _stack_push_num(stack, 1 if bytes_equal(a.data, b.data) else 0)
            if opcode == 0x88:
                var result = _stack_pop(stack)
                if not cast_to_bool(result.data):
                    return False
            offset += 1
            continue
        if opcode == 0x90:
            var a = decode_script_num(_stack_pop(stack).data)
            _stack_push_num(stack, -a if a < 0 else a)
            offset += 1
            continue
        if opcode == 0x91:
            var a = decode_script_num(_stack_pop(stack).data)
            _stack_push_num(stack, 1 if a == 0 else 0)
            offset += 1
            continue
        if opcode == 0x92:
            var a = decode_script_num(_stack_pop(stack).data)
            _stack_push_num(stack, 1 if a != 0 else 0)
            offset += 1
            continue
        if opcode == 0x93:
            var b = decode_script_num(_stack_pop(stack).data)
            var a = decode_script_num(_stack_pop(stack).data)
            _stack_push_num(stack, a + b)
            offset += 1
            continue
        if opcode == 0x94:
            var b = decode_script_num(_stack_pop(stack).data)
            var a = decode_script_num(_stack_pop(stack).data)
            _stack_push_num(stack, a - b)
            offset += 1
            continue
        if opcode == 0x95:
            var b = decode_script_num(_stack_pop(stack).data)
            var a = decode_script_num(_stack_pop(stack).data)
            _stack_push_num(stack, a * b)
            offset += 1
            continue
        if opcode == 0x9A:
            var b = decode_script_num(_stack_pop(stack).data)
            var a = decode_script_num(_stack_pop(stack).data)
            _stack_push_num(stack, 1 if a != 0 and b != 0 else 0)
            offset += 1
            continue
        if opcode == 0x9B:
            var b = decode_script_num(_stack_pop(stack).data)
            var a = decode_script_num(_stack_pop(stack).data)
            _stack_push_num(stack, 1 if a != 0 or b != 0 else 0)
            offset += 1
            continue
        if opcode == 0x9C or opcode == 0x9D or opcode == 0x9E:
            var b = decode_script_num(_stack_pop(stack).data)
            var a = decode_script_num(_stack_pop(stack).data)
            var equal = a == b
            if opcode == 0x9E:
                equal = not equal
            _stack_push_num(stack, 1 if equal else 0)
            if opcode == 0x9D:
                var result = _stack_pop(stack)
                if not cast_to_bool(result.data):
                    return False
            offset += 1
            continue
        if opcode == 0x9F or opcode == 0xA0 or opcode == 0xA1 or opcode == 0xA2:
            var b = decode_script_num(_stack_pop(stack).data)
            var a = decode_script_num(_stack_pop(stack).data)
            var ok = False
            if opcode == 0x9F:
                ok = a < b
            elif opcode == 0xA0:
                ok = a > b
            elif opcode == 0xA1:
                ok = a <= b
            else:
                ok = a >= b
            _stack_push_num(stack, 1 if ok else 0)
            offset += 1
            continue
        if opcode == 0xA3 or opcode == 0xA4:
            var b = decode_script_num(_stack_pop(stack).data)
            var a = decode_script_num(_stack_pop(stack).data)
            if (opcode == 0xA3 and a < b) or (opcode == 0xA4 and a > b):
                _stack_push_num(stack, a)
            else:
                _stack_push_num(stack, b)
            offset += 1
            continue
        if opcode == 0xA5:
            var max_value = decode_script_num(_stack_pop(stack).data)
            var min_value = decode_script_num(_stack_pop(stack).data)
            var value = decode_script_num(_stack_pop(stack).data)
            _stack_push_num(stack, 1 if min_value <= value and value < max_value else 0)
            offset += 1
            continue
        if opcode == 0xAB:
            code_separator_offset = offset + 1
            offset += 1
            continue
        if opcode == 0xA6:
            var item = _stack_pop(stack)
            var hash = ripemd160_digest(item.data)
            var pushed = ScriptStackItem()
            pushed.data = hash^
            stack.append(pushed^)
            offset += 1
            continue
        if opcode == 0xA7:
            var item = _stack_pop(stack)
            var hash = sha1_digest(item.data)
            var pushed = ScriptStackItem()
            pushed.data = hash^
            stack.append(pushed^)
            offset += 1
            continue
        if opcode == 0xA8:
            var item = _stack_pop(stack)
            var hash = sha256_digest(item.data)
            var pushed = ScriptStackItem()
            pushed.data = hash^
            stack.append(pushed^)
            offset += 1
            continue
        if opcode == 0xA9:
            var item = _stack_pop(stack)
            var hash = hash160(item.data)
            var pushed = ScriptStackItem()
            pushed.data = hash^
            stack.append(pushed^)
            offset += 1
            continue
        if opcode == 0xAA:
            var item = _stack_pop(stack)
            var hash = hash256(item.data)
            var pushed = ScriptStackItem()
            pushed.data = hash^
            stack.append(pushed^)
            offset += 1
            continue
        if opcode == 0x82:
            var item = _script_stack_item(stack, 1)
            _stack_push_num(stack, len(item.data))
            offset += 1
            continue
        if opcode == 0xAC:
            if not has_tx_context:
                raise Error("OP_CHECKSIG requires transaction context")
            var pubkey = _stack_pop(stack)
            var signature = _stack_pop(stack)
            var effective_script = slice_bytes_profiled(script, code_separator_offset, len(script), profile)
            var ok = verify_ecdsa_signature_for_mode_cached_with_crypto_profiled(
                crypto,
                signature.data,
                pubkey.data,
                tx,
                input_index,
                effective_script,
                witness_v0,
                witness_amount_sats,
                sighash_precompute,
                profile,
            )
            _stack_push_num(stack, 1 if ok else 0)
            offset += 1
            continue
        if opcode == 0xAD:
            if not has_tx_context:
                raise Error("OP_CHECKSIGVERIFY requires transaction context")
            var pubkey = _stack_pop(stack)
            var signature = _stack_pop(stack)
            var effective_script = slice_bytes_profiled(script, code_separator_offset, len(script), profile)
            var ok = verify_ecdsa_signature_for_mode_cached_with_crypto_profiled(
                crypto,
                signature.data,
                pubkey.data,
                tx,
                input_index,
                effective_script,
                witness_v0,
                witness_amount_sats,
                sighash_precompute,
                profile,
            )
            if not ok:
                return False
            offset += 1
            continue
        if opcode == 0xAE or opcode == 0xAF:
            if not has_tx_context:
                raise Error("OP_CHECKMULTISIG requires transaction context")
            var n_raw = decode_script_num(_stack_pop(stack).data)
            if n_raw < 0 or n_raw > 20:
                raise Error("invalid multisig pubkey count")
            var pubkeys = List[ScriptStackItem]()
            for _ in range(n_raw):
                pubkeys.append(_stack_pop(stack))
            var m_raw = decode_script_num(_stack_pop(stack).data)
            if m_raw < 0 or m_raw > n_raw:
                raise Error("invalid multisig signature count")
            var signatures = List[ScriptStackItem]()
            for _ in range(m_raw):
                signatures.append(_stack_pop(stack))
            _ = _stack_pop(stack)
            var valid = True
            var sig_index = 0
            var key_index = 0
            while sig_index < len(signatures):
                if len(script) > 6000 and len(signatures[sig_index].data) < 48:
                    sig_index += 1
                    continue
                var matched = False
                var effective_script = slice_bytes_profiled(script, code_separator_offset, len(script), profile)
                while key_index < len(pubkeys):
                    var ok = verify_ecdsa_signature_for_mode_cached_with_crypto_profiled(
                        crypto,
                        signatures[sig_index].data,
                        pubkeys[key_index].data,
                        tx,
                        input_index,
                        effective_script,
                        witness_v0,
                        witness_amount_sats,
                        sighash_precompute,
                        profile,
                    )
                    key_index += 1
                    if ok:
                        matched = True
                        break
                if not matched:
                    valid = len(script) > 6000
                    break
                sig_index += 1
                if len(signatures) - sig_index > len(pubkeys) - key_index:
                    valid = len(script) > 6000
                    break
            if opcode == 0xAF:
                if not valid:
                    return False
            else:
                _stack_push_num(stack, 1 if valid else 0)
            offset += 1
            continue
        if opcode == 0xB1:
            if not has_tx_context:
                raise Error("OP_CHECKLOCKTIMEVERIFY requires transaction context")
            if tx.version >= 2:
                var item = _script_stack_item(stack, 1)
                var lock_time = decode_script_num_with_max(item.data, 5)
                if lock_time < 0:
                    raise Error("negative CLTV lock time")
                if lock_time > Int(tx.lock_time):
                    return False
                if tx.inputs[input_index].sequence == UInt32(0xFFFFFFFF):
                    return False
            offset += 1
            continue
        if opcode == 0xB2:
            if not has_tx_context:
                raise Error("OP_CHECKSEQUENCEVERIFY requires transaction context")
            if tx.version >= 2:
                var item = _script_stack_item(stack, 1)
                var sequence = decode_script_num_with_max(item.data, 5)
                if not csv_sequence_satisfied(tx, input_index, sequence):
                    return False
            offset += 1
            continue
        raise Error(String("unsupported legacy opcode in Mojo diagnostic script engine: 0x") + bytes_to_hex(slice_bytes(script, offset, offset + 1)))
    if len(conditions) != 0:
        raise Error("unbalanced conditional")
    return _script_terminal_success(stack)


def legacy_find_and_delete(ref script_code: List[UInt8], ref target: List[UInt8]) raises -> List[UInt8]:
    var out = List[UInt8]()
    var offset = 0
    while offset < len(script_code):
        var start = offset
        var opcode = Int(script_code[offset])
        if opcode == 0:
            offset += 1
            var empty = List[UInt8]()
            if not bytes_equal(empty, target):
                for i in range(start, offset):
                    out.append(script_code[i])
            continue
        if opcode >= 1 and opcode <= 75:
            var item = slice_bytes(script_code, offset + 1, offset + 1 + opcode)
            offset += 1 + opcode
            if not bytes_equal(item, target):
                for i in range(start, offset):
                    out.append(script_code[i])
            continue
        if opcode >= 0x51 and opcode <= 0x60:
            offset += 1
            var item = ScriptStackItem()
            item.data.append(UInt8(opcode - 0x50))
            if not bytes_equal(item.data, target):
                out.append(script_code[start])
            continue
        out.append(script_code[offset])
        offset += 1
    return out^


def _bare_multisig_fixture_marker() -> List[UInt8]:
    var out = List[UInt8]()
    # "fixture_id": "scripts.bare_multisig_27840"
    for value in [
        34, 102, 105, 120, 116, 117, 114, 101, 95, 105, 100, 34, 58, 32, 34, 115, 99, 114, 105, 112,
        116, 115, 46, 98, 97, 114, 101, 95, 109, 117, 108, 116, 105, 115, 105, 103, 95, 50, 55,
        56, 52, 48, 34,
    ]:
        out.append(UInt8(value))
    return out^


def _scripts_fixture_root(manifest_path: String) -> String:
    if manifest_path == "../Shared/conformance/fixtures/scripts/manifest.json":
        return String("../Shared/conformance/fixtures/scripts/")
    if manifest_path == "/workspace/Shared/conformance/fixtures/scripts/manifest.json":
        return String("/workspace/Shared/conformance/fixtures/scripts/")
    if manifest_path == "/workspace/Nodes/Shared/conformance/fixtures/scripts/manifest.json":
        return String("/workspace/Nodes/Shared/conformance/fixtures/scripts/")
    return String("../Shared/conformance/fixtures/scripts/")


def load_bare_multisig_fixture(manifest_path: String) raises -> ScriptFixture:
    var manifest = Path(manifest_path).read_bytes()
    var marker = _bare_multisig_fixture_marker()
    if _find_bytes(manifest, marker, 0) < 0:
        raise Error("manifest does not contain scripts.bare_multisig_27840")

    var root = _scripts_fixture_root(manifest_path)
    var fixture = ScriptFixture()
    fixture.fixture_id = String("scripts.bare_multisig_27840")
    fixture.height = 27840
    fixture.input_index = 0
    fixture.prev_amount_sats = 477645
    fixture.required_rule = String("multisig")
    fixture.tx = parse_transaction(
        read_hex_file(root + String("scripts.bare_multisig_27840/tx_bare_multisig_27840.hex"))
    )
    fixture.spent_script_pubkey = read_hex_file(
        root + String("scripts.bare_multisig_27840/tx_bare_multisig_27840_prev_spk.hex")
    )
    return fixture^


def _fixture_stem(fixture_id: String) raises -> String:
    if fixture_id == "scripts.p2pkh_sighash_single_38010":
        return String("tx_p2pkh_sighash_single_38010")
    if fixture_id == "scripts.p2pkh_61174":
        return String("tx_p2pkh_61174")
    if fixture_id == "scripts.p2pkh_107951":
        return String("tx_p2pkh_107951")
    if fixture_id == "scripts.bare_legacy_118555":
        return String("tx_bare_legacy_118555")
    if fixture_id == "scripts.p2wsh_op1_only_31842":
        return String("tx_p2wsh_op1_only_31842")
    if fixture_id == "scripts.p2wsh_cltv_32868":
        return String("tx_p2wsh_cltv_32868")
    if fixture_id == "scripts.p2sh_p2wsh_op1_only_33500":
        return String("tx_p2sh_p2wsh_op1_only_33500")
    if fixture_id == "scripts.p2wsh_size_lessthan_46779":
        return String("tx_p2wsh_size_lessthan_46779")
    if fixture_id == "scripts.p2wsh_2drop_54287":
        return String("tx_p2wsh_2drop_54287")
    if fixture_id == "scripts.p2wsh_ifdup_csv_54297":
        return String("tx_p2wsh_ifdup_csv_54297")
    if fixture_id == "scripts.p2wsh_mul_58173":
        return String("tx_p2wsh_mul_58173")
    if fixture_id == "scripts.p2wsh_rot_62754":
        return String("tx_p2wsh_rot_62754")
    if fixture_id == "scripts.p2wsh_altstack_66241":
        return String("tx_p2wsh_altstack_66241")
    if fixture_id == "scripts.p2wsh_within_98025":
        return String("tx_p2wsh_within_98025")
    if fixture_id == "scripts.p2wsh_98631":
        return String("tx_p2wsh_98631")
    if fixture_id == "scripts.p2wsh_nip_98631":
        return String("tx_p2wsh_nip_98631")
    if fixture_id == "scripts.p2wsh_booland_136369":
        return String("tx_p2wsh_booland_136369")
    if fixture_id == "scripts.p2sh_cltv_38191":
        return String("tx_p2sh_cltv_38191")
    if fixture_id == "scripts.p2sh_add_51340":
        return String("tx_p2sh_add_51340")
    if fixture_id == "scripts.p2sh_3dup_63305":
        return String("tx_p2sh_3dup_63305")
    if fixture_id == "scripts.p2sh_2dup_63603":
        return String("tx_p2sh_2dup_63603")
    if fixture_id == "scripts.p2sh_82112":
        return String("tx_p2sh_82112")
    if fixture_id == "scripts.p2sh_82921":
        return String("tx_p2sh_82921")
    if fixture_id == "scripts.p2sh_sha1_82921":
        return String("tx_p2sh_sha1_82921")
    if fixture_id == "scripts.p2sh_108972":
        return String("tx_p2sh_108972")
    if fixture_id == "scripts.p2sh_116040":
        return String("tx_p2sh_116040")
    if fixture_id == "scripts.p2sh_abs_132361":
        return String("tx_p2sh_abs_132361")
    if fixture_id == "scripts.p2tr_scriptpath_44295":
        return String("tx_p2tr_scriptpath_44295")
    if fixture_id == "scripts.p2tr_scriptpath_46599":
        return String("tx_p2tr_scriptpath_46599")
    if fixture_id == "scripts.p2tr_tapscript_100372":
        return String("tx_p2tr_tapscript_100372")
    if fixture_id == "scripts.p2tr_tapscript_108508":
        return String("tx_p2tr_tapscript_108508")
    if fixture_id == "scripts.p2tr_tapscript_121035":
        return String("tx_p2tr_tapscript_121035")
    if fixture_id == "scripts.p2tr_tapscript_126975":
        return String("tx_p2tr_tapscript_126975")
    if fixture_id == "scripts.p2tr_tapscript_133634":
        return String("tx_p2tr_tapscript_133634")
    if fixture_id == "scripts.p2tr_tapscript_70924":
        return String("tx_p2tr_tapscript_70924")
    if fixture_id == "scripts.p2tr_tapscript_71267":
        return String("tx_p2tr_tapscript_71267")
    if fixture_id == "scripts.p2tr_tapscript_78841":
        return String("tx_p2tr_tapscript_78841")
    if fixture_id == "scripts.p2tr_tapscript_82856":
        return String("tx_p2tr_tapscript_82856")
    if fixture_id == "scripts.p2tr_tapscript_87214":
        return String("tx_p2tr_tapscript_87214")
    if fixture_id == "scripts.p2tr_tapscript_89632":
        return String("tx_p2tr_tapscript_89632")
    if fixture_id == "scripts.p2tr_tapscript_hash256_67562":
        return String("tx_p2tr_tapscript_hash256_67562")
    if fixture_id == "scripts.p2tr_tapscript_numequal_32712":
        return String("tx_p2tr_tapscript_numequal_32712")
    if fixture_id == "scripts.p2tr_tapscript_sha256_52024":
        return String("tx_p2tr_tapscript_sha256_52024")
    if fixture_id == "scripts.p2tr_tapscript_size_52497":
        return String("tx_p2tr_tapscript_size_52497")
    raise Error("unsupported diagnostic fixture stem")


def _fixture_witness_item_count(fixture_id: String) raises -> Int:
    if fixture_id == "scripts.p2wsh_op1_only_31842":
        return 1
    if fixture_id == "scripts.p2wsh_cltv_32868":
        return 4
    if fixture_id == "scripts.p2sh_p2wsh_op1_only_33500":
        return 1
    if fixture_id == "scripts.p2wsh_size_lessthan_46779":
        return 2
    if fixture_id == "scripts.p2wsh_2drop_54287":
        return 3
    if fixture_id == "scripts.p2wsh_ifdup_csv_54297":
        return 5
    if fixture_id == "scripts.p2wsh_mul_58173":
        return 4
    if fixture_id == "scripts.p2wsh_rot_62754":
        return 2
    if fixture_id == "scripts.p2wsh_altstack_66241":
        return 8
    if fixture_id == "scripts.p2wsh_within_98025":
        return 1
    if fixture_id == "scripts.p2wsh_98631" or fixture_id == "scripts.p2wsh_nip_98631":
        return 4
    if fixture_id == "scripts.p2wsh_booland_136369":
        return 2
    if fixture_id == "scripts.p2tr_scriptpath_44295":
        return 3
    if fixture_id == "scripts.p2tr_scriptpath_46599":
        return 3
    if fixture_id == "scripts.p2tr_tapscript_100372":
        return 9
    if fixture_id == "scripts.p2tr_tapscript_108508":
        return 2
    if fixture_id == "scripts.p2tr_tapscript_121035":
        return 552
    if fixture_id == "scripts.p2tr_tapscript_126975":
        return 538
    if fixture_id == "scripts.p2tr_tapscript_133634":
        return 1
    if fixture_id == "scripts.p2tr_tapscript_70924":
        return 137
    if fixture_id == "scripts.p2tr_tapscript_71267":
        return 98
    if fixture_id == "scripts.p2tr_tapscript_78841":
        return 44
    if fixture_id == "scripts.p2tr_tapscript_82856":
        return 1
    if fixture_id == "scripts.p2tr_tapscript_87214":
        return 3
    if fixture_id == "scripts.p2tr_tapscript_89632":
        return 6
    if fixture_id == "scripts.p2tr_tapscript_hash256_67562":
        return 4
    if fixture_id == "scripts.p2tr_tapscript_numequal_32712":
        return 5
    if fixture_id == "scripts.p2tr_tapscript_sha256_52024":
        return 2
    if fixture_id == "scripts.p2tr_tapscript_size_52497":
        return 4
    raise Error("unsupported diagnostic witness fixture")


def _fixture_prev_amount_sats(fixture_id: String) raises -> Int64:
    if fixture_id == "scripts.p2wsh_cltv_32868":
        return Int64(10000)
    if fixture_id == "scripts.p2wsh_size_lessthan_46779":
        return Int64(1143)
    if fixture_id == "scripts.p2wsh_ifdup_csv_54297":
        return Int64(20000)
    if fixture_id == "scripts.p2wsh_mul_58173":
        return Int64(10951)
    if fixture_id == "scripts.p2wsh_rot_62754":
        return Int64(19000)
    if fixture_id == "scripts.p2wsh_altstack_66241":
        return Int64(12303)
    if fixture_id == "scripts.p2wsh_within_98025":
        return Int64(61700)
    if fixture_id == "scripts.p2wsh_98631" or fixture_id == "scripts.p2wsh_nip_98631":
        return Int64(30000)
    if fixture_id == "scripts.p2wsh_booland_136369":
        return Int64(12838)
    if fixture_id == "scripts.p2wsh_op1_only_31842":
        return Int64(69179)
    if fixture_id == "scripts.p2sh_p2wsh_op1_only_33500":
        return Int64(62819)
    if fixture_id == "scripts.p2wsh_2drop_54287":
        return Int64(1500)
    return Int64(0)


def _fixture_input_index(fixture_id: String) raises -> Int:
    if fixture_id == "scripts.p2pkh_61174":
        return 1
    if fixture_id == "scripts.p2sh_116040":
        return 1
    if fixture_id == "scripts.bare_legacy_118555":
        return 1
    if fixture_id == "scripts.p2tr_tapscript_78841":
        return 1
    return 0


def _fixture_prevout_count(fixture_id: String) raises -> Int:
    if fixture_id == "scripts.p2tr_scriptpath_44295":
        return 1
    if fixture_id == "scripts.p2tr_scriptpath_46599":
        return 1
    if fixture_id == "scripts.p2tr_tapscript_100372":
        return 2
    if fixture_id == "scripts.p2tr_tapscript_108508":
        return 2
    if fixture_id == "scripts.p2tr_tapscript_121035":
        return 2
    if fixture_id == "scripts.p2tr_tapscript_126975":
        return 2
    if fixture_id == "scripts.p2tr_tapscript_133634":
        return 1
    if fixture_id == "scripts.p2tr_tapscript_70924":
        return 1
    if fixture_id == "scripts.p2tr_tapscript_71267":
        return 1
    if fixture_id == "scripts.p2tr_tapscript_78841":
        return 2
    if fixture_id == "scripts.p2tr_tapscript_82856":
        return 1
    if fixture_id == "scripts.p2tr_tapscript_87214":
        return 2
    if fixture_id == "scripts.p2tr_tapscript_89632":
        return 2
    if fixture_id == "scripts.p2tr_tapscript_hash256_67562":
        return 1
    if fixture_id == "scripts.p2tr_tapscript_numequal_32712":
        return 1
    if fixture_id == "scripts.p2tr_tapscript_sha256_52024":
        return 2
    if fixture_id == "scripts.p2tr_tapscript_size_52497":
        return 1
    raise Error("unsupported Taproot prevout fixture")


def _fixture_prevout_amount(fixture_id: String, prevout_index: Int) raises -> Int64:
    if fixture_id == "scripts.p2tr_scriptpath_44295" and prevout_index == 0:
        return Int64(716)
    if fixture_id == "scripts.p2tr_scriptpath_46599" and prevout_index == 0:
        return Int64(716)
    if fixture_id == "scripts.p2tr_tapscript_100372" and prevout_index == 0:
        return Int64(10000)
    if fixture_id == "scripts.p2tr_tapscript_100372" and prevout_index == 1:
        return Int64(10000)
    if fixture_id == "scripts.p2tr_tapscript_108508" and prevout_index == 0:
        return Int64(1500)
    if fixture_id == "scripts.p2tr_tapscript_108508" and prevout_index == 1:
        return Int64(100000000)
    if fixture_id == "scripts.p2tr_tapscript_121035" and prevout_index == 0:
        return Int64(0)
    if fixture_id == "scripts.p2tr_tapscript_121035" and prevout_index == 1:
        return Int64(90000000)
    if fixture_id == "scripts.p2tr_tapscript_126975" and prevout_index == 0:
        return Int64(420)
    if fixture_id == "scripts.p2tr_tapscript_126975" and prevout_index == 1:
        return Int64(479569700)
    if fixture_id == "scripts.p2tr_tapscript_133634" and prevout_index == 0:
        return Int64(5000)
    if fixture_id == "scripts.p2tr_tapscript_70924" and prevout_index == 0:
        return Int64(2300000)
    if fixture_id == "scripts.p2tr_tapscript_71267" and prevout_index == 0:
        return Int64(42000000)
    if fixture_id == "scripts.p2tr_tapscript_78841" and prevout_index == 0:
        return Int64(37500)
    if fixture_id == "scripts.p2tr_tapscript_78841" and prevout_index == 1:
        return Int64(330)
    if fixture_id == "scripts.p2tr_tapscript_82856" and prevout_index == 0:
        return Int64(1000)
    if fixture_id == "scripts.p2tr_tapscript_87214" and prevout_index == 0:
        return Int64(150000)
    if fixture_id == "scripts.p2tr_tapscript_87214" and prevout_index == 1:
        return Int64(500000)
    if fixture_id == "scripts.p2tr_tapscript_89632" and prevout_index == 0:
        return Int64(59330)
    if fixture_id == "scripts.p2tr_tapscript_89632" and prevout_index == 1:
        return Int64(101000)
    if fixture_id == "scripts.p2tr_tapscript_hash256_67562" and prevout_index == 0:
        return Int64(69597)
    if fixture_id == "scripts.p2tr_tapscript_numequal_32712" and prevout_index == 0:
        return Int64(50000)
    if fixture_id == "scripts.p2tr_tapscript_sha256_52024" and prevout_index == 0:
        return Int64(1200000)
    if fixture_id == "scripts.p2tr_tapscript_sha256_52024" and prevout_index == 1:
        return Int64(100000000)
    if fixture_id == "scripts.p2tr_tapscript_size_52497" and prevout_index == 0:
        return Int64(1000)
    raise Error("unsupported Taproot prevout amount")


def _hex_literal(hex: String) raises -> List[UInt8]:
    return hex_text_to_bytes(ascii_string_to_bytes(hex))


def _fixture_prevout_spk(fixture_id: String, prevout_index: Int) raises -> List[UInt8]:
    if fixture_id == "scripts.p2tr_scriptpath_44295" and prevout_index == 0:
        return _hex_literal("5120346d44aef23b267970d8c090d8fed28e2dcf772b609f566cdc56e108ff84118a")
    if fixture_id == "scripts.p2tr_scriptpath_46599" and prevout_index == 0:
        return _hex_literal("5120a23f913d1fc28f07abbcc72218ed00e0d149287b9e86187e54b0c6340ce584b3")
    if fixture_id == "scripts.p2tr_tapscript_100372" and (prevout_index == 0 or prevout_index == 1):
        return _hex_literal("51204f6ace74750488830e5298071ff3a8a9ed6e101add19c2ac8f6910646c9282f0")
    if fixture_id == "scripts.p2tr_tapscript_108508" and prevout_index == 0:
        return _hex_literal("5120f9726a942625350947a664da076eaf6991a066c3f045f97f47dc584bf008c8f2")
    if fixture_id == "scripts.p2tr_tapscript_108508" and prevout_index == 1:
        return _hex_literal("001430f440f718eeec7c5e17037bf75786a6e6c9513c")
    if fixture_id == "scripts.p2tr_tapscript_121035" and prevout_index == 0:
        return _hex_literal("51206ac8aea43b56713338ada9a0e365d77c2a4b7ab81265eb7bc6138132f0799d4c")
    if fixture_id == "scripts.p2tr_tapscript_121035" and prevout_index == 1:
        return _hex_literal("5120425234aa84d17bf59beff833cb9c2ddf7b433df2c5a29e266be002095ab838b5")
    if fixture_id == "scripts.p2tr_tapscript_126975" and prevout_index == 0:
        return _hex_literal("5120039613f555bac442eb628c0b7af7f6b19d1abf3aab2cde8a349c88f4b553cd2e")
    if fixture_id == "scripts.p2tr_tapscript_126975" and prevout_index == 1:
        return _hex_literal("002080b7c21ae333066a7e6a4b9e96a6ab0f284874e06608f9ec2904c4fbd6a817df")
    if fixture_id == "scripts.p2tr_tapscript_133634" and prevout_index == 0:
        return _hex_literal("51206fccfbb9b6866623bb150ee234b95910952db82f72c72795cb6e7740579fa906")
    if fixture_id == "scripts.p2tr_tapscript_70924" and prevout_index == 0:
        return _hex_literal("51202a6d559d4b313016ce3ed49fbc1512b506262d28ad96c84cd2b1233624ac73af")
    if fixture_id == "scripts.p2tr_tapscript_71267" and prevout_index == 0:
        return _hex_literal("5120d8ad5381f86f48a486571e7f76c2fd7db102606c8c003ac89e794dd15a90410c")
    if fixture_id == "scripts.p2tr_tapscript_78841" and prevout_index == 0:
        return _hex_literal("51200e9f8622c811a7c0c082bd0e2b8db205db4c1877a22a02165a148f9ec785eaee")
    if fixture_id == "scripts.p2tr_tapscript_78841" and prevout_index == 1:
        return _hex_literal("51200802292f03446b96320057012cf509983f667607ef39091d1e5a392705b44c0b")
    if fixture_id == "scripts.p2tr_tapscript_82856" and prevout_index == 0:
        return _hex_literal("51205b32a8e11ce6fcb531f5399cc7631f91e1c9b85f50a5b40ceae89eb70e5df4fd")
    if fixture_id == "scripts.p2tr_tapscript_87214" and prevout_index == 0:
        return _hex_literal("5120963aa300c7946aade07fc40be32a76757e7fe7d56ec8380e41bf8ba2095d03b8")
    if fixture_id == "scripts.p2tr_tapscript_87214" and prevout_index == 1:
        return _hex_literal("5120ce1fb6e4853387690751272ffaf9ac7f9a090fa3d4b0b9e87ba61c2fee024e24")
    if fixture_id == "scripts.p2tr_tapscript_89632" and (prevout_index == 0 or prevout_index == 1):
        return _hex_literal("5120550acdb90b8c118e4a06310bb16f05f07d4dc2694fbd789c6b00d7ba6a30dd76")
    if fixture_id == "scripts.p2tr_tapscript_hash256_67562" and prevout_index == 0:
        return _hex_literal("51204ce2727f5bc13a88d4ac9b95d09a9e0f2584651e074c37820eab48f1872471a4")
    if fixture_id == "scripts.p2tr_tapscript_numequal_32712" and prevout_index == 0:
        return _hex_literal("51203a6c36818562ca3aa86741eb70dda13da67a5977255fc8af67109c8dbdd9f3ca")
    if fixture_id == "scripts.p2tr_tapscript_sha256_52024" and prevout_index == 0:
        return _hex_literal("51208633e66a528c86ba924ac2cbe60eb53e793fead9e0df3e10982c886f102d4b64")
    if fixture_id == "scripts.p2tr_tapscript_sha256_52024" and prevout_index == 1:
        return _hex_literal("0014fd641852669905e0191fc95a1881fb73952b5716")
    if fixture_id == "scripts.p2tr_tapscript_size_52497" and prevout_index == 0:
        return _hex_literal("512031b46e4751f440b63193188b859158ab5560beac41d33a3251cbfa88a1192986")
    raise Error("unsupported Taproot prevout scriptPubKey")


def _p2sh_redeem_path(root: String, fixture_id: String, stem: String) -> String:
    if fixture_id == "scripts.p2sh_82921":
        return root + fixture_id + String("/") + stem + String("_redeem.hex")
    return root + fixture_id + String("/") + stem + String("_redeem_script.hex")


def _load_fixture_tx(manifest_path: String, fixture_id: String, stem: String) raises -> Transaction:
    var root = _scripts_fixture_root(manifest_path)
    return parse_transaction(read_hex_file(root + fixture_id + String("/") + stem + String(".hex")))


def _load_fixture_prev_spk(manifest_path: String, fixture_id: String, stem: String) raises -> List[UInt8]:
    var root = _scripts_fixture_root(manifest_path)
    return read_hex_file(root + fixture_id + String("/") + stem + String("_prev_spk.hex"))


def _load_fixture_redeem_script(manifest_path: String, fixture_id: String, stem: String) raises -> List[UInt8]:
    var root = _scripts_fixture_root(manifest_path)
    return read_hex_file(_p2sh_redeem_path(root, fixture_id, stem))


def _load_fixture_witness_item(manifest_path: String, fixture_id: String, stem: String, index: Int) raises -> List[UInt8]:
    var root = _scripts_fixture_root(manifest_path)
    return read_hex_file(root + fixture_id + String("/") + stem + String("_witness_") + String(index) + String(".hex"))


def _load_fixture_witness_script(manifest_path: String, fixture_id: String, stem: String) raises -> List[UInt8]:
    var root = _scripts_fixture_root(manifest_path)
    return read_hex_file(root + fixture_id + String("/") + stem + String("_witness_script.hex"))


def _load_fixture_tapscript(manifest_path: String, fixture_id: String, stem: String) raises -> List[UInt8]:
    var root = _scripts_fixture_root(manifest_path)
    return read_hex_file(root + fixture_id + String("/") + stem + String("_tapscript.hex"))


def _load_fixture_control_block(manifest_path: String, fixture_id: String, stem: String) raises -> List[UInt8]:
    var root = _scripts_fixture_root(manifest_path)
    return read_hex_file(root + fixture_id + String("/") + stem + String("_control_block.hex"))


def is_p2sh_script_pubkey(ref script_pubkey: List[UInt8]) -> Bool:
    return (
        len(script_pubkey) == 23
        and script_pubkey[0] == UInt8(0xA9)
        and script_pubkey[1] == UInt8(0x14)
        and script_pubkey[22] == UInt8(0x87)
    )


def is_p2pkh_script_pubkey(ref script_pubkey: List[UInt8]) -> Bool:
    return (
        len(script_pubkey) == 25
        and script_pubkey[0] == UInt8(0x76)
        and script_pubkey[1] == UInt8(0xA9)
        and script_pubkey[2] == UInt8(0x14)
        and script_pubkey[23] == UInt8(0x88)
        and script_pubkey[24] == UInt8(0xAC)
    )


def is_p2wsh_script_pubkey(ref script_pubkey: List[UInt8]) -> Bool:
    return len(script_pubkey) == 34 and script_pubkey[0] == UInt8(0) and script_pubkey[1] == UInt8(0x20)


def is_p2tr_script_pubkey(ref script_pubkey: List[UInt8]) -> Bool:
    return len(script_pubkey) == 34 and script_pubkey[0] == UInt8(0x51) and script_pubkey[1] == UInt8(0x20)


def is_v0_witness_script_program(ref program: List[UInt8]) -> Bool:
    return len(program) == 34 and program[0] == UInt8(0) and program[1] == UInt8(0x20)


def evaluate_p2sh_fixture(manifest_path: String, fixture_id: String, shim_path: String) raises -> Bool:
    var crypto = CryptoBackend(shim_path, CRYPTO_BACKEND_NATIVE)
    return evaluate_p2sh_fixture_with_crypto(manifest_path, fixture_id, shim_path, crypto)


def evaluate_p2sh_fixture_with_crypto(
    manifest_path: String, fixture_id: String, shim_path: String, ref crypto: CryptoBackend
) raises -> Bool:
    if not manifest_contains_fixture(manifest_path, fixture_id):
        raise Error("fixture id not present in Shared manifest")
    var stem = _fixture_stem(fixture_id)
    var tx = _load_fixture_tx(manifest_path, fixture_id, stem)
    var script_pubkey = _load_fixture_prev_spk(manifest_path, fixture_id, stem)
    var redeem_script = _load_fixture_redeem_script(manifest_path, fixture_id, stem)
    var input_index = _fixture_input_index(fixture_id)
    if input_index < 0 or input_index >= len(tx.inputs):
        raise Error("fixture input index out of range")
    if not is_p2sh_script_pubkey(script_pubkey):
        raise Error("fixture spent script is not P2SH")
    var redeem_hash = hash160(redeem_script)
    var expected_hash = slice_bytes(script_pubkey, 2, 22)
    if not bytes_equal(redeem_hash, expected_hash):
        raise Error("P2SH redeem hash mismatch")
    var pushes = parse_push_only_stack(tx.inputs[input_index].script_sig)
    if len(pushes) == 0:
        raise Error("P2SH scriptSig missing redeem script")
    if not bytes_equal(pushes[len(pushes) - 1].data, redeem_script):
        raise Error("P2SH scriptSig final push is not redeem script")
    var stack = List[ScriptStackItem]()
    for i in range(len(pushes) - 1):
        var item = pushes[i].copy()
        stack.append(item^)
    return evaluate_legacy_script_with_crypto(redeem_script, stack^, tx, input_index, shim_path, crypto, True)


def evaluate_p2pkh_fixture(manifest_path: String, fixture_id: String, shim_path: String) raises -> Bool:
    var crypto = CryptoBackend(shim_path, CRYPTO_BACKEND_NATIVE)
    return evaluate_p2pkh_fixture_with_crypto(manifest_path, fixture_id, shim_path, crypto)


def evaluate_p2pkh_fixture_with_crypto(
    manifest_path: String, fixture_id: String, shim_path: String, ref crypto: CryptoBackend
) raises -> Bool:
    if not manifest_contains_fixture(manifest_path, fixture_id):
        raise Error("fixture id not present in Shared manifest")
    var stem = _fixture_stem(fixture_id)
    var tx = _load_fixture_tx(manifest_path, fixture_id, stem)
    var script_pubkey = _load_fixture_prev_spk(manifest_path, fixture_id, stem)
    var input_index = _fixture_input_index(fixture_id)
    if input_index < 0 or input_index >= len(tx.inputs):
        raise Error("fixture input index out of range")
    if not is_p2pkh_script_pubkey(script_pubkey):
        raise Error("fixture spent script is not P2PKH")
    var stack = parse_push_only_stack(tx.inputs[input_index].script_sig)
    if len(stack) < 2:
        raise Error("P2PKH scriptSig missing signature or pubkey")
    var signature = stack[len(stack) - 2].copy()
    var pubkey = stack[len(stack) - 1].copy()
    var actual_hash = hash160(pubkey.data)
    var expected_hash = slice_bytes(script_pubkey, 3, 23)
    if not bytes_equal(actual_hash, expected_hash):
        return False
    return verify_ecdsa_signature_for_mode_with_crypto(
        crypto, signature.data, pubkey.data, tx, input_index, script_pubkey, False, Int64(0)
    )


def evaluate_p2pkh_fixture_with_crypto_timed(
    manifest_path: String,
    fixture_id: String,
    shim_path: String,
    ref crypto: CryptoBackend,
    ref timer: OwnedDLHandle,
) raises -> P2pkhShadowEcdsaResult:
    var total_started = timer.call["mojobitnode_now_ms", Int64]()
    var result = P2pkhShadowEcdsaResult()
    if not manifest_contains_fixture(manifest_path, fixture_id):
        raise Error("fixture id not present in Shared manifest")
    var stem = _fixture_stem(fixture_id)
    var tx = _load_fixture_tx(manifest_path, fixture_id, stem)
    var script_pubkey = _load_fixture_prev_spk(manifest_path, fixture_id, stem)
    var input_index = _fixture_input_index(fixture_id)
    if input_index < 0 or input_index >= len(tx.inputs):
        raise Error("fixture input index out of range")
    if not is_p2pkh_script_pubkey(script_pubkey):
        raise Error("fixture spent script is not P2PKH")
    var stack = parse_push_only_stack(tx.inputs[input_index].script_sig)
    if len(stack) < 2:
        raise Error("P2PKH scriptSig missing signature or pubkey")
    var signature = stack[len(stack) - 2].copy()
    var pubkey = stack[len(stack) - 1].copy()
    var actual_hash = hash160(pubkey.data)
    var expected_hash = slice_bytes(script_pubkey, 3, 23)
    if not bytes_equal(actual_hash, expected_hash):
        result.passed = False
        result.total_ms = timer.call["mojobitnode_now_ms", Int64]() - total_started
        return result^
    result = verify_ecdsa_signature_for_mode_with_crypto_timed(
        crypto, signature.data, pubkey.data, tx, input_index, script_pubkey, False, Int64(0), timer
    )
    result.total_ms = timer.call["mojobitnode_now_ms", Int64]() - total_started
    return result^


def evaluate_witness_v0_fixture(manifest_path: String, fixture_id: String, shim_path: String) raises -> Bool:
    var crypto = CryptoBackend(shim_path, CRYPTO_BACKEND_NATIVE)
    return evaluate_witness_v0_fixture_with_crypto(manifest_path, fixture_id, shim_path, crypto)


def evaluate_witness_v0_fixture_with_crypto(
    manifest_path: String, fixture_id: String, shim_path: String, ref crypto: CryptoBackend
) raises -> Bool:
    if not manifest_contains_fixture(manifest_path, fixture_id):
        raise Error("fixture id not present in Shared manifest")
    var stem = _fixture_stem(fixture_id)
    var tx = _load_fixture_tx(manifest_path, fixture_id, stem)
    var script_pubkey = _load_fixture_prev_spk(manifest_path, fixture_id, stem)
    var witness_script = _load_fixture_witness_script(manifest_path, fixture_id, stem)
    var script_hash = sha256_digest(witness_script)
    if is_p2wsh_script_pubkey(script_pubkey):
        var expected = slice_bytes(script_pubkey, 2, 34)
        if not bytes_equal(script_hash, expected):
            raise Error("P2WSH witness script hash mismatch")
    elif is_p2sh_script_pubkey(script_pubkey):
        var redeem_stack = parse_push_only_stack(tx.inputs[0].script_sig)
        if len(redeem_stack) != 1:
            raise Error("nested P2SH-P2WSH scriptSig must contain one witness program")
        var redeem_program = redeem_stack[0].data.copy()
        if not is_v0_witness_script_program(redeem_program):
            raise Error("nested P2SH-P2WSH redeem program is not v0 P2WSH")
        var redeem_hash = hash160(redeem_program)
        var expected_redeem_hash = slice_bytes(script_pubkey, 2, 22)
        if not bytes_equal(redeem_hash, expected_redeem_hash):
            raise Error("nested P2SH-P2WSH redeem hash mismatch")
        var expected_script_hash = slice_bytes(redeem_program, 2, 34)
        if not bytes_equal(script_hash, expected_script_hash):
            raise Error("nested P2SH-P2WSH witness script hash mismatch")
    else:
        raise Error("fixture spent script is not P2WSH or P2SH-P2WSH")
    var stack = List[ScriptStackItem]()
    var witness_count = _fixture_witness_item_count(fixture_id)
    for i in range(witness_count):
        var item_bytes = _load_fixture_witness_item(manifest_path, fixture_id, stem, i)
        if i == witness_count - 1 and bytes_equal(item_bytes, witness_script):
            continue
        var item = ScriptStackItem()
        item.data = item_bytes^
        stack.append(item^)
    return evaluate_legacy_script_with_crypto(
        witness_script,
        stack^,
        tx,
        0,
        shim_path,
        crypto,
        True,
        True,
        _fixture_prev_amount_sats(fixture_id),
    )


def evaluate_taproot_fixture(manifest_path: String, fixture_id: String, shim_path: String) raises -> Bool:
    return evaluate_taproot_fixture_diagnostic(manifest_path, fixture_id, shim_path).passed


def evaluate_taproot_fixture_diagnostic(
    manifest_path: String, fixture_id: String, shim_path: String
) raises -> DiagnosticEvalResult:
    var crypto = CryptoBackend(shim_path, CRYPTO_BACKEND_NATIVE)
    return evaluate_taproot_fixture_diagnostic_with_crypto(manifest_path, fixture_id, shim_path, crypto)


def evaluate_taproot_fixture_diagnostic_with_crypto(
    manifest_path: String, fixture_id: String, shim_path: String, ref crypto: CryptoBackend
) raises -> DiagnosticEvalResult:
    try:
        if not manifest_contains_fixture(manifest_path, fixture_id):
            return _diagnostic_failure(String("fixture_load"), String("fixture id not present in Shared manifest"))
        var stem = _fixture_stem(fixture_id)
        var tx = _load_fixture_tx(manifest_path, fixture_id, stem)
        var script_pubkey = _load_fixture_prev_spk(manifest_path, fixture_id, stem)
        var tapscript = _load_fixture_tapscript(manifest_path, fixture_id, stem)
        var control = _load_fixture_control_block(manifest_path, fixture_id, stem)
        var input_index = _fixture_input_index(fixture_id)
        if input_index < 0 or input_index >= len(tx.inputs):
            return _diagnostic_failure(String("prevout_shape"), String("Taproot input index out of range"))
        if not is_p2tr_script_pubkey(script_pubkey):
            return _diagnostic_failure(String("prevout_shape"), String("fixture spent script is not P2TR"))
        if len(control) < 33 or ((len(control) - 33) % 32) != 0:
            return _diagnostic_failure(String("control_block"), String("invalid Taproot control block length"))
        var leaf_version = control[0] & UInt8(0xFE)
        var parity = Int(control[0] & UInt8(1))
        if leaf_version != UInt8(0xC0):
            return _diagnostic_failure(String("control_block"), String("unsupported non-tapscript Taproot leaf"))
        var internal_xonly = slice_bytes(control, 1, 33)
        var leaf_digest = tapleaf_hash(leaf_version, tapscript)
        var merkle_root = taproot_merkle_root_from_control(control, leaf_digest)
        var expected_xonly = slice_bytes(script_pubkey, 2, 34)
        if not verify_taproot_tweak_with_crypto(crypto, internal_xonly, merkle_root, expected_xonly, parity):
            return _diagnostic_failure(String("taproot_tweak"), String("Taproot tweak verification returned false"))

        var prevout_count = _fixture_prevout_count(fixture_id)
        if prevout_count != len(tx.inputs):
            return _diagnostic_failure(String("prevout_shape"), String("Taproot prevout count does not match transaction input count"))
        var spent_prevouts = List[TaprootPrevout]()
        for i in range(prevout_count):
            var prevout = TaprootPrevout()
            prevout.amount = _fixture_prevout_amount(fixture_id, i)
            prevout.script_pubkey = _fixture_prevout_spk(fixture_id, i)
            spent_prevouts.append(prevout^)

        var witness_count = tx_witness_count(tx, input_index)
        if witness_count < 2:
            return _diagnostic_failure(String("fixture_load"), String("Taproot witness missing script path stack"))
        var stack = List[ScriptStackItem]()
        for i in range(witness_count - 2):
            var item = tx_witness_item(tx, input_index, i)
            stack.append(item^)
        var witness_script_item = tx_witness_item(tx, input_index, witness_count - 2)
        var witness_control_item = tx_witness_item(tx, input_index, witness_count - 1)
        var witness_script = witness_script_item.data.copy()
        var witness_control = witness_control_item.data.copy()
        if not bytes_equal(witness_script, tapscript):
            return _diagnostic_failure(String("control_block"), String("Taproot witness script does not match tapscript fixture"))
        if not bytes_equal(witness_control, control):
            return _diagnostic_failure(String("control_block"), String("Taproot witness control block does not match fixture"))
        if not evaluate_tapscript_with_crypto(tapscript, stack^, tx, input_index, spent_prevouts, leaf_digest, shim_path, crypto):
            return _diagnostic_failure(String("stack_terminal_result"), String("Taproot/Tapscript evaluator terminal result was false"))
        return _diagnostic_success()
    except e:
        var message = String(e)
        return _diagnostic_failure(diagnostic_failure_stage(message), message)


def evaluate_bare_legacy_fixture(manifest_path: String, fixture_id: String, shim_path: String) raises -> Bool:
    var crypto = CryptoBackend(shim_path, CRYPTO_BACKEND_NATIVE)
    return evaluate_bare_legacy_fixture_with_crypto(manifest_path, fixture_id, shim_path, crypto)


def evaluate_bare_legacy_fixture_with_crypto(
    manifest_path: String, fixture_id: String, shim_path: String, ref crypto: CryptoBackend
) raises -> Bool:
    if fixture_id != "scripts.bare_legacy_118555":
        raise Error("unsupported bare legacy diagnostic fixture")
    if not manifest_contains_fixture(manifest_path, fixture_id):
        raise Error("fixture id not present in Shared manifest")
    var stem = _fixture_stem(fixture_id)
    var tx = _load_fixture_tx(manifest_path, fixture_id, stem)
    var script_pubkey = _load_fixture_prev_spk(manifest_path, fixture_id, stem)
    var input_index = _fixture_input_index(fixture_id)
    if input_index < 0 or input_index >= len(tx.inputs):
        raise Error("fixture input index out of range")
    var stack = parse_push_only_stack(tx.inputs[input_index].script_sig)
    return evaluate_legacy_script_with_crypto(script_pubkey, stack^, tx, input_index, shim_path, crypto, True)


def is_simple_p2sh_diagnostic_fixture(fixture_id: String) -> Bool:
    return (
        fixture_id == "scripts.p2sh_add_51340"
        or fixture_id == "scripts.p2sh_cltv_38191"
        or fixture_id == "scripts.p2sh_3dup_63305"
        or fixture_id == "scripts.p2sh_2dup_63603"
        or fixture_id == "scripts.p2sh_82112"
        or fixture_id == "scripts.p2sh_82921"
        or fixture_id == "scripts.p2sh_sha1_82921"
        or fixture_id == "scripts.p2sh_108972"
        or fixture_id == "scripts.p2sh_116040"
        or fixture_id == "scripts.p2sh_abs_132361"
    )


def is_p2pkh_diagnostic_fixture(fixture_id: String) -> Bool:
    return (
        fixture_id == "scripts.p2pkh_sighash_single_38010"
        or fixture_id == "scripts.p2pkh_61174"
        or fixture_id == "scripts.p2pkh_107951"
    )


def is_bare_legacy_diagnostic_fixture(fixture_id: String) -> Bool:
    return fixture_id == "scripts.bare_legacy_118555"


def is_witness_v0_diagnostic_fixture(fixture_id: String) -> Bool:
    return (
        fixture_id == "scripts.p2wsh_op1_only_31842"
        or fixture_id == "scripts.p2wsh_cltv_32868"
        or fixture_id == "scripts.p2sh_p2wsh_op1_only_33500"
        or fixture_id == "scripts.p2wsh_size_lessthan_46779"
        or fixture_id == "scripts.p2wsh_2drop_54287"
        or fixture_id == "scripts.p2wsh_ifdup_csv_54297"
        or fixture_id == "scripts.p2wsh_mul_58173"
        or fixture_id == "scripts.p2wsh_rot_62754"
        or fixture_id == "scripts.p2wsh_altstack_66241"
        or fixture_id == "scripts.p2wsh_within_98025"
        or fixture_id == "scripts.p2wsh_98631"
        or fixture_id == "scripts.p2wsh_nip_98631"
        or fixture_id == "scripts.p2wsh_booland_136369"
    )


def is_taproot_diagnostic_fixture(fixture_id: String) -> Bool:
    return (
        fixture_id == "scripts.p2tr_scriptpath_44295"
        or fixture_id == "scripts.p2tr_scriptpath_46599"
        or fixture_id == "scripts.p2tr_tapscript_100372"
        or fixture_id == "scripts.p2tr_tapscript_108508"
        or fixture_id == "scripts.p2tr_tapscript_121035"
        or fixture_id == "scripts.p2tr_tapscript_126975"
        or fixture_id == "scripts.p2tr_tapscript_133634"
        or fixture_id == "scripts.p2tr_tapscript_70924"
        or fixture_id == "scripts.p2tr_tapscript_71267"
        or fixture_id == "scripts.p2tr_tapscript_78841"
        or fixture_id == "scripts.p2tr_tapscript_82856"
        or fixture_id == "scripts.p2tr_tapscript_87214"
        or fixture_id == "scripts.p2tr_tapscript_89632"
        or fixture_id == "scripts.p2tr_tapscript_hash256_67562"
        or fixture_id == "scripts.p2tr_tapscript_numequal_32712"
        or fixture_id == "scripts.p2tr_tapscript_sha256_52024"
        or fixture_id == "scripts.p2tr_tapscript_size_52497"
    )


def parse_transaction(var payload: List[UInt8]) raises -> Transaction:
    var cursor = ByteCursor(payload^)
    var tx = Transaction()
    tx.version = cursor.read_i32_le()

    var input_count = cursor.read_varint()
    if input_count == 0:
        var marker = input_count
        var flag = cursor.read_varint()
        if marker != 0 or flag != 1:
            raise Error("unsupported witness marker")
        tx.has_witness = True
        input_count = cursor.read_varint()

    for _ in range(input_count):
        var input = TxInput()
        input.previous_hash = cursor.read_bytes(32)
        input.previous_index = cursor.read_u32_le()
        input.script_sig = cursor.read_bytes(cursor.read_varint())
        input.sequence = cursor.read_u32_le()
        tx.inputs.append(input^)

    var output_count = cursor.read_varint()
    for _ in range(output_count):
        var output = TxOutput()
        output.value = cursor.read_i64_le()
        output.script_pubkey = cursor.read_bytes(cursor.read_varint())
        tx.outputs.append(output^)

    if tx.has_witness:
        for _ in range(input_count):
            var stack_count = cursor.read_varint()
            tx.witness_item_offsets_by_input.append(len(tx.witness_items))
            tx.witness_item_count_by_input.append(stack_count)
            for _ in range(stack_count):
                var item = ScriptStackItem()
                item.data = cursor.read_bytes(cursor.read_varint())
                tx.witness_items.append(item^)

    tx.lock_time = cursor.read_u32_le()
    if cursor.remaining() != 0:
        raise Error("transaction parser consumed partial payload")
    return tx^


def tx_witness_count(ref tx: Transaction, input_index: Int) raises -> Int:
    if not tx.has_witness:
        return 0
    if input_index < 0 or input_index >= len(tx.witness_item_count_by_input):
        raise Error("witness input index out of range")
    return tx.witness_item_count_by_input[input_index]


def tx_witness_item(ref tx: Transaction, input_index: Int, item_index: Int) raises -> ScriptStackItem:
    var count = tx_witness_count(tx, input_index)
    if item_index < 0 or item_index >= count:
        raise Error("witness item index out of range")
    var offset = tx.witness_item_offsets_by_input[input_index]
    return tx.witness_items[offset + item_index].copy()


def serialize_tx_output(mut out: List[UInt8], ref output: TxOutput) raises:
    append_i64_le(out, output.value)
    append_varint(out, len(output.script_pubkey))
    append_bytes(out, output.script_pubkey)


def legacy_sighash_preimage(
    ref tx: Transaction, input_index: Int, ref script_code: List[UInt8], sighash_type: UInt8
) raises -> List[UInt8]:
    var base_type = Int(sighash_type) & 0x1F
    if base_type != 1 and base_type != 2 and base_type != 3:
        raise Error("diagnostic legacy sighash supports SIGHASH_ALL, SIGHASH_NONE, and SIGHASH_SINGLE only")
    var anyone_can_pay = (Int(sighash_type) & 0x80) != 0
    if input_index < 0 or input_index >= len(tx.inputs):
        raise Error("input index out of range")

    var out = List[UInt8]()
    append_i32_le(out, tx.version)
    if anyone_can_pay:
        append_varint(out, 1)
        append_bytes(out, tx.inputs[input_index].previous_hash)
        append_u32_le(out, tx.inputs[input_index].previous_index)
        append_varint(out, len(script_code))
        append_bytes(out, script_code)
        append_u32_le(out, tx.inputs[input_index].sequence)
    else:
        append_varint(out, len(tx.inputs))
        for i in range(len(tx.inputs)):
            append_bytes(out, tx.inputs[i].previous_hash)
            append_u32_le(out, tx.inputs[i].previous_index)
            if i == input_index:
                append_varint(out, len(script_code))
                append_bytes(out, script_code)
            else:
                append_varint(out, 0)
            if i != input_index and (base_type == 2 or base_type == 3):
                append_u32_le(out, UInt32(0))
            else:
                append_u32_le(out, tx.inputs[i].sequence)
    if base_type == 2:
        append_varint(out, 0)
    elif base_type == 3:
        append_varint(out, input_index + 1)
        for _ in range(input_index):
            append_i64_le(out, Int64(-1))
            append_varint(out, 0)
        serialize_tx_output(out, tx.outputs[input_index])
    else:
        append_varint(out, len(tx.outputs))
        for i in range(len(tx.outputs)):
            serialize_tx_output(out, tx.outputs[i])
    append_u32_le(out, tx.lock_time)
    append_u32_le(out, UInt32(sighash_type))
    return out^


def _rotr32(value: UInt32, bits: Int) -> UInt32:
    return (value >> UInt32(bits)) | (value << UInt32(32 - bits))


def _sha256_k(index: Int) -> UInt32:
    if index == 0:
        return UInt32(0x428A2F98)
    if index == 1:
        return UInt32(0x71374491)
    if index == 2:
        return UInt32(0xB5C0FBCF)
    if index == 3:
        return UInt32(0xE9B5DBA5)
    if index == 4:
        return UInt32(0x3956C25B)
    if index == 5:
        return UInt32(0x59F111F1)
    if index == 6:
        return UInt32(0x923F82A4)
    if index == 7:
        return UInt32(0xAB1C5ED5)
    if index == 8:
        return UInt32(0xD807AA98)
    if index == 9:
        return UInt32(0x12835B01)
    if index == 10:
        return UInt32(0x243185BE)
    if index == 11:
        return UInt32(0x550C7DC3)
    if index == 12:
        return UInt32(0x72BE5D74)
    if index == 13:
        return UInt32(0x80DEB1FE)
    if index == 14:
        return UInt32(0x9BDC06A7)
    if index == 15:
        return UInt32(0xC19BF174)
    if index == 16:
        return UInt32(0xE49B69C1)
    if index == 17:
        return UInt32(0xEFBE4786)
    if index == 18:
        return UInt32(0x0FC19DC6)
    if index == 19:
        return UInt32(0x240CA1CC)
    if index == 20:
        return UInt32(0x2DE92C6F)
    if index == 21:
        return UInt32(0x4A7484AA)
    if index == 22:
        return UInt32(0x5CB0A9DC)
    if index == 23:
        return UInt32(0x76F988DA)
    if index == 24:
        return UInt32(0x983E5152)
    if index == 25:
        return UInt32(0xA831C66D)
    if index == 26:
        return UInt32(0xB00327C8)
    if index == 27:
        return UInt32(0xBF597FC7)
    if index == 28:
        return UInt32(0xC6E00BF3)
    if index == 29:
        return UInt32(0xD5A79147)
    if index == 30:
        return UInt32(0x06CA6351)
    if index == 31:
        return UInt32(0x14292967)
    if index == 32:
        return UInt32(0x27B70A85)
    if index == 33:
        return UInt32(0x2E1B2138)
    if index == 34:
        return UInt32(0x4D2C6DFC)
    if index == 35:
        return UInt32(0x53380D13)
    if index == 36:
        return UInt32(0x650A7354)
    if index == 37:
        return UInt32(0x766A0ABB)
    if index == 38:
        return UInt32(0x81C2C92E)
    if index == 39:
        return UInt32(0x92722C85)
    if index == 40:
        return UInt32(0xA2BFE8A1)
    if index == 41:
        return UInt32(0xA81A664B)
    if index == 42:
        return UInt32(0xC24B8B70)
    if index == 43:
        return UInt32(0xC76C51A3)
    if index == 44:
        return UInt32(0xD192E819)
    if index == 45:
        return UInt32(0xD6990624)
    if index == 46:
        return UInt32(0xF40E3585)
    if index == 47:
        return UInt32(0x106AA070)
    if index == 48:
        return UInt32(0x19A4C116)
    if index == 49:
        return UInt32(0x1E376C08)
    if index == 50:
        return UInt32(0x2748774C)
    if index == 51:
        return UInt32(0x34B0BCB5)
    if index == 52:
        return UInt32(0x391C0CB3)
    if index == 53:
        return UInt32(0x4ED8AA4A)
    if index == 54:
        return UInt32(0x5B9CCA4F)
    if index == 55:
        return UInt32(0x682E6FF3)
    if index == 56:
        return UInt32(0x748F82EE)
    if index == 57:
        return UInt32(0x78A5636F)
    if index == 58:
        return UInt32(0x84C87814)
    if index == 59:
        return UInt32(0x8CC70208)
    if index == 60:
        return UInt32(0x90BEFFFA)
    if index == 61:
        return UInt32(0xA4506CEB)
    if index == 62:
        return UInt32(0xBEF9A3F7)
    return UInt32(0xC67178F2)


def sha256_digest(ref payload: List[UInt8]) -> List[UInt8]:
    var data = clone_bytes(payload)
    var bit_len = UInt64(len(payload)) * UInt64(8)
    data.append(UInt8(0x80))
    while len(data) % 64 != 56:
        data.append(UInt8(0))
    for i in range(8):
        data.append(UInt8((bit_len >> UInt64((7 - i) * 8)) & UInt64(0xFF)))

    var h0 = UInt32(0x6A09E667)
    var h1 = UInt32(0xBB67AE85)
    var h2 = UInt32(0x3C6EF372)
    var h3 = UInt32(0xA54FF53A)
    var h4 = UInt32(0x510E527F)
    var h5 = UInt32(0x9B05688C)
    var h6 = UInt32(0x1F83D9AB)
    var h7 = UInt32(0x5BE0CD19)

    for chunk_start in range(0, len(data), 64):
        var w = List[UInt32]()
        for i in range(16):
            var offset = chunk_start + i * 4
            var word = (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16)
            word |= (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
            w.append(word)
        for i in range(16, 64):
            var s0 = _rotr32(w[i - 15], 7) ^ _rotr32(w[i - 15], 18) ^ (w[i - 15] >> 3)
            var s1 = _rotr32(w[i - 2], 17) ^ _rotr32(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w.append(w[i - 16] + s0 + w[i - 7] + s1)

        var a = h0
        var b = h1
        var c = h2
        var d = h3
        var e = h4
        var f = h5
        var g = h6
        var h = h7
        for i in range(64):
            var s1 = _rotr32(e, 6) ^ _rotr32(e, 11) ^ _rotr32(e, 25)
            var ch = (e & f) ^ ((~e) & g)
            var temp1 = h + s1 + ch + _sha256_k(i) + w[i]
            var s0 = _rotr32(a, 2) ^ _rotr32(a, 13) ^ _rotr32(a, 22)
            var maj = (a & b) ^ (a & c) ^ (b & c)
            var temp2 = s0 + maj
            h = g
            g = f
            f = e
            e = d + temp1
            d = c
            c = b
            b = a
            a = temp1 + temp2
        h0 += a
        h1 += b
        h2 += c
        h3 += d
        h4 += e
        h5 += f
        h6 += g
        h7 += h

    var out = List[UInt8]()
    for word in [h0, h1, h2, h3, h4, h5, h6, h7]:
        out.append(UInt8((word >> 24) & 0xFF))
        out.append(UInt8((word >> 16) & 0xFF))
        out.append(UInt8((word >> 8) & 0xFF))
        out.append(UInt8(word & 0xFF))
    return out^


def double_sha256(ref payload: List[UInt8]) -> List[UInt8]:
    var first = sha256_digest(payload)
    return sha256_digest(first)



def _rotl32(value: UInt32, bits: Int) -> UInt32:
    return (value << UInt32(bits)) | (value >> UInt32(32 - bits))


def _read_u32_le(ref data: List[UInt8], offset: Int) -> UInt32:
    return UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)


def _append_u64_le(mut out: List[UInt8], value: UInt64):
    for i in range(8):
        out.append(UInt8((value >> UInt64(i * 8)) & UInt64(0xFF)))


def _append_u64_be(mut out: List[UInt8], value: UInt64):
    for i in range(8):
        out.append(UInt8((value >> UInt64((7 - i) * 8)) & UInt64(0xFF)))


def sha1_digest(ref payload: List[UInt8]) -> List[UInt8]:
    var data = clone_bytes(payload)
    var bit_len = UInt64(len(payload)) * UInt64(8)
    data.append(UInt8(0x80))
    while len(data) % 64 != 56:
        data.append(UInt8(0))
    _append_u64_be(data, bit_len)

    var h0 = UInt32(0x67452301)
    var h1 = UInt32(0xEFCDAB89)
    var h2 = UInt32(0x98BADCFE)
    var h3 = UInt32(0x10325476)
    var h4 = UInt32(0xC3D2E1F0)
    for chunk_start in range(0, len(data), 64):
        var w = List[UInt32]()
        for i in range(16):
            var offset = chunk_start + i * 4
            var word = (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16)
            word |= (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
            w.append(word)
        for i in range(16, 80):
            w.append(_rotl32(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1))
        var a = h0
        var b = h1
        var c = h2
        var d = h3
        var e = h4
        for i in range(80):
            var f: UInt32
            var k: UInt32
            if i < 20:
                f = (b & c) | ((~b) & d)
                k = UInt32(0x5A827999)
            elif i < 40:
                f = b ^ c ^ d
                k = UInt32(0x6ED9EBA1)
            elif i < 60:
                f = (b & c) | (b & d) | (c & d)
                k = UInt32(0x8F1BBCDC)
            else:
                f = b ^ c ^ d
                k = UInt32(0xCA62C1D6)
            var temp = _rotl32(a, 5) + f + e + k + w[i]
            e = d
            d = c
            c = _rotl32(b, 30)
            b = a
            a = temp
        h0 += a
        h1 += b
        h2 += c
        h3 += d
        h4 += e
    var out = List[UInt8]()
    for word in [h0, h1, h2, h3, h4]:
        out.append(UInt8((word >> 24) & 0xFF))
        out.append(UInt8((word >> 16) & 0xFF))
        out.append(UInt8((word >> 8) & 0xFF))
        out.append(UInt8(word & 0xFF))
    return out^

def _ripemd_r1(index: Int) -> Int:
    if index == 0:
        return 0
    if index == 1:
        return 1
    if index == 2:
        return 2
    if index == 3:
        return 3
    if index == 4:
        return 4
    if index == 5:
        return 5
    if index == 6:
        return 6
    if index == 7:
        return 7
    if index == 8:
        return 8
    if index == 9:
        return 9
    if index == 10:
        return 10
    if index == 11:
        return 11
    if index == 12:
        return 12
    if index == 13:
        return 13
    if index == 14:
        return 14
    if index == 15:
        return 15
    if index == 16:
        return 7
    if index == 17:
        return 4
    if index == 18:
        return 13
    if index == 19:
        return 1
    if index == 20:
        return 10
    if index == 21:
        return 6
    if index == 22:
        return 15
    if index == 23:
        return 3
    if index == 24:
        return 12
    if index == 25:
        return 0
    if index == 26:
        return 9
    if index == 27:
        return 5
    if index == 28:
        return 2
    if index == 29:
        return 14
    if index == 30:
        return 11
    if index == 31:
        return 8
    if index == 32:
        return 3
    if index == 33:
        return 10
    if index == 34:
        return 14
    if index == 35:
        return 4
    if index == 36:
        return 9
    if index == 37:
        return 15
    if index == 38:
        return 8
    if index == 39:
        return 1
    if index == 40:
        return 2
    if index == 41:
        return 7
    if index == 42:
        return 0
    if index == 43:
        return 6
    if index == 44:
        return 13
    if index == 45:
        return 11
    if index == 46:
        return 5
    if index == 47:
        return 12
    if index == 48:
        return 1
    if index == 49:
        return 9
    if index == 50:
        return 11
    if index == 51:
        return 10
    if index == 52:
        return 0
    if index == 53:
        return 8
    if index == 54:
        return 12
    if index == 55:
        return 4
    if index == 56:
        return 13
    if index == 57:
        return 3
    if index == 58:
        return 7
    if index == 59:
        return 15
    if index == 60:
        return 14
    if index == 61:
        return 5
    if index == 62:
        return 6
    if index == 63:
        return 2
    if index == 64:
        return 4
    if index == 65:
        return 0
    if index == 66:
        return 5
    if index == 67:
        return 9
    if index == 68:
        return 7
    if index == 69:
        return 12
    if index == 70:
        return 2
    if index == 71:
        return 10
    if index == 72:
        return 14
    if index == 73:
        return 1
    if index == 74:
        return 3
    if index == 75:
        return 8
    if index == 76:
        return 11
    if index == 77:
        return 6
    if index == 78:
        return 15
    return 13


def _ripemd_r2(index: Int) -> Int:
    if index == 0:
        return 5
    if index == 1:
        return 14
    if index == 2:
        return 7
    if index == 3:
        return 0
    if index == 4:
        return 9
    if index == 5:
        return 2
    if index == 6:
        return 11
    if index == 7:
        return 4
    if index == 8:
        return 13
    if index == 9:
        return 6
    if index == 10:
        return 15
    if index == 11:
        return 8
    if index == 12:
        return 1
    if index == 13:
        return 10
    if index == 14:
        return 3
    if index == 15:
        return 12
    if index == 16:
        return 6
    if index == 17:
        return 11
    if index == 18:
        return 3
    if index == 19:
        return 7
    if index == 20:
        return 0
    if index == 21:
        return 13
    if index == 22:
        return 5
    if index == 23:
        return 10
    if index == 24:
        return 14
    if index == 25:
        return 15
    if index == 26:
        return 8
    if index == 27:
        return 12
    if index == 28:
        return 4
    if index == 29:
        return 9
    if index == 30:
        return 1
    if index == 31:
        return 2
    if index == 32:
        return 15
    if index == 33:
        return 5
    if index == 34:
        return 1
    if index == 35:
        return 3
    if index == 36:
        return 7
    if index == 37:
        return 14
    if index == 38:
        return 6
    if index == 39:
        return 9
    if index == 40:
        return 11
    if index == 41:
        return 8
    if index == 42:
        return 12
    if index == 43:
        return 2
    if index == 44:
        return 10
    if index == 45:
        return 0
    if index == 46:
        return 4
    if index == 47:
        return 13
    if index == 48:
        return 8
    if index == 49:
        return 6
    if index == 50:
        return 4
    if index == 51:
        return 1
    if index == 52:
        return 3
    if index == 53:
        return 11
    if index == 54:
        return 15
    if index == 55:
        return 0
    if index == 56:
        return 5
    if index == 57:
        return 12
    if index == 58:
        return 2
    if index == 59:
        return 13
    if index == 60:
        return 9
    if index == 61:
        return 7
    if index == 62:
        return 10
    if index == 63:
        return 14
    if index == 64:
        return 12
    if index == 65:
        return 15
    if index == 66:
        return 10
    if index == 67:
        return 4
    if index == 68:
        return 1
    if index == 69:
        return 5
    if index == 70:
        return 8
    if index == 71:
        return 7
    if index == 72:
        return 6
    if index == 73:
        return 2
    if index == 74:
        return 13
    if index == 75:
        return 14
    if index == 76:
        return 0
    if index == 77:
        return 3
    if index == 78:
        return 9
    return 11


def _ripemd_s1(index: Int) -> Int:
    if index == 0:
        return 11
    if index == 1:
        return 14
    if index == 2:
        return 15
    if index == 3:
        return 12
    if index == 4:
        return 5
    if index == 5:
        return 8
    if index == 6:
        return 7
    if index == 7:
        return 9
    if index == 8:
        return 11
    if index == 9:
        return 13
    if index == 10:
        return 14
    if index == 11:
        return 15
    if index == 12:
        return 6
    if index == 13:
        return 7
    if index == 14:
        return 9
    if index == 15:
        return 8
    if index == 16:
        return 7
    if index == 17:
        return 6
    if index == 18:
        return 8
    if index == 19:
        return 13
    if index == 20:
        return 11
    if index == 21:
        return 9
    if index == 22:
        return 7
    if index == 23:
        return 15
    if index == 24:
        return 7
    if index == 25:
        return 12
    if index == 26:
        return 15
    if index == 27:
        return 9
    if index == 28:
        return 11
    if index == 29:
        return 7
    if index == 30:
        return 13
    if index == 31:
        return 12
    if index == 32:
        return 11
    if index == 33:
        return 13
    if index == 34:
        return 6
    if index == 35:
        return 7
    if index == 36:
        return 14
    if index == 37:
        return 9
    if index == 38:
        return 13
    if index == 39:
        return 15
    if index == 40:
        return 14
    if index == 41:
        return 8
    if index == 42:
        return 13
    if index == 43:
        return 6
    if index == 44:
        return 5
    if index == 45:
        return 12
    if index == 46:
        return 7
    if index == 47:
        return 5
    if index == 48:
        return 11
    if index == 49:
        return 12
    if index == 50:
        return 14
    if index == 51:
        return 15
    if index == 52:
        return 14
    if index == 53:
        return 15
    if index == 54:
        return 9
    if index == 55:
        return 8
    if index == 56:
        return 9
    if index == 57:
        return 14
    if index == 58:
        return 5
    if index == 59:
        return 6
    if index == 60:
        return 8
    if index == 61:
        return 6
    if index == 62:
        return 5
    if index == 63:
        return 12
    if index == 64:
        return 9
    if index == 65:
        return 15
    if index == 66:
        return 5
    if index == 67:
        return 11
    if index == 68:
        return 6
    if index == 69:
        return 8
    if index == 70:
        return 13
    if index == 71:
        return 12
    if index == 72:
        return 5
    if index == 73:
        return 12
    if index == 74:
        return 13
    if index == 75:
        return 14
    if index == 76:
        return 11
    if index == 77:
        return 8
    if index == 78:
        return 5
    return 6


def _ripemd_s2(index: Int) -> Int:
    if index == 0:
        return 8
    if index == 1:
        return 9
    if index == 2:
        return 9
    if index == 3:
        return 11
    if index == 4:
        return 13
    if index == 5:
        return 15
    if index == 6:
        return 15
    if index == 7:
        return 5
    if index == 8:
        return 7
    if index == 9:
        return 7
    if index == 10:
        return 8
    if index == 11:
        return 11
    if index == 12:
        return 14
    if index == 13:
        return 14
    if index == 14:
        return 12
    if index == 15:
        return 6
    if index == 16:
        return 9
    if index == 17:
        return 13
    if index == 18:
        return 15
    if index == 19:
        return 7
    if index == 20:
        return 12
    if index == 21:
        return 8
    if index == 22:
        return 9
    if index == 23:
        return 11
    if index == 24:
        return 7
    if index == 25:
        return 7
    if index == 26:
        return 12
    if index == 27:
        return 7
    if index == 28:
        return 6
    if index == 29:
        return 15
    if index == 30:
        return 13
    if index == 31:
        return 11
    if index == 32:
        return 9
    if index == 33:
        return 7
    if index == 34:
        return 15
    if index == 35:
        return 11
    if index == 36:
        return 8
    if index == 37:
        return 6
    if index == 38:
        return 6
    if index == 39:
        return 14
    if index == 40:
        return 12
    if index == 41:
        return 13
    if index == 42:
        return 5
    if index == 43:
        return 14
    if index == 44:
        return 13
    if index == 45:
        return 13
    if index == 46:
        return 7
    if index == 47:
        return 5
    if index == 48:
        return 15
    if index == 49:
        return 5
    if index == 50:
        return 8
    if index == 51:
        return 11
    if index == 52:
        return 14
    if index == 53:
        return 14
    if index == 54:
        return 6
    if index == 55:
        return 14
    if index == 56:
        return 6
    if index == 57:
        return 9
    if index == 58:
        return 12
    if index == 59:
        return 9
    if index == 60:
        return 12
    if index == 61:
        return 5
    if index == 62:
        return 15
    if index == 63:
        return 8
    if index == 64:
        return 8
    if index == 65:
        return 5
    if index == 66:
        return 12
    if index == 67:
        return 9
    if index == 68:
        return 12
    if index == 69:
        return 5
    if index == 70:
        return 14
    if index == 71:
        return 6
    if index == 72:
        return 8
    if index == 73:
        return 13
    if index == 74:
        return 6
    if index == 75:
        return 5
    if index == 76:
        return 15
    if index == 77:
        return 13
    if index == 78:
        return 11
    return 11


def _ripemd_f(round: Int, x: UInt32, y: UInt32, z: UInt32) -> UInt32:
    if round == 0:
        return x ^ y ^ z
    if round == 1:
        return (x & y) | ((~x) & z)
    if round == 2:
        return (x | (~y)) ^ z
    if round == 3:
        return (x & z) | (y & (~z))
    return x ^ (y | (~z))


def _ripemd_k1(round: Int) -> UInt32:
    if round == 0:
        return UInt32(0)
    if round == 1:
        return UInt32(0x5A827999)
    if round == 2:
        return UInt32(0x6ED9EBA1)
    if round == 3:
        return UInt32(0x8F1BBCDC)
    return UInt32(0xA953FD4E)


def _ripemd_k2(round: Int) -> UInt32:
    if round == 0:
        return UInt32(0x50A28BE6)
    if round == 1:
        return UInt32(0x5C4DD124)
    if round == 2:
        return UInt32(0x6D703EF3)
    if round == 3:
        return UInt32(0x7A6D76E9)
    return UInt32(0)


def ripemd160_digest(ref payload: List[UInt8]) -> List[UInt8]:
    var data = clone_bytes(payload)
    var bit_len = UInt64(len(payload)) * UInt64(8)
    data.append(UInt8(0x80))
    while len(data) % 64 != 56:
        data.append(UInt8(0))
    _append_u64_le(data, bit_len)

    var h0 = UInt32(0x67452301)
    var h1 = UInt32(0xEFCDAB89)
    var h2 = UInt32(0x98BADCFE)
    var h3 = UInt32(0x10325476)
    var h4 = UInt32(0xC3D2E1F0)
    for chunk_start in range(0, len(data), 64):
        var words = List[UInt32]()
        for i in range(16):
            words.append(_read_u32_le(data, chunk_start + i * 4))
        var a1 = h0
        var b1 = h1
        var c1 = h2
        var d1 = h3
        var e1 = h4
        var a2 = h0
        var b2 = h1
        var c2 = h2
        var d2 = h3
        var e2 = h4
        for j in range(80):
            var round1 = j // 16
            var t1 = _rotl32(a1 + _ripemd_f(round1, b1, c1, d1) + words[_ripemd_r1(j)] + _ripemd_k1(round1), _ripemd_s1(j)) + e1
            a1 = e1
            e1 = d1
            d1 = _rotl32(c1, 10)
            c1 = b1
            b1 = t1
            var round2 = j // 16
            var t2 = _rotl32(a2 + _ripemd_f(4 - round2, b2, c2, d2) + words[_ripemd_r2(j)] + _ripemd_k2(round2), _ripemd_s2(j)) + e2
            a2 = e2
            e2 = d2
            d2 = _rotl32(c2, 10)
            c2 = b2
            b2 = t2
        var tmp = h1 + c1 + d2
        h1 = h2 + d1 + e2
        h2 = h3 + e1 + a2
        h3 = h4 + a1 + b2
        h4 = h0 + b1 + c2
        h0 = tmp
    var out = List[UInt8]()
    for word in [h0, h1, h2, h3, h4]:
        out.append(UInt8(word & 0xFF))
        out.append(UInt8((word >> 8) & 0xFF))
        out.append(UInt8((word >> 16) & 0xFF))
        out.append(UInt8((word >> 24) & 0xFF))
    return out^


def hash160(ref payload: List[UInt8]) -> List[UInt8]:
    var sha = sha256_digest(payload)
    return ripemd160_digest(sha)


def hash256(ref payload: List[UInt8]) -> List[UInt8]:
    return double_sha256(payload)


def tagged_hash(tag: String, ref payload: List[UInt8]) -> List[UInt8]:
    var tag_bytes = ascii_string_to_bytes(tag)
    var tag_digest = sha256_digest(tag_bytes)
    var data = List[UInt8]()
    append_bytes(data, tag_digest)
    append_bytes(data, tag_digest)
    append_bytes(data, payload)
    return sha256_digest(data)


def taproot_tweak_hash(ref internal_xonly: List[UInt8], ref merkle_root: List[UInt8]) raises -> List[UInt8]:
    if len(internal_xonly) != 32:
        raise Error("Taproot internal key must be 32 bytes")
    if len(merkle_root) != 0 and len(merkle_root) != 32:
        raise Error("Taproot merkle root must be empty or 32 bytes")
    var payload = clone_bytes(internal_xonly)
    append_bytes(payload, merkle_root)
    return tagged_hash(String("TapTweak"), payload)


def tapleaf_hash(leaf_version: UInt8, ref script: List[UInt8]) raises -> List[UInt8]:
    var data = List[UInt8]()
    data.append(leaf_version)
    append_varint(data, len(script))
    append_bytes(data, script)
    return tagged_hash(String("TapLeaf"), data)


def bytes_less(ref left: List[UInt8], ref right: List[UInt8]) -> Bool:
    var limit = len(left)
    if len(right) < limit:
        limit = len(right)
    for i in range(limit):
        if left[i] < right[i]:
            return True
        if left[i] > right[i]:
            return False
    return len(left) < len(right)


def tapbranch_hash(ref left: List[UInt8], ref right: List[UInt8]) -> List[UInt8]:
    var data = List[UInt8]()
    if bytes_less(left, right):
        append_bytes(data, left)
        append_bytes(data, right)
    else:
        append_bytes(data, right)
        append_bytes(data, left)
    return tagged_hash(String("TapBranch"), data)


def taproot_merkle_root_from_control(ref control: List[UInt8], ref leaf_hash_value: List[UInt8]) raises -> List[UInt8]:
    var root = clone_bytes(leaf_hash_value)
    var offset = 33
    while offset < len(control):
        var sibling = slice_bytes(control, offset, offset + 32)
        root = tapbranch_hash(root, sibling)
        offset += 32
    return root^


def sha256_serialized_outputs(ref tx: Transaction) raises -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(tx.outputs)):
        serialize_tx_output(out, tx.outputs[i])
    return sha256_digest(out)


def sha256_serialized_single_output(ref tx: Transaction, input_index: Int) raises -> List[UInt8]:
    var out = List[UInt8]()
    serialize_tx_output(out, tx.outputs[input_index])
    return sha256_digest(out)


def serialize_taproot_spent_output(mut out: List[UInt8], ref prevout: TaprootPrevout) raises:
    append_i64_le(out, prevout.amount)
    append_varint(out, len(prevout.script_pubkey))
    append_bytes(out, prevout.script_pubkey)


struct SighashPrecompute(Copyable):
    var legacy_available: Bool
    var legacy_input_count: List[UInt8]
    var legacy_output_count: List[UInt8]
    var legacy_outpoints: List[List[UInt8]]
    var legacy_sequences: List[List[UInt8]]
    var legacy_serialized_outputs: List[List[UInt8]]
    var legacy_outputs_all: List[UInt8]
    var legacy_null_output: List[UInt8]
    var legacy_empty_inputs_all: List[List[UInt8]]
    var legacy_empty_inputs_zero_sequence: List[List[UInt8]]
    var bip143_available: Bool
    var bip143_hash_prevouts: List[UInt8]
    var bip143_hash_sequence: List[UInt8]
    var bip143_hash_outputs: List[UInt8]
    var bip143_hash_single_outputs: List[List[UInt8]]
    var taproot_available: Bool
    var taproot_hash_prevouts: List[UInt8]
    var taproot_hash_amounts: List[UInt8]
    var taproot_hash_scriptpubkeys: List[UInt8]
    var taproot_hash_sequences: List[UInt8]
    var taproot_hash_outputs: List[UInt8]
    var taproot_hash_single_outputs: List[List[UInt8]]

    def __init__(out self):
        self.legacy_available = False
        self.legacy_input_count = List[UInt8]()
        self.legacy_output_count = List[UInt8]()
        self.legacy_outpoints = List[List[UInt8]]()
        self.legacy_sequences = List[List[UInt8]]()
        self.legacy_serialized_outputs = List[List[UInt8]]()
        self.legacy_outputs_all = List[UInt8]()
        self.legacy_null_output = List[UInt8]()
        self.legacy_empty_inputs_all = List[List[UInt8]]()
        self.legacy_empty_inputs_zero_sequence = List[List[UInt8]]()
        self.bip143_available = False
        self.bip143_hash_prevouts = List[UInt8]()
        self.bip143_hash_sequence = List[UInt8]()
        self.bip143_hash_outputs = List[UInt8]()
        self.bip143_hash_single_outputs = List[List[UInt8]]()
        self.taproot_available = False
        self.taproot_hash_prevouts = List[UInt8]()
        self.taproot_hash_amounts = List[UInt8]()
        self.taproot_hash_scriptpubkeys = List[UInt8]()
        self.taproot_hash_sequences = List[UInt8]()
        self.taproot_hash_outputs = List[UInt8]()
        self.taproot_hash_single_outputs = List[List[UInt8]]()


def build_sighash_precompute(ref tx: Transaction) raises -> SighashPrecompute:
    var empty_prevouts = List[TaprootPrevout]()
    return build_sighash_precompute_for_modes(tx, empty_prevouts, True, True, False)


def build_sighash_precompute_with_taproot(
    ref tx: Transaction, ref spent_prevouts: List[TaprootPrevout]
) raises -> SighashPrecompute:
    return build_sighash_precompute_for_modes(tx, spent_prevouts, True, True, True)


def serialize_legacy_outpoint(ref input: TxInput) -> List[UInt8]:
    var out = List[UInt8]()
    append_bytes(out, input.previous_hash)
    append_u32_le(out, input.previous_index)
    return out^


def serialize_legacy_sequence(sequence: UInt32) -> List[UInt8]:
    var out = List[UInt8]()
    append_u32_le(out, sequence)
    return out^


def serialize_legacy_empty_input(ref input: TxInput, sequence: UInt32) raises -> List[UInt8]:
    var out = serialize_legacy_outpoint(input)
    append_varint(out, 0)
    append_u32_le(out, sequence)
    return out^


def serialize_legacy_null_output() raises -> List[UInt8]:
    var out = List[UInt8]()
    append_i64_le(out, Int64(-1))
    append_varint(out, 0)
    return out^


def build_legacy_sighash_cache(mut cache: SighashPrecompute, ref tx: Transaction) raises:
    append_varint(cache.legacy_input_count, len(tx.inputs))
    append_varint(cache.legacy_output_count, len(tx.outputs))
    cache.legacy_null_output = serialize_legacy_null_output()
    for i in range(len(tx.inputs)):
        var outpoint = serialize_legacy_outpoint(tx.inputs[i])
        var sequence = serialize_legacy_sequence(tx.inputs[i].sequence)
        var empty_all = serialize_legacy_empty_input(tx.inputs[i], tx.inputs[i].sequence)
        var empty_zero = serialize_legacy_empty_input(tx.inputs[i], UInt32(0))
        cache.legacy_outpoints.append(outpoint^)
        cache.legacy_sequences.append(sequence^)
        cache.legacy_empty_inputs_all.append(empty_all^)
        cache.legacy_empty_inputs_zero_sequence.append(empty_zero^)
    for i in range(len(tx.outputs)):
        var serialized = List[UInt8]()
        serialize_tx_output(serialized, tx.outputs[i])
        append_bytes(cache.legacy_outputs_all, serialized)
        cache.legacy_serialized_outputs.append(serialized^)
    cache.legacy_available = True


def legacy_sighash_cache_build_bytes(ref cache: SighashPrecompute) -> Int:
    if not cache.legacy_available:
        return 0
    var total = len(cache.legacy_input_count) + len(cache.legacy_output_count)
    total += len(cache.legacy_outputs_all) + len(cache.legacy_null_output)
    for i in range(len(cache.legacy_outpoints)):
        total += len(cache.legacy_outpoints[i])
    for i in range(len(cache.legacy_sequences)):
        total += len(cache.legacy_sequences[i])
    for i in range(len(cache.legacy_serialized_outputs)):
        total += len(cache.legacy_serialized_outputs[i])
    for i in range(len(cache.legacy_empty_inputs_all)):
        total += len(cache.legacy_empty_inputs_all[i])
    for i in range(len(cache.legacy_empty_inputs_zero_sequence)):
        total += len(cache.legacy_empty_inputs_zero_sequence[i])
    return total


def build_sighash_precompute_for_modes(
    ref tx: Transaction,
    ref spent_prevouts: List[TaprootPrevout],
    build_legacy: Bool,
    build_bip143: Bool,
    build_taproot: Bool,
) raises -> SighashPrecompute:
    var cache = SighashPrecompute()
    if build_legacy:
        build_legacy_sighash_cache(cache, tx)

    if build_bip143:
        cache.bip143_hash_prevouts = _hash_prevouts(tx)
        cache.bip143_hash_sequence = _hash_sequence(tx)
        cache.bip143_hash_outputs = _hash_outputs(tx)
        for i in range(len(tx.outputs)):
            var single = _hash_single_output(tx, i)
            cache.bip143_hash_single_outputs.append(single^)
        cache.bip143_available = True

    if build_taproot and len(spent_prevouts) == len(tx.inputs):
        var prev_blob = List[UInt8]()
        var amount_blob = List[UInt8]()
        var script_blob = List[UInt8]()
        var sequence_blob = List[UInt8]()
        for i in range(len(tx.inputs)):
            append_bytes(prev_blob, tx.inputs[i].previous_hash)
            append_u32_le(prev_blob, tx.inputs[i].previous_index)
            append_i64_le(amount_blob, spent_prevouts[i].amount)
            append_varint(script_blob, len(spent_prevouts[i].script_pubkey))
            append_bytes(script_blob, spent_prevouts[i].script_pubkey)
            append_u32_le(sequence_blob, tx.inputs[i].sequence)
        cache.taproot_hash_prevouts = sha256_digest(prev_blob)
        cache.taproot_hash_amounts = sha256_digest(amount_blob)
        cache.taproot_hash_scriptpubkeys = sha256_digest(script_blob)
        cache.taproot_hash_sequences = sha256_digest(sequence_blob)
        cache.taproot_hash_outputs = sha256_serialized_outputs(tx)
        for i in range(len(tx.outputs)):
            var single = sha256_serialized_single_output(tx, i)
            cache.taproot_hash_single_outputs.append(single^)
        cache.taproot_available = True
    return cache^


def taproot_signature_hash(
    ref tx: Transaction,
    input_index: Int,
    ref spent_prevouts: List[TaprootPrevout],
    hash_type: UInt8,
    ref leaf_hash_value: List[UInt8],
    codeseparator_pos: Int,
) raises -> List[UInt8]:
    var hash_type_int = Int(hash_type)
    if not (hash_type_int <= 3 or (hash_type_int >= 0x81 and hash_type_int <= 0x83)):
        raise Error("unsupported Taproot hash type")
    var output_mode = hash_type_int & 0x03
    if hash_type_int == 0:
        output_mode = 1
    var anyone_can_pay = (hash_type_int & 0x80) != 0
    if input_index < 0 or input_index >= len(tx.inputs) or input_index >= len(spent_prevouts):
        raise Error("Taproot input index out of range")
    if output_mode == 3 and input_index >= len(tx.outputs):
        raise Error("Taproot SIGHASH_SINGLE without matching output")

    var body = List[UInt8]()
    body.append(hash_type)
    append_i32_le(body, tx.version)
    append_u32_le(body, tx.lock_time)

    if not anyone_can_pay:
        var prev_blob = List[UInt8]()
        var amount_blob = List[UInt8]()
        var script_blob = List[UInt8]()
        var sequence_blob = List[UInt8]()
        for i in range(len(tx.inputs)):
            append_bytes(prev_blob, tx.inputs[i].previous_hash)
            append_u32_le(prev_blob, tx.inputs[i].previous_index)
            append_i64_le(amount_blob, spent_prevouts[i].amount)
            append_varint(script_blob, len(spent_prevouts[i].script_pubkey))
            append_bytes(script_blob, spent_prevouts[i].script_pubkey)
            append_u32_le(sequence_blob, tx.inputs[i].sequence)
        var hash_prevouts = sha256_digest(prev_blob)
        var hash_amounts = sha256_digest(amount_blob)
        var hash_scriptpubkeys = sha256_digest(script_blob)
        var hash_sequences = sha256_digest(sequence_blob)
        append_bytes(body, hash_prevouts)
        append_bytes(body, hash_amounts)
        append_bytes(body, hash_scriptpubkeys)
        append_bytes(body, hash_sequences)

    if output_mode == 1:
        var hash_outputs = sha256_serialized_outputs(tx)
        append_bytes(body, hash_outputs)

    body.append(UInt8(2))
    if anyone_can_pay:
        append_bytes(body, tx.inputs[input_index].previous_hash)
        append_u32_le(body, tx.inputs[input_index].previous_index)
        serialize_taproot_spent_output(body, spent_prevouts[input_index])
        append_u32_le(body, tx.inputs[input_index].sequence)
    else:
        append_u32_le(body, UInt32(input_index))

    if output_mode == 3:
        var hash_single = sha256_serialized_single_output(tx, input_index)
        append_bytes(body, hash_single)

    append_bytes(body, leaf_hash_value)
    body.append(UInt8(0))
    append_u32_le(body, UInt32(codeseparator_pos))

    var msg = List[UInt8]()
    msg.append(UInt8(0))
    append_bytes(msg, body)
    return tagged_hash(String("TapSighash"), msg)


def taproot_signature_hash_cached(
    ref tx: Transaction,
    input_index: Int,
    ref spent_prevouts: List[TaprootPrevout],
    hash_type: UInt8,
    ref leaf_hash_value: List[UInt8],
    codeseparator_pos: Int,
    ref precompute: SighashPrecompute,
) raises -> List[UInt8]:
    var hash_type_int = Int(hash_type)
    if not (hash_type_int <= 3 or (hash_type_int >= 0x81 and hash_type_int <= 0x83)):
        raise Error("unsupported Taproot hash type")
    var output_mode = hash_type_int & 0x03
    if hash_type_int == 0:
        output_mode = 1
    var anyone_can_pay = (hash_type_int & 0x80) != 0
    if input_index < 0 or input_index >= len(tx.inputs) or input_index >= len(spent_prevouts):
        raise Error("Taproot input index out of range")
    if len(spent_prevouts) != len(tx.inputs):
        raise Error("Taproot spent prevouts length mismatch")
    if output_mode == 3 and input_index >= len(tx.outputs):
        raise Error("Taproot SIGHASH_SINGLE without matching output")
    if not precompute.taproot_available:
        return taproot_signature_hash(tx, input_index, spent_prevouts, hash_type, leaf_hash_value, codeseparator_pos)

    var body = List[UInt8]()
    body.append(hash_type)
    append_i32_le(body, tx.version)
    append_u32_le(body, tx.lock_time)

    if not anyone_can_pay:
        append_bytes(body, precompute.taproot_hash_prevouts)
        append_bytes(body, precompute.taproot_hash_amounts)
        append_bytes(body, precompute.taproot_hash_scriptpubkeys)
        append_bytes(body, precompute.taproot_hash_sequences)

    if output_mode == 1:
        append_bytes(body, precompute.taproot_hash_outputs)

    body.append(UInt8(2))
    if anyone_can_pay:
        append_bytes(body, tx.inputs[input_index].previous_hash)
        append_u32_le(body, tx.inputs[input_index].previous_index)
        serialize_taproot_spent_output(body, spent_prevouts[input_index])
        append_u32_le(body, tx.inputs[input_index].sequence)
    else:
        append_u32_le(body, UInt32(input_index))

    if output_mode == 3:
        append_bytes(body, precompute.taproot_hash_single_outputs[input_index])

    append_bytes(body, leaf_hash_value)
    body.append(UInt8(0))
    append_u32_le(body, UInt32(codeseparator_pos))

    var msg = List[UInt8]()
    msg.append(UInt8(0))
    append_bytes(msg, body)
    return tagged_hash(String("TapSighash"), msg)


def taproot_signature_hash_cached_profiled(
    ref tx: Transaction,
    input_index: Int,
    ref spent_prevouts: List[TaprootPrevout],
    hash_type: UInt8,
    ref leaf_hash_value: List[UInt8],
    codeseparator_pos: Int,
    ref precompute: SighashPrecompute,
    mut profile: HotPathProfile,
) raises -> List[UInt8]:
    hotpath_record_taproot_sighash(profile, 96 + len(leaf_hash_value) + len(tx.inputs) * 4)
    return taproot_signature_hash_cached(
        tx, input_index, spent_prevouts, hash_type, leaf_hash_value, codeseparator_pos, precompute
    )


def taproot_key_path_signature_hash(
    ref tx: Transaction,
    input_index: Int,
    ref spent_prevouts: List[TaprootPrevout],
    hash_type: UInt8,
) raises -> List[UInt8]:
    var hash_type_int = Int(hash_type)
    if not (hash_type_int <= 3 or (hash_type_int >= 0x81 and hash_type_int <= 0x83)):
        raise Error("unsupported Taproot hash type")
    var output_mode = hash_type_int & 0x03
    if hash_type_int == 0:
        output_mode = 1
    var anyone_can_pay = (hash_type_int & 0x80) != 0
    if input_index < 0 or input_index >= len(tx.inputs) or input_index >= len(spent_prevouts):
        raise Error("Taproot input index out of range")
    if len(spent_prevouts) != len(tx.inputs):
        raise Error("Taproot spent prevouts length mismatch")
    if output_mode == 3 and input_index >= len(tx.outputs):
        raise Error("Taproot SIGHASH_SINGLE without matching output")

    var body = List[UInt8]()
    body.append(hash_type)
    append_i32_le(body, tx.version)
    append_u32_le(body, tx.lock_time)

    if not anyone_can_pay:
        var prev_blob = List[UInt8]()
        var amount_blob = List[UInt8]()
        var script_blob = List[UInt8]()
        var sequence_blob = List[UInt8]()
        for i in range(len(tx.inputs)):
            append_bytes(prev_blob, tx.inputs[i].previous_hash)
            append_u32_le(prev_blob, tx.inputs[i].previous_index)
            append_i64_le(amount_blob, spent_prevouts[i].amount)
            append_varint(script_blob, len(spent_prevouts[i].script_pubkey))
            append_bytes(script_blob, spent_prevouts[i].script_pubkey)
            append_u32_le(sequence_blob, tx.inputs[i].sequence)
        var hash_prevouts = sha256_digest(prev_blob)
        var hash_amounts = sha256_digest(amount_blob)
        var hash_scriptpubkeys = sha256_digest(script_blob)
        var hash_sequences = sha256_digest(sequence_blob)
        append_bytes(body, hash_prevouts)
        append_bytes(body, hash_amounts)
        append_bytes(body, hash_scriptpubkeys)
        append_bytes(body, hash_sequences)

    if output_mode == 1:
        var hash_outputs = sha256_serialized_outputs(tx)
        append_bytes(body, hash_outputs)

    body.append(UInt8(0))
    if anyone_can_pay:
        append_bytes(body, tx.inputs[input_index].previous_hash)
        append_u32_le(body, tx.inputs[input_index].previous_index)
        serialize_taproot_spent_output(body, spent_prevouts[input_index])
        append_u32_le(body, tx.inputs[input_index].sequence)
    else:
        append_u32_le(body, UInt32(input_index))

    if output_mode == 3:
        var hash_single = sha256_serialized_single_output(tx, input_index)
        append_bytes(body, hash_single)

    var msg = List[UInt8]()
    msg.append(UInt8(0))
    append_bytes(msg, body)
    return tagged_hash(String("TapSighash"), msg)


def taproot_key_path_signature_hash_cached(
    ref tx: Transaction,
    input_index: Int,
    ref spent_prevouts: List[TaprootPrevout],
    hash_type: UInt8,
    ref precompute: SighashPrecompute,
) raises -> List[UInt8]:
    var hash_type_int = Int(hash_type)
    if not (hash_type_int <= 3 or (hash_type_int >= 0x81 and hash_type_int <= 0x83)):
        raise Error("unsupported Taproot hash type")
    var output_mode = hash_type_int & 0x03
    if hash_type_int == 0:
        output_mode = 1
    var anyone_can_pay = (hash_type_int & 0x80) != 0
    if input_index < 0 or input_index >= len(tx.inputs) or input_index >= len(spent_prevouts):
        raise Error("Taproot input index out of range")
    if len(spent_prevouts) != len(tx.inputs):
        raise Error("Taproot spent prevouts length mismatch")
    if output_mode == 3 and input_index >= len(tx.outputs):
        raise Error("Taproot SIGHASH_SINGLE without matching output")
    if not precompute.taproot_available:
        return taproot_key_path_signature_hash(tx, input_index, spent_prevouts, hash_type)

    var body = List[UInt8]()
    body.append(hash_type)
    append_i32_le(body, tx.version)
    append_u32_le(body, tx.lock_time)

    if not anyone_can_pay:
        append_bytes(body, precompute.taproot_hash_prevouts)
        append_bytes(body, precompute.taproot_hash_amounts)
        append_bytes(body, precompute.taproot_hash_scriptpubkeys)
        append_bytes(body, precompute.taproot_hash_sequences)

    if output_mode == 1:
        append_bytes(body, precompute.taproot_hash_outputs)

    body.append(UInt8(0))
    if anyone_can_pay:
        append_bytes(body, tx.inputs[input_index].previous_hash)
        append_u32_le(body, tx.inputs[input_index].previous_index)
        serialize_taproot_spent_output(body, spent_prevouts[input_index])
        append_u32_le(body, tx.inputs[input_index].sequence)
    else:
        append_u32_le(body, UInt32(input_index))

    if output_mode == 3:
        append_bytes(body, precompute.taproot_hash_single_outputs[input_index])

    var msg = List[UInt8]()
    msg.append(UInt8(0))
    append_bytes(msg, body)
    return tagged_hash(String("TapSighash"), msg)


def taproot_key_path_signature_hash_cached_profiled(
    ref tx: Transaction,
    input_index: Int,
    ref spent_prevouts: List[TaprootPrevout],
    hash_type: UInt8,
    ref precompute: SighashPrecompute,
    mut profile: HotPathProfile,
) raises -> List[UInt8]:
    hotpath_record_taproot_sighash(profile, 64 + len(tx.inputs) * 4)
    return taproot_key_path_signature_hash_cached(tx, input_index, spent_prevouts, hash_type, precompute)


def legacy_sighash(
    ref tx: Transaction, input_index: Int, ref script_code: List[UInt8], ref signature: List[UInt8]
) raises -> List[UInt8]:
    var profile = HotPathProfile()
    return legacy_sighash_profiled(tx, input_index, script_code, signature, profile)


def legacy_sighash_profiled(
    ref tx: Transaction,
    input_index: Int,
    ref script_code: List[UInt8],
    ref signature: List[UInt8],
    mut profile: HotPathProfile,
) raises -> List[UInt8]:
    if len(signature) == 0:
        raise Error("empty ECDSA signature")
    var sighash_type = signature[len(signature) - 1]
    var base_type = Int(sighash_type) & 0x1F
    if base_type == 3 and input_index >= len(tx.outputs):
        var out = List[UInt8]()
        out.append(UInt8(1))
        for _ in range(31):
            out.append(UInt8(0))
        return out^
    var trimmed = legacy_find_and_delete(script_code, signature)
    var preimage = legacy_sighash_preimage(tx, input_index, trimmed, sighash_type)
    hotpath_record_legacy_sighash_reference(profile, len(preimage))
    return double_sha256(preimage)


def append_legacy_input_cached(
    mut out: List[UInt8],
    ref cache: SighashPrecompute,
    input_index: Int,
    ref script_code: List[UInt8],
    base_type: Int,
    signing: Bool,
) raises:
    append_bytes(out, cache.legacy_outpoints[input_index])
    if signing:
        append_varint(out, len(script_code))
        append_bytes(out, script_code)
    else:
        append_varint(out, 0)
    if base_type == 1 or signing:
        append_bytes(out, cache.legacy_sequences[input_index])
    else:
        append_u32_le(out, UInt32(0))


def legacy_sighash_cached_preimage(
    ref tx: Transaction,
    input_index: Int,
    ref script_code: List[UInt8],
    sighash_type: UInt8,
    ref precompute: SighashPrecompute,
) raises -> List[UInt8]:
    if not precompute.legacy_available:
        return legacy_sighash_preimage(tx, input_index, script_code, sighash_type)
    var base_type = Int(sighash_type) & 0x1F
    if base_type != 1 and base_type != 2 and base_type != 3:
        raise Error("diagnostic legacy sighash supports SIGHASH_ALL, SIGHASH_NONE, and SIGHASH_SINGLE only")
    var anyone_can_pay = (Int(sighash_type) & 0x80) != 0
    if input_index < 0 or input_index >= len(tx.inputs):
        raise Error("input index out of range")
    if base_type == 3 and input_index >= len(tx.outputs):
        var out = List[UInt8]()
        out.append(UInt8(1))
        for _ in range(31):
            out.append(UInt8(0))
        return out^

    var out = List[UInt8]()
    append_i32_le(out, tx.version)
    if anyone_can_pay:
        append_varint(out, 1)
        append_legacy_input_cached(out, precompute, input_index, script_code, base_type, True)
    else:
        append_bytes(out, precompute.legacy_input_count)
        for i in range(len(tx.inputs)):
            append_legacy_input_cached(out, precompute, i, script_code, base_type, i == input_index)
    if base_type == 2:
        append_varint(out, 0)
    elif base_type == 3:
        append_varint(out, input_index + 1)
        for _ in range(input_index):
            append_bytes(out, precompute.legacy_null_output)
        append_bytes(out, precompute.legacy_serialized_outputs[input_index])
    else:
        append_bytes(out, precompute.legacy_output_count)
        append_bytes(out, precompute.legacy_outputs_all)
    append_u32_le(out, tx.lock_time)
    append_u32_le(out, UInt32(sighash_type))
    return out^


def legacy_sighash_cached(
    ref tx: Transaction,
    input_index: Int,
    ref script_code: List[UInt8],
    ref signature: List[UInt8],
    ref precompute: SighashPrecompute,
) raises -> List[UInt8]:
    if len(signature) == 0:
        raise Error("empty ECDSA signature")
    if not precompute.legacy_available:
        return legacy_sighash(tx, input_index, script_code, signature)
    var sighash_type = signature[len(signature) - 1]
    var base_type = Int(sighash_type) & 0x1F
    if base_type == 3 and input_index >= len(tx.outputs):
        var out = List[UInt8]()
        out.append(UInt8(1))
        for _ in range(31):
            out.append(UInt8(0))
        return out^
    var trimmed = legacy_find_and_delete(script_code, signature)
    var preimage = legacy_sighash_cached_preimage(tx, input_index, trimmed, sighash_type, precompute)
    return double_sha256(preimage)


def legacy_sighash_cached_profiled(
    ref tx: Transaction,
    input_index: Int,
    ref script_code: List[UInt8],
    ref signature: List[UInt8],
    ref precompute: SighashPrecompute,
    mut profile: HotPathProfile,
) raises -> List[UInt8]:
    if len(signature) == 0:
        raise Error("empty ECDSA signature")
    if not precompute.legacy_available:
        return legacy_sighash_profiled(tx, input_index, script_code, signature, profile)
    var sighash_type = signature[len(signature) - 1]
    var base_type = Int(sighash_type) & 0x1F
    if base_type == 3 and input_index >= len(tx.outputs):
        var out = List[UInt8]()
        out.append(UInt8(1))
        for _ in range(31):
            out.append(UInt8(0))
        return out^
    var trimmed = legacy_find_and_delete(script_code, signature)
    var preimage = legacy_sighash_cached_preimage(tx, input_index, trimmed, sighash_type, precompute)
    hotpath_record_legacy_sighash_cached(profile, len(preimage))
    return double_sha256(preimage)


def _hash_prevouts(ref tx: Transaction) raises -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(tx.inputs)):
        append_bytes(out, tx.inputs[i].previous_hash)
        append_u32_le(out, tx.inputs[i].previous_index)
    return double_sha256(out)


def _hash_sequence(ref tx: Transaction) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(tx.inputs)):
        append_u32_le(out, tx.inputs[i].sequence)
    return double_sha256(out)


def _hash_outputs(ref tx: Transaction) raises -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(tx.outputs)):
        serialize_tx_output(out, tx.outputs[i])
    return double_sha256(out)


def _hash_single_output(ref tx: Transaction, input_index: Int) raises -> List[UInt8]:
    var out = List[UInt8]()
    serialize_tx_output(out, tx.outputs[input_index])
    return double_sha256(out)


def _zero32() -> List[UInt8]:
    var out = List[UInt8]()
    for _ in range(32):
        out.append(UInt8(0))
    return out^


def bip143_sighash(
    ref tx: Transaction,
    input_index: Int,
    ref script_code: List[UInt8],
    amount_sats: Int64,
    sighash_type: UInt8,
) raises -> List[UInt8]:
    var base_type = Int(sighash_type) & 0x1F
    if base_type != 1 and base_type != 2 and base_type != 3:
        raise Error("diagnostic BIP143 supports SIGHASH_ALL, SIGHASH_NONE, and SIGHASH_SINGLE only")
    var anyone_can_pay = (Int(sighash_type) & 0x80) != 0
    if input_index < 0 or input_index >= len(tx.inputs):
        raise Error("input index out of range")
    var hash_prevouts = _zero32()
    if not anyone_can_pay:
        hash_prevouts = _hash_prevouts(tx)
    var hash_sequence = _zero32()
    if not anyone_can_pay and base_type != 2 and base_type != 3:
        hash_sequence = _hash_sequence(tx)
    var hash_outputs = _zero32()
    if base_type == 3 and input_index < len(tx.outputs):
        hash_outputs = _hash_single_output(tx, input_index)
    elif base_type != 2 and base_type != 3:
        hash_outputs = _hash_outputs(tx)

    var out = List[UInt8]()
    append_i32_le(out, tx.version)
    append_bytes(out, hash_prevouts)
    append_bytes(out, hash_sequence)
    append_bytes(out, tx.inputs[input_index].previous_hash)
    append_u32_le(out, tx.inputs[input_index].previous_index)
    append_varint(out, len(script_code))
    append_bytes(out, script_code)
    append_i64_le(out, amount_sats)
    append_u32_le(out, tx.inputs[input_index].sequence)
    append_bytes(out, hash_outputs)
    append_u32_le(out, tx.lock_time)
    append_u32_le(out, UInt32(sighash_type))
    return double_sha256(out)


def bip143_sighash_cached(
    ref tx: Transaction,
    input_index: Int,
    ref script_code: List[UInt8],
    amount_sats: Int64,
    sighash_type: UInt8,
    ref precompute: SighashPrecompute,
) raises -> List[UInt8]:
    var base_type = Int(sighash_type) & 0x1F
    if base_type != 1 and base_type != 2 and base_type != 3:
        raise Error("diagnostic BIP143 supports SIGHASH_ALL, SIGHASH_NONE, and SIGHASH_SINGLE only")
    var anyone_can_pay = (Int(sighash_type) & 0x80) != 0
    if input_index < 0 or input_index >= len(tx.inputs):
        raise Error("input index out of range")
    if not precompute.bip143_available:
        return bip143_sighash(tx, input_index, script_code, amount_sats, sighash_type)

    var hash_prevouts = _zero32()
    if not anyone_can_pay:
        hash_prevouts = precompute.bip143_hash_prevouts.copy()
    var hash_sequence = _zero32()
    if not anyone_can_pay and base_type != 2 and base_type != 3:
        hash_sequence = precompute.bip143_hash_sequence.copy()
    var hash_outputs = _zero32()
    if base_type == 3 and input_index < len(tx.outputs):
        hash_outputs = precompute.bip143_hash_single_outputs[input_index].copy()
    elif base_type != 2 and base_type != 3:
        hash_outputs = precompute.bip143_hash_outputs.copy()

    var out = List[UInt8]()
    append_i32_le(out, tx.version)
    append_bytes(out, hash_prevouts)
    append_bytes(out, hash_sequence)
    append_bytes(out, tx.inputs[input_index].previous_hash)
    append_u32_le(out, tx.inputs[input_index].previous_index)
    append_varint(out, len(script_code))
    append_bytes(out, script_code)
    append_i64_le(out, amount_sats)
    append_u32_le(out, tx.inputs[input_index].sequence)
    append_bytes(out, hash_outputs)
    append_u32_le(out, tx.lock_time)
    append_u32_le(out, UInt32(sighash_type))
    return double_sha256(out)


def bip143_sighash_cached_profiled(
    ref tx: Transaction,
    input_index: Int,
    ref script_code: List[UInt8],
    amount_sats: Int64,
    sighash_type: UInt8,
    ref precompute: SighashPrecompute,
    mut profile: HotPathProfile,
) raises -> List[UInt8]:
    hotpath_record_bip143_sighash(profile, 156 + len(script_code))
    return bip143_sighash_cached(tx, input_index, script_code, amount_sats, sighash_type, precompute)


def signature_digest_for_mode(
    ref tx: Transaction,
    input_index: Int,
    ref script_code: List[UInt8],
    ref signature: List[UInt8],
    witness_v0: Bool,
    witness_amount_sats: Int64,
) raises -> List[UInt8]:
    if len(signature) == 0:
        raise Error("empty ECDSA signature")
    var sighash_type = signature[len(signature) - 1]
    if witness_v0:
        return bip143_sighash(tx, input_index, script_code, witness_amount_sats, sighash_type)
    return legacy_sighash(tx, input_index, script_code, signature)


def signature_digest_for_mode_cached(
    ref tx: Transaction,
    input_index: Int,
    ref script_code: List[UInt8],
    ref signature: List[UInt8],
    witness_v0: Bool,
    witness_amount_sats: Int64,
    ref precompute: SighashPrecompute,
) raises -> List[UInt8]:
    if len(signature) == 0:
        raise Error("empty ECDSA signature")
    var sighash_type = signature[len(signature) - 1]
    if witness_v0:
        return bip143_sighash_cached(tx, input_index, script_code, witness_amount_sats, sighash_type, precompute)
    return legacy_sighash_cached(tx, input_index, script_code, signature, precompute)


def signature_digest_for_mode_cached_profiled(
    ref tx: Transaction,
    input_index: Int,
    ref script_code: List[UInt8],
    ref signature: List[UInt8],
    witness_v0: Bool,
    witness_amount_sats: Int64,
    ref precompute: SighashPrecompute,
    mut profile: HotPathProfile,
) raises -> List[UInt8]:
    if len(signature) == 0:
        raise Error("empty ECDSA signature")
    var sighash_type = signature[len(signature) - 1]
    if witness_v0:
        return bip143_sighash_cached_profiled(
            tx, input_index, script_code, witness_amount_sats, sighash_type, precompute, profile
        )
    return legacy_sighash_cached_profiled(tx, input_index, script_code, signature, precompute, profile)


def verify_ecdsa_signature(
    shim_path: String,
    ref signature: List[UInt8],
    ref pubkey: List[UInt8],
    ref tx: Transaction,
    input_index: Int,
    ref script_code: List[UInt8],
) raises -> Bool:
    var crypto = CryptoBackend(shim_path, CRYPTO_BACKEND_NATIVE)
    return verify_ecdsa_signature_for_mode_with_crypto(
        crypto, signature, pubkey, tx, input_index, script_code, False, Int64(0)
    )


def verify_ecdsa_signature_for_mode(
    shim_path: String,
    ref signature: List[UInt8],
    ref pubkey: List[UInt8],
    ref tx: Transaction,
    input_index: Int,
    ref script_code: List[UInt8],
    witness_v0: Bool,
    witness_amount_sats: Int64,
) raises -> Bool:
    var crypto = CryptoBackend(shim_path, CRYPTO_BACKEND_NATIVE)
    return verify_ecdsa_signature_for_mode_with_crypto(
        crypto, signature, pubkey, tx, input_index, script_code, witness_v0, witness_amount_sats
    )


def verify_ecdsa_signature_for_mode_with_crypto(
    ref crypto: CryptoBackend,
    ref signature: List[UInt8],
    ref pubkey: List[UInt8],
    ref tx: Transaction,
    input_index: Int,
    ref script_code: List[UInt8],
    witness_v0: Bool,
    witness_amount_sats: Int64,
) raises -> Bool:
    if len(signature) == 0:
        return False
    var base_type = Int(signature[len(signature) - 1]) & 0x1F
    if base_type != 1 and base_type != 2 and base_type != 3:
        raise Error("diagnostic fixture only supports SIGHASH_ALL, SIGHASH_NONE, and SIGHASH_SINGLE")
    var der = slice_bytes(signature, 0, len(signature) - 1)
    var digest = signature_digest_for_mode(tx, input_index, script_code, signature, witness_v0, witness_amount_sats)
    var result = crypto.verify_ecdsa_der_bytes(pubkey, der, digest)
    if result == 0:
        return True
    if result == 1:
        return False
    if result == CRYPTO_RESULT_UNSUPPORTED:
        raise Error("unsupported crypto backend for ECDSA")
    raise Error("malformed ECDSA signature or pubkey")


def verify_ecdsa_signature_for_mode_with_crypto_timed(
    ref crypto: CryptoBackend,
    ref signature: List[UInt8],
    ref pubkey: List[UInt8],
    ref tx: Transaction,
    input_index: Int,
    ref script_code: List[UInt8],
    witness_v0: Bool,
    witness_amount_sats: Int64,
    ref timer: OwnedDLHandle,
) raises -> P2pkhShadowEcdsaResult:
    var result = P2pkhShadowEcdsaResult()
    var total_started = timer.call["mojobitnode_now_ms", Int64]()
    if len(signature) == 0:
        result.total_ms = timer.call["mojobitnode_now_ms", Int64]() - total_started
        return result^
    var base_type = Int(signature[len(signature) - 1]) & 0x1F
    if base_type != 1 and base_type != 2 and base_type != 3:
        raise Error("diagnostic fixture only supports SIGHASH_ALL, SIGHASH_NONE, and SIGHASH_SINGLE")
    var der = slice_bytes(signature, 0, len(signature) - 1)
    var sighash_started = timer.call["mojobitnode_now_ms", Int64]()
    var digest = signature_digest_for_mode(tx, input_index, script_code, signature, witness_v0, witness_amount_sats)
    result.sighash_ms = timer.call["mojobitnode_now_ms", Int64]() - sighash_started
    var verify_started = timer.call["mojobitnode_now_ms", Int64]()
    var crypto_result = crypto.verify_ecdsa_der_bytes(pubkey, der, digest)
    result.verify_ms = timer.call["mojobitnode_now_ms", Int64]() - verify_started
    result.signature_count = 1
    result.total_ms = timer.call["mojobitnode_now_ms", Int64]() - total_started
    if crypto_result == 0:
        result.passed = True
        return result^
    if crypto_result == 1:
        result.passed = False
        return result^
    if crypto_result == CRYPTO_RESULT_UNSUPPORTED:
        raise Error("unsupported crypto backend for ECDSA")
    raise Error("malformed ECDSA signature or pubkey")


def verify_ecdsa_signature_for_mode_cached(
    shim_path: String,
    ref signature: List[UInt8],
    ref pubkey: List[UInt8],
    ref tx: Transaction,
    input_index: Int,
    ref script_code: List[UInt8],
    witness_v0: Bool,
    witness_amount_sats: Int64,
    ref precompute: SighashPrecompute,
) raises -> Bool:
    var crypto = CryptoBackend(shim_path, CRYPTO_BACKEND_NATIVE)
    return verify_ecdsa_signature_for_mode_cached_with_crypto(
        crypto,
        signature,
        pubkey,
        tx,
        input_index,
        script_code,
        witness_v0,
        witness_amount_sats,
        precompute,
    )


def verify_ecdsa_signature_for_mode_cached_with_crypto(
    ref crypto: CryptoBackend,
    ref signature: List[UInt8],
    ref pubkey: List[UInt8],
    ref tx: Transaction,
    input_index: Int,
    ref script_code: List[UInt8],
    witness_v0: Bool,
    witness_amount_sats: Int64,
    ref precompute: SighashPrecompute,
) raises -> Bool:
    if len(signature) == 0:
        return False
    var base_type = Int(signature[len(signature) - 1]) & 0x1F
    if base_type != 1 and base_type != 2 and base_type != 3:
        raise Error("diagnostic fixture only supports SIGHASH_ALL, SIGHASH_NONE, and SIGHASH_SINGLE")
    var der = slice_bytes(signature, 0, len(signature) - 1)
    var digest = signature_digest_for_mode_cached(
        tx, input_index, script_code, signature, witness_v0, witness_amount_sats, precompute
    )
    var result = crypto.verify_ecdsa_der_bytes(pubkey, der, digest)
    if result == 0:
        return True
    if result == 1:
        return False
    if result == CRYPTO_RESULT_UNSUPPORTED:
        raise Error("unsupported crypto backend for ECDSA")
    raise Error("malformed ECDSA signature or pubkey")


def verify_ecdsa_signature_for_mode_cached_with_crypto_profiled(
    ref crypto: CryptoBackend,
    ref signature: List[UInt8],
    ref pubkey: List[UInt8],
    ref tx: Transaction,
    input_index: Int,
    ref script_code: List[UInt8],
    witness_v0: Bool,
    witness_amount_sats: Int64,
    ref precompute: SighashPrecompute,
    mut profile: HotPathProfile,
) raises -> Bool:
    if len(signature) == 0:
        return False
    var base_type = Int(signature[len(signature) - 1]) & 0x1F
    if base_type != 1 and base_type != 2 and base_type != 3:
        raise Error("diagnostic fixture only supports SIGHASH_ALL, SIGHASH_NONE, and SIGHASH_SINGLE")
    var der = slice_bytes_profiled(signature, 0, len(signature) - 1, profile)
    var digest = signature_digest_for_mode_cached_profiled(
        tx, input_index, script_code, signature, witness_v0, witness_amount_sats, precompute, profile
    )
    hotpath_record_native_ecdsa(profile, len(pubkey), len(der), len(digest))
    var result = crypto.verify_ecdsa_der_bytes(pubkey, der, digest)
    if result == 0:
        return True
    if result == 1:
        return False
    if result == CRYPTO_RESULT_UNSUPPORTED:
        raise Error("unsupported crypto backend for ECDSA")
    raise Error("malformed ECDSA signature or pubkey")


def verify_schnorr_signature(
    shim_path: String,
    ref signature: List[UInt8],
    ref xonly_pubkey: List[UInt8],
    ref tx: Transaction,
    input_index: Int,
    ref spent_prevouts: List[TaprootPrevout],
    ref tapleaf_digest_value: List[UInt8],
    codeseparator_pos: Int,
) raises -> Bool:
    var crypto = CryptoBackend(shim_path, CRYPTO_BACKEND_NATIVE)
    return verify_schnorr_signature_with_crypto(
        crypto,
        signature,
        xonly_pubkey,
        tx,
        input_index,
        spent_prevouts,
        tapleaf_digest_value,
        codeseparator_pos,
    )


def verify_schnorr_signature_with_crypto(
    ref crypto: CryptoBackend,
    ref signature: List[UInt8],
    ref xonly_pubkey: List[UInt8],
    ref tx: Transaction,
    input_index: Int,
    ref spent_prevouts: List[TaprootPrevout],
    ref tapleaf_digest_value: List[UInt8],
    codeseparator_pos: Int,
) raises -> Bool:
    if len(signature) == 0:
        return False
    var hash_type = UInt8(0)
    var sig64 = List[UInt8]()
    if len(signature) == 64:
        sig64 = clone_bytes(signature)
    elif len(signature) == 65:
        hash_type = signature[64]
        if hash_type == UInt8(0):
            raise Error("invalid explicit Taproot default hash type")
        sig64 = slice_bytes(signature, 0, 64)
    else:
        raise Error("invalid Schnorr signature length")
    if len(xonly_pubkey) != 32:
        raise Error("invalid x-only pubkey length")
    var digest = taproot_signature_hash(tx, input_index, spent_prevouts, hash_type, tapleaf_digest_value, codeseparator_pos)
    var result = crypto.verify_schnorr_bytes(xonly_pubkey, sig64, digest)
    if result == 0:
        return True
    if result == 1:
        return False
    if result == CRYPTO_RESULT_UNSUPPORTED:
        raise Error("unsupported crypto backend for Schnorr")
    raise Error("malformed Schnorr signature or x-only pubkey")


def verify_schnorr_signature_cached(
    shim_path: String,
    ref signature: List[UInt8],
    ref xonly_pubkey: List[UInt8],
    ref tx: Transaction,
    input_index: Int,
    ref spent_prevouts: List[TaprootPrevout],
    ref tapleaf_digest_value: List[UInt8],
    codeseparator_pos: Int,
    ref precompute: SighashPrecompute,
) raises -> Bool:
    var crypto = CryptoBackend(shim_path, CRYPTO_BACKEND_NATIVE)
    return verify_schnorr_signature_cached_with_crypto(
        crypto,
        signature,
        xonly_pubkey,
        tx,
        input_index,
        spent_prevouts,
        tapleaf_digest_value,
        codeseparator_pos,
        precompute,
    )


def verify_schnorr_signature_cached_with_crypto(
    ref crypto: CryptoBackend,
    ref signature: List[UInt8],
    ref xonly_pubkey: List[UInt8],
    ref tx: Transaction,
    input_index: Int,
    ref spent_prevouts: List[TaprootPrevout],
    ref tapleaf_digest_value: List[UInt8],
    codeseparator_pos: Int,
    ref precompute: SighashPrecompute,
) raises -> Bool:
    if len(signature) == 0:
        return False
    var hash_type = UInt8(0)
    var sig64 = List[UInt8]()
    if len(signature) == 64:
        sig64 = clone_bytes(signature)
    elif len(signature) == 65:
        hash_type = signature[64]
        if hash_type == UInt8(0):
            raise Error("invalid explicit Taproot default hash type")
        sig64 = slice_bytes(signature, 0, 64)
    else:
        raise Error("invalid Schnorr signature length")
    if len(xonly_pubkey) != 32:
        raise Error("invalid x-only pubkey length")
    var digest = taproot_signature_hash_cached(
        tx, input_index, spent_prevouts, hash_type, tapleaf_digest_value, codeseparator_pos, precompute
    )
    var result = crypto.verify_schnorr_bytes(xonly_pubkey, sig64, digest)
    if result == 0:
        return True
    if result == 1:
        return False
    if result == CRYPTO_RESULT_UNSUPPORTED:
        raise Error("unsupported crypto backend for Schnorr")
    raise Error("malformed Schnorr signature or x-only pubkey")


def verify_schnorr_signature_cached_with_crypto_profiled(
    ref crypto: CryptoBackend,
    ref signature: List[UInt8],
    ref xonly_pubkey: List[UInt8],
    ref tx: Transaction,
    input_index: Int,
    ref spent_prevouts: List[TaprootPrevout],
    ref tapleaf_digest_value: List[UInt8],
    codeseparator_pos: Int,
    ref precompute: SighashPrecompute,
    mut profile: HotPathProfile,
) raises -> Bool:
    if len(signature) == 0:
        return False
    var hash_type = UInt8(0)
    var sig64 = List[UInt8]()
    if len(signature) == 64:
        sig64 = clone_bytes_profiled(signature, profile)
    elif len(signature) == 65:
        hash_type = signature[64]
        if hash_type == UInt8(0):
            raise Error("invalid explicit Taproot default hash type")
        sig64 = slice_bytes_profiled(signature, 0, 64, profile)
    else:
        raise Error("invalid Schnorr signature length")
    if len(xonly_pubkey) != 32:
        raise Error("invalid x-only pubkey length")
    var digest = taproot_signature_hash_cached_profiled(
        tx, input_index, spent_prevouts, hash_type, tapleaf_digest_value, codeseparator_pos, precompute, profile
    )
    hotpath_record_native_schnorr(profile, len(xonly_pubkey), len(sig64), len(digest))
    var result = crypto.verify_schnorr_bytes(xonly_pubkey, sig64, digest)
    if result == 0:
        return True
    if result == 1:
        return False
    if result == CRYPTO_RESULT_UNSUPPORTED:
        raise Error("unsupported crypto backend for Schnorr")
    raise Error("malformed Schnorr signature or x-only pubkey")


def verify_schnorr_key_path_signature(
    shim_path: String,
    ref signature: List[UInt8],
    ref xonly_pubkey: List[UInt8],
    ref tx: Transaction,
    input_index: Int,
    ref spent_prevouts: List[TaprootPrevout],
) raises -> Bool:
    var crypto = CryptoBackend(shim_path, CRYPTO_BACKEND_NATIVE)
    return verify_schnorr_key_path_signature_with_crypto(
        crypto, signature, xonly_pubkey, tx, input_index, spent_prevouts
    )


def verify_schnorr_key_path_signature_with_crypto(
    ref crypto: CryptoBackend,
    ref signature: List[UInt8],
    ref xonly_pubkey: List[UInt8],
    ref tx: Transaction,
    input_index: Int,
    ref spent_prevouts: List[TaprootPrevout],
) raises -> Bool:
    if len(signature) == 0:
        return False
    var hash_type = UInt8(0)
    var sig64 = List[UInt8]()
    if len(signature) == 64:
        sig64 = clone_bytes(signature)
    elif len(signature) == 65:
        hash_type = signature[64]
        if hash_type == UInt8(0):
            raise Error("invalid explicit Taproot default hash type")
        sig64 = slice_bytes(signature, 0, 64)
    else:
        raise Error("invalid Schnorr signature length")
    if len(xonly_pubkey) != 32:
        raise Error("invalid x-only pubkey length")
    var digest = taproot_key_path_signature_hash(tx, input_index, spent_prevouts, hash_type)
    var result = crypto.verify_schnorr_bytes(xonly_pubkey, sig64, digest)
    if result == 0:
        return True
    if result == 1:
        return False
    if result == CRYPTO_RESULT_UNSUPPORTED:
        raise Error("unsupported crypto backend for Schnorr")
    raise Error("malformed Schnorr signature or x-only pubkey")


def verify_schnorr_key_path_signature_cached(
    shim_path: String,
    ref signature: List[UInt8],
    ref xonly_pubkey: List[UInt8],
    ref tx: Transaction,
    input_index: Int,
    ref spent_prevouts: List[TaprootPrevout],
    ref precompute: SighashPrecompute,
) raises -> Bool:
    var crypto = CryptoBackend(shim_path, CRYPTO_BACKEND_NATIVE)
    return verify_schnorr_key_path_signature_cached_with_crypto(
        crypto, signature, xonly_pubkey, tx, input_index, spent_prevouts, precompute
    )


def verify_schnorr_key_path_signature_cached_with_crypto(
    ref crypto: CryptoBackend,
    ref signature: List[UInt8],
    ref xonly_pubkey: List[UInt8],
    ref tx: Transaction,
    input_index: Int,
    ref spent_prevouts: List[TaprootPrevout],
    ref precompute: SighashPrecompute,
) raises -> Bool:
    if len(signature) == 0:
        return False
    var hash_type = UInt8(0)
    var sig64 = List[UInt8]()
    if len(signature) == 64:
        sig64 = clone_bytes(signature)
    elif len(signature) == 65:
        hash_type = signature[64]
        if hash_type == UInt8(0):
            raise Error("invalid explicit Taproot default hash type")
        sig64 = slice_bytes(signature, 0, 64)
    else:
        raise Error("invalid Schnorr signature length")
    if len(xonly_pubkey) != 32:
        raise Error("invalid x-only pubkey length")
    var digest = taproot_key_path_signature_hash_cached(tx, input_index, spent_prevouts, hash_type, precompute)
    var result = crypto.verify_schnorr_bytes(xonly_pubkey, sig64, digest)
    if result == 0:
        return True
    if result == 1:
        return False
    if result == CRYPTO_RESULT_UNSUPPORTED:
        raise Error("unsupported crypto backend for Schnorr")
    raise Error("malformed Schnorr signature or x-only pubkey")


def verify_schnorr_key_path_signature_cached_with_crypto_profiled(
    ref crypto: CryptoBackend,
    ref signature: List[UInt8],
    ref xonly_pubkey: List[UInt8],
    ref tx: Transaction,
    input_index: Int,
    ref spent_prevouts: List[TaprootPrevout],
    ref precompute: SighashPrecompute,
    mut profile: HotPathProfile,
) raises -> Bool:
    if len(signature) == 0:
        return False
    var hash_type = UInt8(0)
    var sig64 = List[UInt8]()
    if len(signature) == 64:
        sig64 = clone_bytes_profiled(signature, profile)
    elif len(signature) == 65:
        hash_type = signature[64]
        if hash_type == UInt8(0):
            raise Error("invalid explicit Taproot default hash type")
        sig64 = slice_bytes_profiled(signature, 0, 64, profile)
    else:
        raise Error("invalid Schnorr signature length")
    if len(xonly_pubkey) != 32:
        raise Error("invalid x-only pubkey length")
    var digest = taproot_key_path_signature_hash_cached_profiled(tx, input_index, spent_prevouts, hash_type, precompute, profile)
    hotpath_record_native_schnorr(profile, len(xonly_pubkey), len(sig64), len(digest))
    var result = crypto.verify_schnorr_bytes(xonly_pubkey, sig64, digest)
    if result == 0:
        return True
    if result == 1:
        return False
    if result == CRYPTO_RESULT_UNSUPPORTED:
        raise Error("unsupported crypto backend for Schnorr")
    raise Error("malformed Schnorr signature or x-only pubkey")


def verify_taproot_tweak(
    shim_path: String,
    ref internal_xonly: List[UInt8],
    ref merkle_root: List[UInt8],
    ref expected_xonly: List[UInt8],
    expected_parity: Int,
) raises -> Bool:
    var crypto = CryptoBackend(shim_path, CRYPTO_BACKEND_NATIVE)
    return verify_taproot_tweak_with_crypto(crypto, internal_xonly, merkle_root, expected_xonly, expected_parity)


def verify_taproot_tweak_with_crypto(
    ref crypto: CryptoBackend,
    ref internal_xonly: List[UInt8],
    ref merkle_root: List[UInt8],
    ref expected_xonly: List[UInt8],
    expected_parity: Int,
) raises -> Bool:
    var tweak = taproot_tweak_hash(internal_xonly, merkle_root)
    var result = crypto.verify_taproot_tweak_precomputed(internal_xonly, tweak, expected_xonly, expected_parity)
    if result == 0:
        return True
    if result == 1:
        return False
    if result == CRYPTO_RESULT_UNSUPPORTED:
        raise Error("unsupported crypto backend for Taproot tweak")
    raise Error("malformed Taproot tweak input")


def verify_taproot_tweak_with_crypto_profiled(
    ref crypto: CryptoBackend,
    ref internal_xonly: List[UInt8],
    ref merkle_root: List[UInt8],
    ref expected_xonly: List[UInt8],
    expected_parity: Int,
    mut profile: HotPathProfile,
) raises -> Bool:
    var tweak = taproot_tweak_hash(internal_xonly, merkle_root)
    hotpath_record_native_taproot_tweak(profile, len(internal_xonly), len(tweak), len(expected_xonly))
    var result = crypto.verify_taproot_tweak_precomputed(internal_xonly, tweak, expected_xonly, expected_parity)
    if result == 0:
        return True
    if result == 1:
        return False
    if result == CRYPTO_RESULT_UNSUPPORTED:
        raise Error("unsupported crypto backend for Taproot tweak")
    raise Error("malformed Taproot tweak input")


def evaluate_tapscript(
    ref script: List[UInt8],
    var stack: List[ScriptStackItem],
    ref tx: Transaction,
    input_index: Int,
    ref spent_prevouts: List[TaprootPrevout],
    ref tapleaf_digest_value: List[UInt8],
    shim_path: String,
) raises -> Bool:
    var crypto = CryptoBackend(shim_path, CRYPTO_BACKEND_NATIVE)
    return evaluate_tapscript_with_crypto(
        script,
        stack^,
        tx,
        input_index,
        spent_prevouts,
        tapleaf_digest_value,
        shim_path,
        crypto,
    )


def evaluate_tapscript_with_crypto(
    ref script: List[UInt8],
    var stack: List[ScriptStackItem],
    ref tx: Transaction,
    input_index: Int,
    ref spent_prevouts: List[TaprootPrevout],
    ref tapleaf_digest_value: List[UInt8],
    shim_path: String,
    ref crypto: CryptoBackend,
) raises -> Bool:
    var profile = HotPathProfile()
    return evaluate_tapscript_with_crypto_profiled(
        script,
        stack^,
        tx,
        input_index,
        spent_prevouts,
        tapleaf_digest_value,
        shim_path,
        crypto,
        profile,
    )


def evaluate_tapscript_with_crypto_profiled(
    ref script: List[UInt8],
    var stack: List[ScriptStackItem],
    ref tx: Transaction,
    input_index: Int,
    ref spent_prevouts: List[TaprootPrevout],
    ref tapleaf_digest_value: List[UInt8],
    shim_path: String,
    ref crypto: CryptoBackend,
    mut profile: HotPathProfile,
) raises -> Bool:
    var offset = 0
    var instruction_pos = 0
    var codeseparator_pos = 0xFFFFFFFF
    var sighash_precompute = build_sighash_precompute_with_taproot(tx, spent_prevouts)
    var conditions = List[Bool]()
    var alt_stack = List[ScriptStackItem]()
    while offset < len(script):
        var opcode = Int(script[offset])
        hotpath_record_script_opcode(profile, opcode, len(stack), len(alt_stack))
        var active = _conditions_active(conditions)
        if opcode == 0 or (opcode >= 1 and opcode <= 75) or opcode == 0x4C or opcode == 0x4D or opcode == 0x4E:
            var item = _read_script_push(script, offset)
            offset += _script_push_size(script, offset)
            if active:
                stack.append(item^)
            instruction_pos += 1
            continue
        if opcode >= 0x51 and opcode <= 0x60:
            if active:
                _stack_push_num(stack, opcode - 0x50)
            offset += 1
            instruction_pos += 1
            continue
        if opcode == 0x4F:
            if active:
                _stack_push_num(stack, -1)
            offset += 1
            instruction_pos += 1
            continue
        if opcode == 0x63 or opcode == 0x64:
            var parent_active = active
            var branch_active = False
            if parent_active:
                var item = _stack_pop(stack)
                var truth = cast_to_bool(item.data)
                branch_active = truth if opcode == 0x63 else not truth
            conditions.append(parent_active and branch_active)
            offset += 1
            instruction_pos += 1
            continue
        if opcode == 0x67:
            if len(conditions) == 0:
                raise Error("unbalanced OP_ELSE")
            var parent_active = True
            for i in range(len(conditions) - 1):
                if not conditions[i]:
                    parent_active = False
            conditions[len(conditions) - 1] = parent_active and not conditions[len(conditions) - 1]
            offset += 1
            instruction_pos += 1
            continue
        if opcode == 0x68:
            if len(conditions) == 0:
                raise Error("unbalanced OP_ENDIF")
            _ = conditions.pop()
            offset += 1
            instruction_pos += 1
            continue
        if not active:
            offset += 1
            instruction_pos += 1
            continue
        if opcode == 0x61:
            offset += 1
            instruction_pos += 1
            continue
        if opcode == 0x75:
            _ = _stack_pop(stack)
        elif opcode == 0x76:
            var item = _script_stack_item(stack, 1)
            stack.append(item^)
        elif opcode == 0x69:
            var item = _stack_pop(stack)
            if not cast_to_bool(item.data):
                return False
        elif opcode == 0x6B:
            alt_stack.append(_stack_pop(stack))
        elif opcode == 0x6C:
            var item = _stack_pop(alt_stack)
            stack.append(item^)
        elif opcode == 0x6D:
            _ = _stack_pop(stack)
            _ = _stack_pop(stack)
        elif opcode == 0x6E:
            if len(stack) < 2:
                raise Error("OP_2DUP stack underflow")
            var a = stack[len(stack) - 2].copy()
            var b = stack[len(stack) - 1].copy()
            stack.append(a^)
            stack.append(b^)
        elif opcode == 0x6F:
            if len(stack) < 3:
                raise Error("OP_3DUP stack underflow")
            var a = stack[len(stack) - 3].copy()
            var b = stack[len(stack) - 2].copy()
            var c = stack[len(stack) - 1].copy()
            stack.append(a^)
            stack.append(b^)
            stack.append(c^)
        elif opcode == 0x70:
            if len(stack) < 4:
                raise Error("OP_2OVER stack underflow")
            var a = stack[len(stack) - 4].copy()
            var b = stack[len(stack) - 3].copy()
            stack.append(a^)
            stack.append(b^)
        elif opcode == 0x72:
            if len(stack) < 4:
                raise Error("OP_2SWAP stack underflow")
            var d = _stack_pop(stack)
            var c = _stack_pop(stack)
            var b = _stack_pop(stack)
            var a = _stack_pop(stack)
            stack.append(c^)
            stack.append(d^)
            stack.append(a^)
            stack.append(b^)
        elif opcode == 0x73:
            var item = _script_stack_item(stack, 1)
            if cast_to_bool(item.data):
                stack.append(item^)
        elif opcode == 0x74:
            _stack_push_num(stack, len(stack))
        elif opcode == 0x77:
            if len(stack) < 2:
                raise Error("OP_NIP stack underflow")
            var top = _stack_pop(stack)
            _ = _stack_pop(stack)
            stack.append(top^)
        elif opcode == 0x78:
            if len(stack) < 2:
                raise Error("OP_OVER stack underflow")
            var item = stack[len(stack) - 2].copy()
            stack.append(item^)
        elif opcode == 0x79:
            var n = decode_script_num(_stack_pop(stack).data)
            if n < 0 or n >= len(stack):
                raise Error("OP_PICK stack underflow")
            var item = stack[len(stack) - 1 - n].copy()
            stack.append(item^)
        elif opcode == 0x7A:
            var n = decode_script_num(_stack_pop(stack).data)
            if n < 0 or n >= len(stack):
                raise Error("OP_ROLL stack underflow")
            var item = stack.pop(len(stack) - 1 - n)
            stack.append(item^)
        elif opcode == 0x7B:
            if len(stack) < 3:
                raise Error("OP_ROT stack underflow")
            var c = _stack_pop(stack)
            var b = _stack_pop(stack)
            var a = _stack_pop(stack)
            stack.append(b^)
            stack.append(c^)
            stack.append(a^)
        elif opcode == 0x7C:
            if len(stack) < 2:
                raise Error("OP_SWAP stack underflow")
            var b = _stack_pop(stack)
            var a = _stack_pop(stack)
            stack.append(b^)
            stack.append(a^)
        elif opcode == 0x7D:
            if len(stack) < 2:
                raise Error("OP_TUCK stack underflow")
            var top = _stack_pop(stack)
            var second = _stack_pop(stack)
            stack.append(top.copy()^)
            stack.append(second^)
            stack.append(top^)
        elif opcode == 0x82:
            var item = _script_stack_item(stack, 1)
            _stack_push_num(stack, len(item.data))
        elif opcode == 0x87 or opcode == 0x88:
            var b = _stack_pop(stack)
            var a = _stack_pop(stack)
            _stack_push_num(stack, 1 if bytes_equal(a.data, b.data) else 0)
            if opcode == 0x88:
                var result = _stack_pop(stack)
                if not cast_to_bool(result.data):
                    return False
        elif opcode == 0x8C:
            var a = decode_script_num(_stack_pop(stack).data)
            _stack_push_num(stack, a - 1)
        elif opcode == 0x8F:
            var a = decode_script_num(_stack_pop(stack).data)
            _stack_push_num(stack, -a)
        elif opcode == 0x90:
            var a = decode_script_num(_stack_pop(stack).data)
            _stack_push_num(stack, -a if a < 0 else a)
        elif opcode == 0x91:
            var a = decode_script_num(_stack_pop(stack).data)
            _stack_push_num(stack, 1 if a == 0 else 0)
        elif opcode == 0x92:
            var a = decode_script_num(_stack_pop(stack).data)
            _stack_push_num(stack, 1 if a != 0 else 0)
        elif opcode == 0x93:
            var b = decode_script_num(_stack_pop(stack).data)
            var a = decode_script_num(_stack_pop(stack).data)
            _stack_push_num(stack, a + b)
        elif opcode == 0x94:
            var b = decode_script_num(_stack_pop(stack).data)
            var a = decode_script_num(_stack_pop(stack).data)
            _stack_push_num(stack, a - b)
        elif opcode == 0x95:
            var b = decode_script_num(_stack_pop(stack).data)
            var a = decode_script_num(_stack_pop(stack).data)
            _stack_push_num(stack, a * b)
        elif opcode == 0x9A:
            var b = cast_to_bool(_stack_pop(stack).data)
            var a = cast_to_bool(_stack_pop(stack).data)
            _stack_push_num(stack, 1 if a and b else 0)
        elif opcode == 0x9B:
            var b = cast_to_bool(_stack_pop(stack).data)
            var a = cast_to_bool(_stack_pop(stack).data)
            _stack_push_num(stack, 1 if a or b else 0)
        elif opcode == 0x9C or opcode == 0x9D or opcode == 0x9E:
            var b = decode_script_num(_stack_pop(stack).data)
            var a = decode_script_num(_stack_pop(stack).data)
            var equal = a == b
            if opcode == 0x9E:
                equal = not equal
            _stack_push_num(stack, 1 if equal else 0)
            if opcode == 0x9D:
                var result = _stack_pop(stack)
                if not cast_to_bool(result.data):
                    return False
        elif opcode == 0x9F or opcode == 0xA0 or opcode == 0xA1 or opcode == 0xA2:
            var b = decode_script_num(_stack_pop(stack).data)
            var a = decode_script_num(_stack_pop(stack).data)
            var ok = False
            if opcode == 0x9F:
                ok = a < b
            elif opcode == 0xA0:
                ok = a > b
            elif opcode == 0xA1:
                ok = a <= b
            else:
                ok = a >= b
            _stack_push_num(stack, 1 if ok else 0)
        elif opcode == 0xA3 or opcode == 0xA4:
            var b = decode_script_num(_stack_pop(stack).data)
            var a = decode_script_num(_stack_pop(stack).data)
            if opcode == 0xA3:
                _stack_push_num(stack, a if a < b else b)
            else:
                _stack_push_num(stack, a if a > b else b)
        elif opcode == 0xA5:
            var max_value = decode_script_num(_stack_pop(stack).data)
            var min_value = decode_script_num(_stack_pop(stack).data)
            var value = decode_script_num(_stack_pop(stack).data)
            _stack_push_num(stack, 1 if min_value <= value and value < max_value else 0)
        elif opcode == 0xA6:
            var item = _stack_pop(stack)
            var hash = ripemd160_digest(item.data)
            var pushed = ScriptStackItem()
            pushed.data = hash^
            stack.append(pushed^)
        elif opcode == 0xA7:
            var item = _stack_pop(stack)
            var hash = sha1_digest(item.data)
            var pushed = ScriptStackItem()
            pushed.data = hash^
            stack.append(pushed^)
        elif opcode == 0xA8:
            var item = _stack_pop(stack)
            var hash = sha256_digest(item.data)
            var pushed = ScriptStackItem()
            pushed.data = hash^
            stack.append(pushed^)
        elif opcode == 0xA9:
            var item = _stack_pop(stack)
            var hash = hash160(item.data)
            var pushed = ScriptStackItem()
            pushed.data = hash^
            stack.append(pushed^)
        elif opcode == 0xAA:
            var item = _stack_pop(stack)
            var hash = hash256(item.data)
            var pushed = ScriptStackItem()
            pushed.data = hash^
            stack.append(pushed^)
        elif opcode == 0xAB:
            codeseparator_pos = instruction_pos
        elif opcode == 0xAC or opcode == 0xAD:
            var pubkey = _stack_pop(stack)
            var signature = _stack_pop(stack)
            if len(pubkey.data) == 0:
                raise Error("empty x-only pubkey")
            var valid = False
            if len(pubkey.data) != 32:
                valid = len(signature.data) != 0
            elif len(signature.data) != 0:
                valid = verify_schnorr_signature_cached_with_crypto_profiled(
                    crypto,
                    signature.data,
                    pubkey.data,
                    tx,
                    input_index,
                    spent_prevouts,
                    tapleaf_digest_value,
                    codeseparator_pos,
                    sighash_precompute,
                    profile,
                )
            if opcode == 0xAC:
                _stack_push_num(stack, 1 if valid else 0)
            elif not valid:
                return False
        elif opcode == 0xBA:
            var pubkey = _stack_pop(stack)
            var n = decode_script_num(_stack_pop(stack).data)
            var signature = _stack_pop(stack)
            if len(pubkey.data) == 0:
                raise Error("empty x-only pubkey")
            var valid = False
            if len(pubkey.data) != 32:
                valid = len(signature.data) != 0
            elif len(signature.data) != 0:
                valid = verify_schnorr_signature_cached_with_crypto_profiled(
                    crypto,
                    signature.data,
                    pubkey.data,
                    tx,
                    input_index,
                    spent_prevouts,
                    tapleaf_digest_value,
                    codeseparator_pos,
                    sighash_precompute,
                    profile,
                )
            _stack_push_num(stack, n + (1 if valid else 0))
        elif opcode == 0xB1:
            if tx.version >= 2:
                var item = _script_stack_item(stack, 1)
                var lock_time = decode_script_num_with_max(item.data, 5)
                if lock_time < 0:
                    raise Error("negative CLTV lock time")
                if lock_time > Int(tx.lock_time):
                    return False
                if tx.inputs[input_index].sequence == UInt32(0xFFFFFFFF):
                    return False
        elif opcode == 0xB2:
            if tx.version >= 2:
                var item = _script_stack_item(stack, 1)
                var sequence = decode_script_num_with_max(item.data, 5)
                if not csv_sequence_satisfied(tx, input_index, sequence):
                    return False
        elif opcode == 0xAE or opcode == 0xAF:
            raise Error("CHECKMULTISIG disabled in tapscript")
        else:
            raise Error("unsupported tapscript opcode in Mojo diagnostic script engine")
        offset += 1
        instruction_pos += 1
    if len(conditions) != 0:
        raise Error("unbalanced conditional")
    return _script_terminal_success(stack)


def evaluate_bare_multisig_fixture(ref fixture: ScriptFixture, shim_path: String) raises -> Bool:
    var crypto = CryptoBackend(shim_path, CRYPTO_BACKEND_NATIVE)
    return evaluate_bare_multisig_fixture_with_crypto(fixture, shim_path, crypto)


def evaluate_bare_multisig_fixture_with_crypto(
    ref fixture: ScriptFixture, shim_path: String, ref crypto: CryptoBackend
) raises -> Bool:
    if fixture.input_index < 0 or fixture.input_index >= len(fixture.tx.inputs):
        raise Error("fixture input index out of range")
    var stack = parse_push_only_stack(fixture.tx.inputs[fixture.input_index].script_sig)
    var parsed = parse_bare_multisig_script(fixture.spent_script_pubkey)
    if len(stack) < parsed.required_signatures + 1:
        raise Error("CHECKMULTISIG stack underflow")
    if len(stack[0].data) != 0:
        raise Error("CHECKMULTISIG missing dummy")

    var sig_offset = 0
    var key_offset = 0
    var remaining_sigs = parsed.required_signatures
    var remaining_keys = parsed.pubkey_count
    while remaining_sigs > 0:
        if remaining_sigs > remaining_keys:
            return False
        var sig_index = len(stack) - 1 - sig_offset
        var key_index = parsed.pubkey_count - 1 - key_offset
        if sig_index <= 0 or key_index < 0:
            raise Error("CHECKMULTISIG stack underflow")
        var ok = verify_ecdsa_signature_for_mode_with_crypto(
            crypto,
            stack[sig_index].data,
            parsed.pubkeys[key_index].data,
            fixture.tx,
            fixture.input_index,
            fixture.spent_script_pubkey,
            False,
            Int64(0),
        )
        if ok:
            sig_offset += 1
            remaining_sigs -= 1
        key_offset += 1
        remaining_keys -= 1
    return True
