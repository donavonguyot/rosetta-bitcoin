from std.collections import List
from std.ffi import OwnedDLHandle
from std.pathlib import Path


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


struct Transaction(Movable):
    var version: Int32
    var inputs: List[TxInput]
    var outputs: List[TxOutput]
    var witness_item_count_by_input: List[Int]
    var lock_time: UInt32
    var has_witness: Bool

    def __init__(out self):
        self.version = 0
        self.inputs = List[TxInput]()
        self.outputs = List[TxOutput]()
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


struct ScriptStackItem(Copyable):
    var data: List[UInt8]

    def __init__(out self):
        self.data = List[UInt8]()


struct BareMultisigScript(Movable):
    var required_signatures: Int
    var pubkeys: List[ScriptStackItem]
    var pubkey_count: Int

    def __init__(out self):
        self.required_signatures = 0
        self.pubkeys = List[ScriptStackItem]()
        self.pubkey_count = 0


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


def slice_bytes(ref bytes: List[UInt8], start: Int, end: Int) raises -> List[UInt8]:
    if start < 0 or end < start or end > len(bytes):
        raise Error("invalid byte slice bounds")
    var out = List[UInt8]()
    for i in range(start, end):
        out.append(bytes[i])
    return out^


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
    if opcode >= 0x51 and opcode <= 0x60:
        item.data.append(UInt8(opcode - 0x50))
        return item^
    raise Error("unsupported push opcode in diagnostic fixture")


def parse_push_only_stack(ref script: List[UInt8]) raises -> List[ScriptStackItem]:
    var stack = List[ScriptStackItem]()
    var offset = 0
    while offset < len(script):
        var opcode = Int(script[offset])
        var item = _read_script_push(script, offset)
        if opcode >= 1 and opcode <= 75:
            offset += 1 + opcode
        else:
            offset += 1
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


def decode_script_num(ref item: List[UInt8]) raises -> Int:
    if len(item) > 4:
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


def _script_stack_item(ref stack: List[ScriptStackItem], depth_from_top: Int) raises -> ScriptStackItem:
    if depth_from_top <= 0 or len(stack) < depth_from_top:
        raise Error("script stack underflow")
    return stack[len(stack) - depth_from_top]


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
            tx.witness_item_count_by_input.append(stack_count)
            for _ in range(stack_count):
                _ = cursor.read_bytes(cursor.read_varint())

    tx.lock_time = cursor.read_u32_le()
    if cursor.remaining() != 0:
        raise Error("transaction parser consumed partial payload")
    return tx^


def serialize_tx_output(mut out: List[UInt8], ref output: TxOutput) raises:
    append_i64_le(out, output.value)
    append_varint(out, len(output.script_pubkey))
    append_bytes(out, output.script_pubkey)


def legacy_sighash_preimage(
    ref tx: Transaction, input_index: Int, ref script_code: List[UInt8], sighash_type: UInt8
) raises -> List[UInt8]:
    if Int(sighash_type) != 1:
        raise Error("diagnostic legacy sighash supports SIGHASH_ALL only")
    if input_index < 0 or input_index >= len(tx.inputs):
        raise Error("input index out of range")

    var out = List[UInt8]()
    append_i32_le(out, tx.version)
    append_varint(out, len(tx.inputs))
    for i in range(len(tx.inputs)):
        append_bytes(out, tx.inputs[i].previous_hash)
        append_u32_le(out, tx.inputs[i].previous_index)
        if i == input_index:
            append_varint(out, len(script_code))
            append_bytes(out, script_code)
        else:
            append_varint(out, 0)
        append_u32_le(out, tx.inputs[i].sequence)
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


def legacy_sighash(
    ref tx: Transaction, input_index: Int, ref script_code: List[UInt8], ref signature: List[UInt8]
) raises -> List[UInt8]:
    if len(signature) == 0:
        raise Error("empty ECDSA signature")
    var sighash_type = signature[len(signature) - 1]
    var trimmed = legacy_find_and_delete(script_code, signature)
    var preimage = legacy_sighash_preimage(tx, input_index, trimmed, sighash_type)
    return double_sha256(preimage)


def verify_ecdsa_signature(
    shim_path: String,
    ref signature: List[UInt8],
    ref pubkey: List[UInt8],
    ref tx: Transaction,
    input_index: Int,
    ref script_code: List[UInt8],
) raises -> Bool:
    if len(signature) == 0:
        return False
    if signature[len(signature) - 1] != UInt8(1):
        raise Error("diagnostic fixture only supports SIGHASH_ALL")
    var der = slice_bytes(signature, 0, len(signature) - 1)
    var digest = legacy_sighash(tx, input_index, script_code, signature)
    var native = OwnedDLHandle(shim_path)
    var pubkey_hex = bytes_to_hex(pubkey)
    var der_hex = bytes_to_hex(der)
    var digest_hex = bytes_to_hex(digest)
    var result = native.call["mojobitnode_verify_ecdsa_der_hex_len", Int32](
        pubkey_hex.unsafe_ptr(),
        Int32(pubkey_hex.byte_length()),
        der_hex.unsafe_ptr(),
        Int32(der_hex.byte_length()),
        digest_hex.unsafe_ptr(),
        Int32(digest_hex.byte_length()),
    )
    if result == 0:
        return True
    if result == 1:
        return False
    raise Error("malformed ECDSA signature or pubkey")


def evaluate_bare_multisig_fixture(ref fixture: ScriptFixture, shim_path: String) raises -> Bool:
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
        var ok = verify_ecdsa_signature(
            shim_path,
            stack[sig_index].data,
            parsed.pubkeys[key_index].data,
            fixture.tx,
            fixture.input_index,
            fixture.spent_script_pubkey,
        )
        if ok:
            sig_offset += 1
            remaining_sigs -= 1
        key_offset += 1
        remaining_keys -= 1
    return True
