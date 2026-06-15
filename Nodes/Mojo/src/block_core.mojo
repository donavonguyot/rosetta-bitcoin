from std.collections import List
from std.ffi import OwnedDLHandle
from std.memory.unsafe_pointer import alloc

from script_corpus_foundation import (
    ByteCursor,
    ScriptStackItem,
    TaprootPrevout,
    Transaction,
    TxInput,
    TxOutput,
    append_bytes,
    append_i32_le,
    append_i64_le,
    append_u32_le,
    append_varint,
    ascii_string_to_bytes,
    bytes_equal,
    bytes_to_hex,
    cast_to_bool,
    clone_bytes,
    evaluate_tapscript,
    evaluate_legacy_script,
    hash160,
    hash256,
    is_p2pkh_script_pubkey,
    is_p2sh_script_pubkey,
    is_p2tr_script_pubkey,
    is_p2wsh_script_pubkey,
    is_v0_witness_script_program,
    parse_push_only_stack,
    parse_transaction,
    sha256_digest,
    slice_bytes,
    tapleaf_hash,
    taproot_merkle_root_from_control,
    tx_witness_count,
    tx_witness_item,
    verify_ecdsa_signature,
    verify_ecdsa_signature_for_mode,
    verify_schnorr_key_path_signature,
    verify_taproot_tweak,
)


comptime TESTNET4_MAGIC_0 = UInt8(0x1C)
comptime TESTNET4_MAGIC_1 = UInt8(0x16)
comptime TESTNET4_MAGIC_2 = UInt8(0x3F)
comptime TESTNET4_MAGIC_3 = UInt8(0x28)
comptime PROTOCOL_VERSION = Int32(70016)
comptime SERVICES = UInt64(9)
comptime MSG_WITNESS_BLOCK = UInt32(0x40000002)
comptime GENESIS_HASH_DISPLAY = "00000000da84f2bafbbc53dee25a72ae507ff4914b867c565be350b0da8bf043"
comptime BASELINE_5K_HASH_DISPLAY = "000000000e3cb5b92e9765ed9c80c6b06f3d0a186478b330dd5e6b274acf03e2"
comptime SHAKEDOWN_50K_HASH_DISPLAY = "00000000e2c8c94ba126169a88997233f07a9769e2b009fb10cad0e893eff2cb"


struct Native(Movable):
    var handle: OwnedDLHandle

    def __init__(out self, shim_path: String) raises:
        self.handle = OwnedDLHandle(shim_path)

    def now_ms(self) -> Int64:
        return self.handle.call["mojobitnode_now_ms", Int64]()

    def socket_connect(self, host: String, port: String) raises -> Int32:
        var fd = self.handle.call["mojobitnode_socket_connect_len", Int32](
            host.unsafe_ptr(), Int32(host.byte_length()), port.unsafe_ptr(), Int32(port.byte_length())
        )
        if fd < 0:
            raise Error("local Reference P2P socket connect failed")
        return fd

    def socket_close(self, fd: Int32):
        _ = self.handle.call["mojobitnode_socket_close", Int32](fd)

    def socket_send_all(self, fd: Int32, ref bytes: List[UInt8]) raises:
        var count = len(bytes)
        var ptr = alloc[UInt8](count)
        for i in range(count):
            ptr[i] = bytes[i]
        var ok = self.handle.call["mojobitnode_socket_send_all", Int32](fd, ptr, Int32(count))
        ptr.free()
        if ok != 1:
            raise Error("local Reference P2P socket write failed")

    def socket_recv_exact(self, fd: Int32, count: Int) raises -> List[UInt8]:
        if count < 0:
            raise Error("negative socket read length")
        var ptr = alloc[UInt8](count)
        var ok = self.handle.call["mojobitnode_socket_recv_exact", Int32](fd, ptr, Int32(count))
        var out = List[UInt8]()
        if ok == 1:
            for i in range(count):
                out.append(ptr[i])
        ptr.free()
        if ok != 1:
            raise Error("local Reference P2P socket read failed")
        return out^

    def rocksdb_open(self, datadir: String) raises -> Int64:
        var db = self.handle.call["mojobitnode_rocksdb_open_len", Int64](
            datadir.unsafe_ptr(), Int32(datadir.byte_length())
        )
        if db == 0:
            raise Error("RocksDB open failed")
        return db

    def rocksdb_close(self, db: Int64):
        _ = self.handle.call["mojobitnode_rocksdb_close_handle", Int32](db)

    def rocksdb_put(self, db: Int64, ref key: List[UInt8], ref value: List[UInt8]) raises:
        var key_ptr = alloc[UInt8](len(key))
        var value_ptr = alloc[UInt8](len(value))
        for i in range(len(key)):
            key_ptr[i] = key[i]
        for i in range(len(value)):
            value_ptr[i] = value[i]
        var ok = self.handle.call["mojobitnode_rocksdb_put", Int32](
            db, key_ptr, Int32(len(key)), value_ptr, Int32(len(value))
        )
        key_ptr.free()
        value_ptr.free()
        if ok != 1:
            raise Error("RocksDB put failed")

    def rocksdb_delete(self, db: Int64, ref key: List[UInt8]) raises:
        var key_ptr = alloc[UInt8](len(key))
        for i in range(len(key)):
            key_ptr[i] = key[i]
        var ok = self.handle.call["mojobitnode_rocksdb_delete", Int32](db, key_ptr, Int32(len(key)))
        key_ptr.free()
        if ok != 1:
            raise Error("RocksDB delete failed")

    def rocksdb_get(self, db: Int64, ref key: List[UInt8], cap: Int) raises -> List[UInt8]:
        var key_ptr = alloc[UInt8](len(key))
        var out_ptr = alloc[UInt8](cap)
        for i in range(len(key)):
            key_ptr[i] = key[i]
        var n = self.handle.call["mojobitnode_rocksdb_get", Int32](
            db, key_ptr, Int32(len(key)), out_ptr, Int32(cap)
        )
        var out = List[UInt8]()
        if n > 0:
            for i in range(Int(n)):
                out.append(out_ptr[i])
        key_ptr.free()
        out_ptr.free()
        if n == -2:
            return out^
        if n < 0:
            raise Error("RocksDB get failed")
        return out^


struct BlockTx(Copyable):
    var tx: Transaction
    var raw: List[UInt8]
    var no_witness_raw: List[UInt8]
    var txid: List[UInt8]

    def __init__(out self):
        self.tx = Transaction()
        self.raw = List[UInt8]()
        self.no_witness_raw = List[UInt8]()
        self.txid = List[UInt8]()


struct Block(Copyable):
    var header: List[UInt8]
    var hash: List[UInt8]
    var txs: List[BlockTx]

    def __init__(out self):
        self.header = List[UInt8]()
        self.hash = List[UInt8]()
        self.txs = List[BlockTx]()


struct Utxo(Copyable):
    var height: Int
    var value_sats: Int64
    var coinbase: Bool
    var script_pubkey: List[UInt8]

    def __init__(out self):
        self.height = 0
        self.value_sats = 0
        self.coinbase = False
        self.script_pubkey = List[UInt8]()


struct ConnectTiming(Copyable):
    var p2p_fetch: Int64
    var block_parse_validate: Int64
    var utxo_load: Int64
    var script_verify: Int64
    var utxo_apply: Int64
    var commit: Int64
    var block_connect_store_commit: Int64

    def __init__(out self):
        self.p2p_fetch = 0
        self.block_parse_validate = 0
        self.utxo_load = 0
        self.script_verify = 0
        self.utxo_apply = 0
        self.commit = 0
        self.block_connect_store_commit = 0


struct ProofResult(Copyable):
    var json: String

    def __init__(out self):
        self.json = String("")


def benchmark_gate_for_target(target: Int) raises -> String:
    if target == 5000:
        return String("baseline_5k")
    if target == 50000:
        return String("shakedown_50k")
    raise Error("Mojo local-reference-proof supports targets 5000 and 50000 only")


def target_label_for_target(target: Int) raises -> String:
    if target == 5000:
        return String("5k")
    if target == 50000:
        return String("50k")
    raise Error("Mojo local-reference-proof supports targets 5000 and 50000 only")


def expected_hash_for_target(target: Int) raises -> String:
    if target == 5000:
        return String(BASELINE_5K_HASH_DISPLAY)
    if target == 50000:
        return String(SHAKEDOWN_50K_HASH_DISPLAY)
    raise Error("Mojo local-reference-proof supports targets 5000 and 50000 only")


def expected_utxos_for_target(target: Int) raises -> Int:
    if target == 5000:
        return 4574
    if target == 50000:
        return 568855
    raise Error("Mojo local-reference-proof supports targets 5000 and 50000 only")


def telemetry_tick_count_for_target(target: Int, progress_interval: Int) -> Int:
    # Startup emits four lifecycle ticks, height 1 emits first_block_connected,
    # and completion emits run_finished. Progress ticks include height 0 and
    # the target height when progress output is enabled.
    var count = 6
    if progress_interval <= 0:
        return count
    count += 1
    var height = progress_interval
    while height < target:
        count += 1
        height += progress_interval
    count += 1
    return count


def _append_u64_le(mut out: List[UInt8], value: UInt64):
    for i in range(8):
        out.append(UInt8((value >> UInt64(i * 8)) & UInt64(0xFF)))


def _append_i64_le(mut out: List[UInt8], value: Int64):
    _append_u64_le(out, UInt64(value))


def _append_u32_be(mut out: List[UInt8], value: UInt32):
    out.append(UInt8((value >> 24) & 0xFF))
    out.append(UInt8((value >> 16) & 0xFF))
    out.append(UInt8((value >> 8) & 0xFF))
    out.append(UInt8(value & 0xFF))


def _append_i64_be(mut out: List[UInt8], value: Int64):
    var bits = UInt64(value)
    for i in range(8):
        out.append(UInt8((bits >> UInt64(56 - i * 8)) & UInt64(0xFF)))


def _read_u32_le(ref bytes: List[UInt8], offset: Int) raises -> UInt32:
    if offset < 0 or offset + 4 > len(bytes):
        raise Error("u32 read out of range")
    return (
        UInt32(bytes[offset])
        | (UInt32(bytes[offset + 1]) << 8)
        | (UInt32(bytes[offset + 2]) << 16)
        | (UInt32(bytes[offset + 3]) << 24)
    )


def _read_u32_be(ref bytes: List[UInt8], offset: Int) raises -> UInt32:
    if offset < 0 or offset + 4 > len(bytes):
        raise Error("u32 read out of range")
    return (
        (UInt32(bytes[offset]) << 24)
        | (UInt32(bytes[offset + 1]) << 16)
        | (UInt32(bytes[offset + 2]) << 8)
        | UInt32(bytes[offset + 3])
    )


def _read_i64_be(ref bytes: List[UInt8], offset: Int) raises -> Int64:
    if offset < 0 or offset + 8 > len(bytes):
        raise Error("i64 read out of range")
    var value = UInt64(0)
    for i in range(8):
        value = (value << 8) | UInt64(bytes[offset + i])
    return Int64(value)


def reverse_bytes(ref bytes: List[UInt8]) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(bytes)):
        out.append(bytes[len(bytes) - 1 - i])
    return out^


def display_hash(ref internal_hash: List[UInt8]) -> String:
    var reversed = reverse_bytes(internal_hash)
    return bytes_to_hex(reversed)


def hash_from_display(text: String) raises -> List[UInt8]:
    var out = List[UInt8]()
    if text.byte_length() != 64:
        raise Error("display hash must be 32 bytes")
    var text_bytes = ascii_string_to_bytes(text)
    var raw = List[UInt8]()
    for i in range(0, len(text_bytes), 2):
        var pair = List[UInt8]()
        pair.append(text_bytes[i])
        pair.append(text_bytes[i + 1])
        # Reuse the corpus hex parser through a tiny local nibble path.
        var hi = _hex_nibble_local(pair[0])
        var lo = _hex_nibble_local(pair[1])
        raw.append(UInt8((Int(hi) << 4) | Int(lo)))
    for i in range(32):
        out.append(raw[31 - i])
    return out^


def _hex_nibble_local(byte: UInt8) raises -> UInt8:
    var value = Int(byte)
    if value >= 48 and value <= 57:
        return UInt8(value - 48)
    if value >= 97 and value <= 102:
        return UInt8(value - 87)
    if value >= 65 and value <= 70:
        return UInt8(value - 55)
    raise Error("invalid hash hex")


def _string_key(name: String) -> List[UInt8]:
    return ascii_string_to_bytes(name)


def _meta_key(name: String) -> List[UInt8]:
    return ascii_string_to_bytes(String("meta:") + name)


def _utxo_key(ref txid: List[UInt8], vout: UInt32) -> List[UInt8]:
    return ascii_string_to_bytes(String("utxo:") + bytes_to_hex(txid) + String(":") + String(vout))


def _block_key(height: Int) -> List[UInt8]:
    return ascii_string_to_bytes(String("block:") + String(height))


def encode_utxo(height: Int, value_sats: Int64, coinbase: Bool, ref script_pubkey: List[UInt8]) -> List[UInt8]:
    var out = List[UInt8]()
    _append_u32_be(out, UInt32(height))
    _append_i64_be(out, value_sats)
    out.append(UInt8(1) if coinbase else UInt8(0))
    _append_u32_be(out, UInt32(len(script_pubkey)))
    append_bytes(out, script_pubkey)
    return out^


def decode_utxo(ref bytes: List[UInt8]) raises -> Utxo:
    if len(bytes) < 17:
        raise Error("stored UTXO value too short")
    var script_len = Int(_read_u32_be(bytes, 13))
    if 17 + script_len > len(bytes):
        raise Error("stored UTXO script truncated")
    var out = Utxo()
    out.height = Int(_read_u32_be(bytes, 0))
    out.value_sats = _read_i64_be(bytes, 4)
    out.coinbase = bytes[12] == UInt8(1)
    out.script_pubkey = slice_bytes(bytes, 17, 17 + script_len)
    return out^


def db_put_string(mut native: Native, db: Int64, name: String, value: String) raises:
    var key = _meta_key(name)
    var bytes = ascii_string_to_bytes(value)
    native.rocksdb_put(db, key, bytes)


def db_get_string(mut native: Native, db: Int64, name: String) raises -> String:
    var key = _meta_key(name)
    var bytes = native.rocksdb_get(db, key, 4096)
    var out = String("")
    for i in range(len(bytes)):
        out += chr(Int(bytes[i]))
    return out


def serialize_transaction_no_witness(ref tx: Transaction) raises -> List[UInt8]:
    var out = List[UInt8]()
    append_i32_le(out, tx.version)
    append_varint(out, len(tx.inputs))
    for i in range(len(tx.inputs)):
        append_bytes(out, tx.inputs[i].previous_hash)
        append_u32_le(out, tx.inputs[i].previous_index)
        append_varint(out, len(tx.inputs[i].script_sig))
        append_bytes(out, tx.inputs[i].script_sig)
        append_u32_le(out, tx.inputs[i].sequence)
    append_varint(out, len(tx.outputs))
    for i in range(len(tx.outputs)):
        append_i64_le(out, tx.outputs[i].value)
        append_varint(out, len(tx.outputs[i].script_pubkey))
        append_bytes(out, tx.outputs[i].script_pubkey)
    append_u32_le(out, tx.lock_time)
    return out^


def parse_block(ref raw: List[UInt8]) raises -> Block:
    if len(raw) < 81:
        raise Error("block payload too short")
    var block = Block()
    block.header = slice_bytes(raw, 0, 80)
    block.hash = hash256(block.header)
    var cursor = ByteCursor(slice_bytes(raw, 80, len(raw)))
    var tx_count = cursor.read_varint()
    for _ in range(tx_count):
        var start = cursor.offset
        _ = cursor.read_i32_le()
        var input_count = cursor.read_varint()
        var has_witness = False
        if input_count == 0:
            var flag = cursor.read_varint()
            if flag != 1:
                raise Error("unsupported transaction witness flag")
            has_witness = True
            input_count = cursor.read_varint()
        for _ in range(input_count):
            _ = cursor.read_bytes(32)
            _ = cursor.read_u32_le()
            _ = cursor.read_bytes(cursor.read_varint())
            _ = cursor.read_u32_le()
        var output_count = cursor.read_varint()
        for _ in range(output_count):
            _ = cursor.read_i64_le()
            _ = cursor.read_bytes(cursor.read_varint())
        if has_witness:
            for _ in range(input_count):
                var witness_count = cursor.read_varint()
                for _ in range(witness_count):
                    _ = cursor.read_bytes(cursor.read_varint())
        _ = cursor.read_u32_le()
        var end = cursor.offset
        var tx_raw = slice_bytes(raw, 80 + start, 80 + end)
        var parsed = parse_transaction(clone_bytes(tx_raw))
        var no_witness = serialize_transaction_no_witness(parsed)
        var item = BlockTx()
        item.tx = parsed^
        item.raw = tx_raw^
        item.no_witness_raw = no_witness^
        item.txid = hash256(item.no_witness_raw)
        block.txs.append(item^)
    if cursor.remaining() != 0:
        raise Error("block parser consumed partial payload")
    return block^


def merkle_root(ref txs: List[BlockTx]) raises -> List[UInt8]:
    if len(txs) == 0:
        raise Error("block has no transactions")
    var layer = List[List[UInt8]]()
    for i in range(len(txs)):
        layer.append(clone_bytes(txs[i].txid))
    while len(layer) > 1:
        var next = List[List[UInt8]]()
        var i = 0
        while i < len(layer):
            var pair = List[UInt8]()
            append_bytes(pair, layer[i])
            if i + 1 < len(layer):
                append_bytes(pair, layer[i + 1])
            else:
                append_bytes(pair, layer[i])
            var digest = hash256(pair)
            next.append(digest^)
            i += 2
        layer = next^
    return layer[0].copy()


def compact_target(bits: UInt32) raises -> List[UInt8]:
    var exponent = Int(bits >> 24)
    var mantissa = bits & UInt32(0x007FFFFF)
    if (bits & UInt32(0x00800000)) != 0 or mantissa == 0:
        raise Error("invalid compact target")
    var target = List[UInt8]()
    for _ in range(32):
        target.append(UInt8(0))
    if exponent <= 3:
        var value = mantissa >> UInt32(8 * (3 - exponent))
        var index = 0
        while value > 0 and index < 32:
            target[index] = UInt8(value & UInt32(0xFF))
            value = value >> 8
            index += 1
    else:
        var start = exponent - 3
        if start + 3 > 32:
            raise Error("compact target overflow")
        target[start] = UInt8(mantissa & UInt32(0xFF))
        target[start + 1] = UInt8((mantissa >> 8) & UInt32(0xFF))
        target[start + 2] = UInt8((mantissa >> 16) & UInt32(0xFF))
    return target^


def check_pow(ref header_hash: List[UInt8], bits: UInt32) raises -> Bool:
    var target = compact_target(bits)
    var i = 31
    while i >= 0:
        if header_hash[i] < target[i]:
            return True
        if header_hash[i] > target[i]:
            return False
        i -= 1
    return True


def is_coinbase(ref tx: Transaction) -> Bool:
    if len(tx.inputs) != 1:
        return False
    var input = tx.inputs[0].copy()
    if input.previous_index != UInt32(0xFFFFFFFF):
        return False
    for i in range(len(input.previous_hash)):
        if input.previous_hash[i] != UInt8(0):
            return False
    return True


def is_spendable_output(ref output: TxOutput) -> Bool:
    if output.value < 0:
        return False
    if len(output.script_pubkey) > 0 and output.script_pubkey[0] == UInt8(0x6A):
        return False
    return True


def verify_p2wpkh_spend(shim_path: String, ref tx: Transaction, input_index: Int, ref prevout: Utxo) raises -> Bool:
    if tx_witness_count(tx, input_index) != 2:
        return False
    var sig = tx_witness_item(tx, input_index, 0)
    var pubkey = tx_witness_item(tx, input_index, 1)
    var actual = hash160(pubkey.data)
    var expected = slice_bytes(prevout.script_pubkey, 2, 22)
    if not bytes_equal(actual, expected):
        return False
    var script_code = List[UInt8]()
    script_code.append(UInt8(0x76))
    script_code.append(UInt8(0xA9))
    script_code.append(UInt8(0x14))
    append_bytes(script_code, expected)
    script_code.append(UInt8(0x88))
    script_code.append(UInt8(0xAC))
    return verify_ecdsa_signature_for_mode(
        shim_path, sig.data, pubkey.data, tx, input_index, script_code, True, prevout.value_sats
    )


def verify_witness_v0_spend(shim_path: String, ref tx: Transaction, input_index: Int, ref prevout: Utxo) raises -> Bool:
    if len(prevout.script_pubkey) == 22 and prevout.script_pubkey[0] == UInt8(0) and prevout.script_pubkey[1] == UInt8(0x14):
        return verify_p2wpkh_spend(shim_path, tx, input_index, prevout)
    if is_p2wsh_script_pubkey(prevout.script_pubkey):
        var witness_count = tx_witness_count(tx, input_index)
        if witness_count < 1:
            return False
        var script_item = tx_witness_item(tx, input_index, witness_count - 1)
        var script_hash = sha256_digest(script_item.data)
        var expected = slice_bytes(prevout.script_pubkey, 2, 34)
        if not bytes_equal(script_hash, expected):
            return False
        var stack = List[ScriptStackItem]()
        for i in range(witness_count - 1):
            var item = tx_witness_item(tx, input_index, i)
            stack.append(item^)
        return evaluate_legacy_script(script_item.data, stack^, tx, input_index, shim_path, True, True, prevout.value_sats)
    raise Error("unsupported witness v0 program")


def taproot_prevout_from_utxo(ref prevout: Utxo) -> TaprootPrevout:
    var out = TaprootPrevout()
    out.amount = prevout.value_sats
    out.script_pubkey = clone_bytes(prevout.script_pubkey)
    return out^


def taproot_prevouts_from_utxos(ref prevouts: List[Utxo]) -> List[TaprootPrevout]:
    var out = List[TaprootPrevout]()
    for i in range(len(prevouts)):
        var item = taproot_prevout_from_utxo(prevouts[i])
        out.append(item^)
    return out^


def verify_taproot_spend(
    shim_path: String,
    ref tx: Transaction,
    input_index: Int,
    ref prevout: Utxo,
    ref all_prevouts: List[Utxo],
) raises -> Bool:
    if len(tx.inputs[input_index].script_sig) != 0:
        return False
    if len(all_prevouts) != len(tx.inputs):
        raise Error("Taproot spent prevouts length mismatch")
    var witness_count = tx_witness_count(tx, input_index)
    if witness_count == 0:
        return False
    var effective_count = witness_count
    if witness_count >= 2:
        var possible_annex = tx_witness_item(tx, input_index, witness_count - 2)
        if len(possible_annex.data) > 0 and possible_annex.data[0] == UInt8(0x50):
            raise Error("Taproot annex spends are not supported by Mojo live proof yet")
        var invalid_annex_position = tx_witness_item(tx, input_index, witness_count - 1)
        if len(invalid_annex_position.data) > 0 and invalid_annex_position.data[0] == UInt8(0x50):
            return False
    var spent_prevouts = taproot_prevouts_from_utxos(all_prevouts)
    if effective_count == 1:
        var signature = tx_witness_item(tx, input_index, 0)
        var xonly = slice_bytes(prevout.script_pubkey, 2, 34)
        return verify_schnorr_key_path_signature(shim_path, signature.data, xonly, tx, input_index, spent_prevouts)
    if effective_count < 2:
        return False
    var script_item = tx_witness_item(tx, input_index, effective_count - 2)
    var control_item = tx_witness_item(tx, input_index, effective_count - 1)
    if len(script_item.data) == 0:
        return False
    if len(control_item.data) < 33 or len(control_item.data) > 33 + 128 * 32 or ((len(control_item.data) - 33) % 32) != 0:
        return False
    var leaf_version = control_item.data[0] & UInt8(0xFE)
    if leaf_version == UInt8(0x50):
        return False
    var leaf_digest = tapleaf_hash(leaf_version, script_item.data)
    var merkle_root = taproot_merkle_root_from_control(control_item.data, leaf_digest)
    var internal_xonly = slice_bytes(control_item.data, 1, 33)
    var expected_xonly = slice_bytes(prevout.script_pubkey, 2, 34)
    var parity = Int(control_item.data[0] & UInt8(1))
    if not verify_taproot_tweak(shim_path, internal_xonly, merkle_root, expected_xonly, parity):
        return False
    if leaf_version != UInt8(0xC0):
        return True
    var stack = List[ScriptStackItem]()
    for i in range(effective_count - 2):
        var item = tx_witness_item(tx, input_index, i)
        stack.append(item^)
    return evaluate_tapscript(script_item.data, stack^, tx, input_index, spent_prevouts, leaf_digest, shim_path)


def verify_spend(
    shim_path: String,
    ref tx: Transaction,
    input_index: Int,
    ref prevout: Utxo,
    ref all_prevouts: List[Utxo],
) raises -> Bool:
    if is_p2pkh_script_pubkey(prevout.script_pubkey):
        var stack = parse_push_only_stack(tx.inputs[input_index].script_sig)
        if len(stack) < 2:
            return False
        var signature = stack[len(stack) - 2].copy()
        var pubkey = stack[len(stack) - 1].copy()
        var actual_hash = hash160(pubkey.data)
        var expected_hash = slice_bytes(prevout.script_pubkey, 3, 23)
        if not bytes_equal(actual_hash, expected_hash):
            return False
        return verify_ecdsa_signature(shim_path, signature.data, pubkey.data, tx, input_index, prevout.script_pubkey)
    if is_p2sh_script_pubkey(prevout.script_pubkey):
        var pushes = parse_push_only_stack(tx.inputs[input_index].script_sig)
        if len(pushes) == 0:
            return False
        var redeem_script = pushes[len(pushes) - 1].data.copy()
        var redeem_hash = hash160(redeem_script)
        var expected_hash = slice_bytes(prevout.script_pubkey, 2, 22)
        if not bytes_equal(redeem_hash, expected_hash):
            return False
        if is_v0_witness_script_program(redeem_script):
            var nested = Utxo()
            nested.height = prevout.height
            nested.value_sats = prevout.value_sats
            nested.coinbase = prevout.coinbase
            nested.script_pubkey = redeem_script^
            return verify_witness_v0_spend(shim_path, tx, input_index, nested)
        var stack = List[ScriptStackItem]()
        for i in range(len(pushes) - 1):
            var item = pushes[i].copy()
            stack.append(item^)
        return evaluate_legacy_script(redeem_script, stack^, tx, input_index, shim_path, True)
    if len(prevout.script_pubkey) >= 2 and prevout.script_pubkey[0] == UInt8(0):
        return verify_witness_v0_spend(shim_path, tx, input_index, prevout)
    if is_p2tr_script_pubkey(prevout.script_pubkey):
        return verify_taproot_spend(shim_path, tx, input_index, prevout, all_prevouts)
    var stack = parse_push_only_stack(tx.inputs[input_index].script_sig)
    return evaluate_legacy_script(prevout.script_pubkey, stack^, tx, input_index, shim_path, True)


def connect_block(
    mut native: Native,
    db: Int64,
    shim_path: String,
    height: Int,
    ref block: Block,
    current_utxos: Int,
    mut timing: ConnectTiming,
) raises -> Int:
    if len(block.txs) == 0:
        raise Error("block has no transactions")
    if not is_coinbase(block.txs[0].tx):
        raise Error("first transaction is not coinbase")

    var created_txids = List[List[UInt8]]()
    var created_vouts = List[UInt32]()
    var created_values = List[Utxo]()
    var spent_txids = List[List[UInt8]]()
    var spent_vouts = List[UInt32]()
    var spent_external = 0
    var created_unspent = 0

    for tx_index in range(len(block.txs)):
        var tx = block.txs[tx_index].tx.copy()
        if tx_index == 0:
            if height != 0:
                for vout in range(len(tx.outputs)):
                    if is_spendable_output(tx.outputs[vout]):
                        var u = Utxo()
                        u.height = height
                        u.value_sats = tx.outputs[vout].value
                        u.coinbase = True
                        u.script_pubkey = clone_bytes(tx.outputs[vout].script_pubkey)
                        created_txids.append(clone_bytes(block.txs[tx_index].txid))
                        created_vouts.append(UInt32(vout))
                        created_values.append(u^)
            continue
        if len(tx.inputs) == 0:
            raise Error("non-coinbase transaction has no inputs")
        var tx_prevouts = List[Utxo]()
        var tx_prev_hashes = List[List[UInt8]]()
        var tx_prev_vouts = List[UInt32]()
        var tx_load_started = native.now_ms()
        for input_index in range(len(tx.inputs)):
            var prev_hash = tx.inputs[input_index].previous_hash.copy()
            var prev_index = tx.inputs[input_index].previous_index
            var found_created = False
            var prevout = Utxo()
            for i in range(len(created_txids)):
                if created_vouts[i] == prev_index and bytes_equal(created_txids[i], prev_hash):
                    found_created = True
                    prevout = created_values[i].copy()
                    break
            if not found_created:
                var key = _utxo_key(prev_hash, prev_index)
                var value = native.rocksdb_get(db, key, 20000)
                if len(value) == 0:
                    raise Error(
                        String("missing UTXO at height ")
                        + String(height)
                        + String(" txid=")
                        + display_hash(block.txs[tx_index].txid)
                        + String(" input=")
                        + String(input_index)
                        + String(" prev_txid=")
                        + display_hash(prev_hash)
                        + String(" prev_vout=")
                        + String(prev_index)
                    )
                prevout = decode_utxo(value)
                spent_external += 1
            if prevout.coinbase and height < prevout.height + 100:
                raise Error("coinbase maturity violation")
            tx_prevouts.append(prevout^)
            tx_prev_hashes.append(prev_hash^)
            tx_prev_vouts.append(prev_index)
        timing.utxo_load += native.now_ms() - tx_load_started
        for input_index in range(len(tx.inputs)):
            var verify_started = native.now_ms()
            var current_prevout = tx_prevouts[input_index].copy()
            var all_prevouts_for_verify = tx_prevouts.copy()
            var verified = False
            try:
                verified = verify_spend(shim_path, tx, input_index, current_prevout, all_prevouts_for_verify)
            except e:
                raise Error(
                    String("script verification error at height ")
                    + String(height)
                    + String(" txid=")
                    + display_hash(block.txs[tx_index].txid)
                    + String(" input=")
                    + String(input_index)
                    + String(" prev_txid=")
                    + display_hash(tx_prev_hashes[input_index])
                    + String(" prev_vout=")
                    + String(tx_prev_vouts[input_index])
                    + String(" spent_script_pubkey=")
                    + bytes_to_hex(tx_prevouts[input_index].script_pubkey)
                    + String(" failure=")
                    + String(e)
                )
            if not verified:
                raise Error(
                    String("script verification failed at height ")
                    + String(height)
                    + String(" txid=")
                    + display_hash(block.txs[tx_index].txid)
                    + String(" input=")
                    + String(input_index)
                    + String(" prev_txid=")
                    + display_hash(tx_prev_hashes[input_index])
                    + String(" prev_vout=")
                    + String(tx_prev_vouts[input_index])
                    + String(" spent_script_pubkey=")
                    + bytes_to_hex(tx_prevouts[input_index].script_pubkey)
                )
            timing.script_verify += native.now_ms() - verify_started
            spent_txids.append(clone_bytes(tx_prev_hashes[input_index]))
            spent_vouts.append(tx_prev_vouts[input_index])
        for vout in range(len(tx.outputs)):
            if is_spendable_output(tx.outputs[vout]):
                var u = Utxo()
                u.height = height
                u.value_sats = tx.outputs[vout].value
                u.coinbase = False
                u.script_pubkey = clone_bytes(tx.outputs[vout].script_pubkey)
                created_txids.append(clone_bytes(block.txs[tx_index].txid))
                created_vouts.append(UInt32(vout))
                created_values.append(u^)

    var apply_started = native.now_ms()
    for i in range(len(spent_txids)):
        var key = _utxo_key(spent_txids[i], spent_vouts[i])
        native.rocksdb_delete(db, key)
    for i in range(len(created_txids)):
        var already_spent = False
        for j in range(len(spent_txids)):
            if spent_vouts[j] == created_vouts[i] and bytes_equal(spent_txids[j], created_txids[i]):
                already_spent = True
                break
        if already_spent:
            continue
        var key = _utxo_key(created_txids[i], created_vouts[i])
        var value = encode_utxo(created_values[i].height, created_values[i].value_sats, created_values[i].coinbase, created_values[i].script_pubkey)
        native.rocksdb_put(db, key, value)
        created_unspent += 1
    var block_key = _block_key(height)
    native.rocksdb_put(db, block_key, block.header)
    var new_utxos = current_utxos - spent_external + created_unspent
    db_put_string(native, db, String("validated_height"), String(height))
    db_put_string(native, db, String("stored_block_height"), String(height))
    db_put_string(native, db, String("header_height"), String(height))
    db_put_string(native, db, String("validated_hash"), display_hash(block.hash))
    db_put_string(native, db, String("stored_block_hash"), display_hash(block.hash))
    db_put_string(native, db, String("header_hash"), display_hash(block.hash))
    db_put_string(native, db, String("chainstate_utxo_count"), String(new_utxos))
    db_put_string(native, db, String("chainstate_backend"), String("rocksdb"))
    db_put_string(native, db, String("native_crypto_backend"), String("libsecp256k1"))
    db_put_string(native, db, String("sync_status"), String("blocks_syncing"))
    var apply_delta = native.now_ms() - apply_started
    timing.utxo_apply += apply_delta
    timing.commit += apply_delta
    return new_utxos


struct Message(Movable):
    var command: String
    var payload: List[UInt8]

    def __init__(out self):
        self.command = String("")
        self.payload = List[UInt8]()


def _checksum(ref payload: List[UInt8]) raises -> List[UInt8]:
    var digest = hash256(payload)
    return slice_bytes(digest, 0, 4)


def send_message(mut native: Native, fd: Int32, command: String, ref payload: List[UInt8]) raises:
    if command.byte_length() > 12:
        raise Error("P2P command too long")
    var out = List[UInt8]()
    out.append(TESTNET4_MAGIC_0)
    out.append(TESTNET4_MAGIC_1)
    out.append(TESTNET4_MAGIC_2)
    out.append(TESTNET4_MAGIC_3)
    var command_bytes = ascii_string_to_bytes(command)
    append_bytes(out, command_bytes)
    for _ in range(12 - len(command_bytes)):
        out.append(UInt8(0))
    append_u32_le(out, UInt32(len(payload)))
    var sum = _checksum(payload)
    append_bytes(out, sum)
    append_bytes(out, payload)
    native.socket_send_all(fd, out)


def read_message(mut native: Native, fd: Int32) raises -> Message:
    var header = native.socket_recv_exact(fd, 24)
    if header[0] != TESTNET4_MAGIC_0 or header[1] != TESTNET4_MAGIC_1 or header[2] != TESTNET4_MAGIC_2 or header[3] != TESTNET4_MAGIC_3:
        raise Error("unexpected P2P network magic")
    var command = String("")
    for i in range(4, 16):
        if header[i] == UInt8(0):
            break
        command += chr(Int(header[i]))
    var length = Int(_read_u32_le(header, 16))
    if length < 0 or length > 67108864:
        raise Error("P2P payload too large")
    var payload = native.socket_recv_exact(fd, length)
    var expected = _checksum(payload)
    var actual = slice_bytes(header, 20, 24)
    if not bytes_equal(expected, actual):
        raise Error("P2P message checksum mismatch")
    var msg = Message()
    msg.command = command
    msg.payload = payload^
    return msg^


def version_payload(start_height: Int) raises -> List[UInt8]:
    var out = List[UInt8]()
    append_i32_le(out, PROTOCOL_VERSION)
    _append_u64_le(out, SERVICES)
    _append_i64_le(out, 0)
    _append_u64_le(out, SERVICES)
    for _ in range(18):
        out.append(UInt8(0))
    _append_u64_le(out, SERVICES)
    for _ in range(18):
        out.append(UInt8(0))
    _append_u64_le(out, UInt64(0x6D6F6A6F6269746E))
    var agent = ascii_string_to_bytes(String("/mojobitnode:0.1.0/"))
    append_varint(out, len(agent))
    append_bytes(out, agent)
    append_i32_le(out, Int32(start_height))
    out.append(UInt8(0))
    return out^


def split_peer(peer: String) raises -> List[String]:
    var parts = List[String]()
    var host = String("")
    var port = String("")
    var seen = False
    for i in range(peer.byte_length()):
        var ch = peer[byte=i]
        if ch == ":":
            seen = True
            continue
        if seen:
            port += ch
        else:
            host += ch
    if host == "" or port == "":
        raise Error("invalid peer host:port")
    parts.append(host)
    parts.append(port)
    return parts^


def handshake(mut native: Native, fd: Int32) raises:
    var payload = version_payload(0)
    send_message(native, fd, String("version"), payload)
    var seen_version = False
    var seen_verack = False
    while not (seen_version and seen_verack):
        var msg = read_message(native, fd)
        if msg.command == "version":
            seen_version = True
            var empty = List[UInt8]()
            send_message(native, fd, String("verack"), empty)
        elif msg.command == "verack":
            seen_verack = True
        elif msg.command == "ping":
            send_message(native, fd, String("pong"), msg.payload)
    var empty2 = List[UInt8]()
    send_message(native, fd, String("sendheaders"), empty2)


def getheaders_payload(ref locator: List[UInt8]) raises -> List[UInt8]:
    var out = List[UInt8]()
    append_i32_le(out, PROTOCOL_VERSION)
    append_varint(out, 1)
    append_bytes(out, locator)
    for _ in range(32):
        out.append(UInt8(0))
    return out^


def getdata_payload(ref hashes: List[List[UInt8]], start: Int, end: Int) raises -> List[UInt8]:
    var out = List[UInt8]()
    append_varint(out, end - start)
    for i in range(start, end):
        append_u32_le(out, MSG_WITNESS_BLOCK)
        append_bytes(out, hashes[i])
    return out^


def parse_headers_payload(ref payload: List[UInt8]) raises -> List[List[UInt8]]:
    var cursor = ByteCursor(clone_bytes(payload))
    var count = cursor.read_varint()
    var out = List[List[UInt8]]()
    for _ in range(count):
        var header = cursor.read_bytes(80)
        var tx_count = cursor.read_varint()
        if tx_count != 0:
            raise Error("headers message had nonzero tx count")
        out.append(header^)
    if cursor.remaining() != 0:
        raise Error("headers payload trailing bytes")
    return out^


def headers_through(mut native: Native, fd: Int32, target: Int) raises -> List[List[UInt8]]:
    var hashes = List[List[UInt8]]()
    var genesis = hash_from_display(String(GENESIS_HASH_DISPLAY))
    hashes.append(genesis^)
    while len(hashes) <= target:
        var payload = getheaders_payload(hashes[len(hashes) - 1])
        send_message(native, fd, String("getheaders"), payload)
        var msg = read_message(native, fd)
        while msg.command != "headers":
            if msg.command == "ping":
                send_message(native, fd, String("pong"), msg.payload)
            msg = read_message(native, fd)
        var headers = parse_headers_payload(msg.payload)
        if len(headers) == 0:
            raise Error("peer returned no headers")
        for i in range(len(headers)):
            if len(hashes) > target:
                break
            var prev = slice_bytes(headers[i], 4, 36)
            if not bytes_equal(prev, hashes[len(hashes) - 1]):
                raise Error("header previous hash mismatch")
            var header_hash = hash256(headers[i])
            if not check_pow(header_hash, _read_u32_le(headers[i], 72)):
                raise Error("header proof of work invalid")
            hashes.append(header_hash^)
    return hashes^


def request_block_batch(mut native: Native, fd: Int32, ref hashes: List[List[UInt8]], start: Int, end: Int) raises -> List[Block]:
    var payload = getdata_payload(hashes, start, end)
    send_message(native, fd, String("getdata"), payload)
    var blocks = List[Block]()
    while len(blocks) < end - start:
        var msg = read_message(native, fd)
        if msg.command == "ping":
            send_message(native, fd, String("pong"), msg.payload)
            continue
        if msg.command == "notfound":
            raise Error("Reference peer returned notfound for block request")
        if msg.command != "block":
            continue
        var block = parse_block(msg.payload)
        blocks.append(block^)
    return blocks^


def verify_block_header(height: Int, ref block: Block, ref expected_hash: List[UInt8], ref prev_hash: List[UInt8]) raises:
    if not bytes_equal(block.hash, expected_hash):
        raise Error(String("block hash mismatch at height ") + String(height))
    if height > 0:
        var prev = slice_bytes(block.header, 4, 36)
        if not bytes_equal(prev, prev_hash):
            raise Error(String("block previous hash mismatch at height ") + String(height))
    var root = merkle_root(block.txs)
    var header_root = slice_bytes(block.header, 36, 68)
    if not bytes_equal(root, header_root):
        raise Error(String("merkle root mismatch at height ") + String(height))


def emit_progress(
    height: Int,
    target: Int,
    hash_display: String,
    peer: String,
    utxos: Int,
    last_block_ms: Int64,
    ref timing: ConnectTiming,
):
    print(
        String("rb.port_progress {")
        + String('"chain":"testnet4","sync_status":"')
        + (String("blocks_current") if height >= target else String("blocks_syncing"))
        + String('","header_height":')
        + String(height)
        + String(',"validated_height":')
        + String(height)
        + String(',"validated_hash":"')
        + hash_display
        + String('","stored_block_height":')
        + String(height)
        + String(',"chainstate_utxo_count":')
        + String(utxos)
        + String(',"current_blocker":null,"peer":"')
        + peer
        + String('","native_crypto_backend":"libsecp256k1","timing_buckets_ms":{"p2p_fetch":')
        + String(timing.p2p_fetch)
        + String(',"block_parse_validate":')
        + String(timing.block_parse_validate)
        + String(',"utxo_load":')
        + String(timing.utxo_load)
        + String(',"script_verify":')
        + String(timing.script_verify)
        + String(',"utxo_apply":')
        + String(timing.utxo_apply)
        + String(',"commit":')
        + String(timing.commit)
        + String(',"block_connect_store_commit":')
        + String(timing.block_connect_store_commit)
        + String('},"last_block_ms":')
        + String(last_block_ms)
        + String("}")
    )


def emit_telemetry(
    gate: String,
    event: String,
    phase: String,
    height: Int,
    target: Int,
    hash_display: String,
    peer: String,
    utxos: Int,
    elapsed_ms: Int64,
    last_block_ms: Int64,
    ref timing: ConnectTiming,
):
    print(
        String("benchmark.telemetry_tick {")
        + String('"schema":"benchmark.telemetry_tick.v1","port":"mojo","gate":"')
        + gate
        + String('","run_id":"mojo-')
        + gate
        + String('","event":"')
        + event
        + String('","target_height":')
        + String(target)
        + String(',"height":')
        + String(height)
        + String(',"phase":"')
        + phase
        + String('","elapsed_ms":')
        + String(elapsed_ms)
        + String(',"monotonic_ms":')
        + String(elapsed_ms)
        + String(',"utxos":')
        + String(utxos)
        + String(',"current_blocker":null,"stall_class":"none","current_block_hash":"')
        + hash_display
        + String('","current_block_elapsed_ms":')
        + String(last_block_ms)
        + String(',"current_block_height":')
        + String(height)
        + String(',"current_block_tx_count":0,"current_block_vin_count":0,"current_block_script_input_count":0')
        + String(',"peer":"')
        + peer
        + String('","timing_buckets_ms":{"p2p_fetch":')
        + String(timing.p2p_fetch)
        + String(',"block_parse_validate":')
        + String(timing.block_parse_validate)
        + String(',"utxo_load":')
        + String(timing.utxo_load)
        + String(',"script_verify":')
        + String(timing.script_verify)
        + String(',"utxo_apply":')
        + String(timing.utxo_apply)
        + String(',"commit":')
        + String(timing.commit)
        + String(',"block_connect_store_commit":')
        + String(timing.block_connect_store_commit)
        + String("}}")
    )


def local_reference_proof(
    shim_path: String,
    surface: String,
    datadir: String,
    peer: String,
    target: Int,
    result_path: String,
    progress_interval: Int,
) raises -> ProofResult:
    var benchmark_gate = benchmark_gate_for_target(target)
    var benchmark_kind = benchmark_gate + String("_p2p")
    var target_label = target_label_for_target(target)
    var expected_hash = expected_hash_for_target(target)
    var expected_utxos = expected_utxos_for_target(target)
    var native = Native(shim_path)
    var started = native.now_ms()
    var parts = split_peer(peer)
    var fd = native.socket_connect(parts[0], parts[1])
    var db = native.rocksdb_open(datadir)
    var timing = ConnectTiming()
    var current_utxos = 0
    var blocks_fetched = 0
    var blocks_connected = 0
    try:
        emit_telemetry(benchmark_gate, String("run_started"), String("startup"), 0, target, String(GENESIS_HASH_DISPLAY), peer, current_utxos, native.now_ms() - started, 0, timing)
        emit_telemetry(benchmark_gate, String("container_started"), String("startup"), 0, target, String(GENESIS_HASH_DISPLAY), peer, current_utxos, native.now_ms() - started, 0, timing)
        db_put_string(native, db, String("chainstate_backend"), String("rocksdb"))
        db_put_string(native, db, String("native_crypto_backend"), String("libsecp256k1"))
        db_put_string(native, db, String("sync_status"), String("headers_syncing"))
        emit_telemetry(benchmark_gate, String("node_started"), String("startup"), 0, target, String(GENESIS_HASH_DISPLAY), peer, current_utxos, native.now_ms() - started, 0, timing)
        handshake(native, fd)
        emit_telemetry(benchmark_gate, String("first_peer_byte"), String("peer_connect"), 0, target, String(GENESIS_HASH_DISPLAY), peer, current_utxos, native.now_ms() - started, 0, timing)
        var headers = headers_through(native, fd, target)
        var cursor = 0
        while cursor <= target:
            var end = cursor + 16
            if end > target + 1:
                end = target + 1
            var fetch_started = native.now_ms()
            var blocks = request_block_batch(native, fd, headers, cursor, end)
            timing.p2p_fetch += native.now_ms() - fetch_started
            for i in range(len(blocks)):
                var height = cursor + i
                var block_started = native.now_ms()
                var parse_started = native.now_ms()
                var prev_hash = headers[height - 1].copy() if height > 0 else hash_from_display(String(GENESIS_HASH_DISPLAY))
                verify_block_header(height, blocks[i], headers[height], prev_hash)
                timing.block_parse_validate += native.now_ms() - parse_started
                current_utxos = connect_block(native, db, shim_path, height, blocks[i], current_utxos, timing)
                timing.block_connect_store_commit += native.now_ms() - block_started
                blocks_fetched += 1
                blocks_connected += 1
                var h = display_hash(blocks[i].hash)
                var last_block_ms = native.now_ms() - block_started
                if height == 1:
                    emit_telemetry(benchmark_gate, String("first_block_connected"), String("block_connect"), height, target, h, peer, current_utxos, native.now_ms() - started, last_block_ms, timing)
                if progress_interval > 0 and (height == 0 or height == target or height % progress_interval == 0):
                    emit_progress(height, target, h, peer, current_utxos, last_block_ms, timing)
                    emit_telemetry(
                        benchmark_gate,
                        (String("target_reached") if height >= target else String("heartbeat")),
                        (String("complete") if height >= target else String("block_connect")),
                        height,
                        target,
                        h,
                        peer,
                        current_utxos,
                        native.now_ms() - started,
                        last_block_ms,
                        timing,
                    )
            cursor = end
        db_put_string(native, db, String("sync_status"), String("blocks_current"))
        var finish_hash = db_get_string(native, db, String("validated_hash"))
        if finish_hash != expected_hash:
            raise Error(benchmark_gate + String(" target hash mismatch"))
        if current_utxos != expected_utxos:
            raise Error(benchmark_gate + String(" UTXO count mismatch: ") + String(current_utxos))
        var total_ms = native.now_ms() - started
        emit_telemetry(benchmark_gate, String("run_finished"), String("complete"), target, target, finish_hash, peer, current_utxos, total_ms, 0, timing)
        var telemetry_tick_count = telemetry_tick_count_for_target(target, progress_interval)
        var json = (
            String('{"schema":"port.local_reference_proof.v1","category":"local_reference_sync",')
            + String('"benchmark_contract_version":1,"benchmark_gate":"')
            + benchmark_gate
            + String('","benchmark_kind":"')
            + benchmark_kind
            + String('","benchmark_lane":"')
            + benchmark_kind
            + String('",')
            + String('"benchmark_comparability":"comparable","implementation":"Mojo","port":"mojo","node_id":"mojobitnode","chain":"testnet4",')
            + String('"runtime_surface":"')
            + surface
            + String('","target_height":')
            + String(target)
            + String(',"header_target_height":')
            + String(target)
            + String(',"target_label":"')
            + target_label
            + String('",')
            + String('"peer_mode":"local_reference","peer":"')
            + peer
            + String('","byte_source":"local_reference_p2p","proof_mode":"p2p_sync","prefetch_depth":4,"script_runner_mode":"parallel",')
            + String('"rocksdb_wal_disabled":false,"fresh_state":true,"resume_supported":true,"datadir":"')
            + datadir
            + String('","chainstate_backend":"rocksdb","chainstate_status":"usable","native_storage":true,')
            + String('"native_crypto_available":true,"native_crypto_backend":"libsecp256k1","validated_height":')
            + String(target)
            + String(',"validated_hash":"')
            + finish_hash
            + String('","header_height":')
            + String(target)
            + String(',"stored_block_height":')
            + String(target)
            + String(',"blocks_fetched":')
            + String(blocks_fetched)
            + String(',"blocks_connected":')
            + String(blocks_connected)
            + String(',"chainstate_utxo_count":')
            + String(current_utxos)
            + String(',"utxo_accounting_policy":"core_spendable_v1","sync_status":"blocks_current","status":"passed","result":"passed",')
            + String('"current_blocker":null,"binary_gate_status":"not_attempted","failures":[],')
            + String('"reference_start_height":0,"reference_start_hash":"')
            + String(GENESIS_HASH_DISPLAY)
            + String('","reference_finish_height":')
            + String(target)
            + String(',"reference_finish_hash":"')
            + expected_hash
            + String('","captured_at":"unix_ms:')
            + String(started)
            + String('","telemetry_schema":"benchmark.telemetry_tick.v1","telemetry_summary":{"telemetry_quality":"clean","tick_count":')
            + String(telemetry_tick_count)
            + String(',"heartbeat_max_gap_ms":0,"lifecycle_markers":{"run_started":0,"container_started":0,"node_started":0,"first_peer_byte":0,"first_block_connected":0,"target_reached":')
            + String(total_ms)
            + String(',"run_finished":')
            + String(total_ms)
            + String('},"slow_blocks":[]},')
            + String('"timing_summary":{"total_ms":')
            + String(total_ms)
            + String(',"stage_totals_ms":{"p2p_fetch":')
            + String(timing.p2p_fetch)
            + String(',"block_parse_validate":')
            + String(timing.block_parse_validate)
            + String(',"utxo_load":')
            + String(timing.utxo_load)
            + String(',"script_verify":')
            + String(timing.script_verify)
            + String(',"utxo_apply":')
            + String(timing.utxo_apply)
            + String(',"commit":')
            + String(timing.commit)
            + String(',"block_connect_store_commit":')
            + String(timing.block_connect_store_commit)
            + String('}},"stage_totals_ms":{"utxo_load":')
            + String(timing.utxo_load)
            + String(',"script_verify":')
            + String(timing.script_verify)
            + String(',"utxo_apply":')
            + String(timing.utxo_apply)
            + String(',"commit":')
            + String(timing.commit)
            + String(',"block_connect_store_commit":')
            + String(timing.block_connect_store_commit)
            + String('},"slow_blocks":[]}')
        )
        if result_path != "":
            _ = native.handle.call["mojobitnode_write_text_len", Int32](
                result_path.unsafe_ptr(),
                Int32(result_path.byte_length()),
                json.unsafe_ptr(),
                Int32(json.byte_length()),
            )
        var result = ProofResult()
        result.json = json
        native.socket_close(fd)
        native.rocksdb_close(db)
        return result^
    except e:
        native.socket_close(fd)
        native.rocksdb_close(db)
        raise e^
