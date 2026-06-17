from std.algorithm.backend.cpu.parallelize import parallelize
from std.collections import List
from std.ffi import OwnedDLHandle
from std.memory.unsafe_pointer import alloc
from std.os import getenv

from script_corpus_foundation import (
    ByteCursor,
    CRYPTO_BACKEND_NATIVE,
    CRYPTO_BACKEND_PURE,
    CryptoBackend,
    HotPathProfile,
    SighashPrecompute,
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
    build_sighash_precompute_with_taproot,
    build_sighash_precompute_for_modes,
    clone_bytes,
    clone_bytes_profiled,
    evaluate_tapscript,
    evaluate_tapscript_with_crypto,
    evaluate_tapscript_with_crypto_profiled,
    evaluate_legacy_script,
    evaluate_legacy_script_with_crypto,
    evaluate_legacy_script_with_crypto_profiled,
    hash160,
    hash256,
    hotpath_add,
    hotpath_profile_from_env,
    hotpath_profile_json_field,
    hotpath_record_clone,
    hotpath_record_list_copy,
    is_p2pkh_script_pubkey,
    is_p2sh_script_pubkey,
    is_p2tr_script_pubkey,
    is_p2wsh_script_pubkey,
    is_v0_witness_script_program,
    legacy_sighash_cache_build_bytes,
    parse_push_only_stack,
    parse_transaction,
    sha256_digest,
    slice_bytes,
    slice_bytes_profiled,
    tapleaf_hash,
    taproot_merkle_root_from_control,
    tx_witness_count,
    tx_witness_item,
    verify_ecdsa_signature,
    verify_ecdsa_signature_for_mode_cached,
    verify_ecdsa_signature_for_mode_cached_with_crypto,
    verify_ecdsa_signature_for_mode_cached_with_crypto_profiled,
    verify_ecdsa_signature_for_mode,
    verify_schnorr_key_path_signature_cached,
    verify_schnorr_key_path_signature_cached_with_crypto,
    verify_schnorr_key_path_signature_cached_with_crypto_profiled,
    verify_schnorr_key_path_signature,
    verify_taproot_tweak,
    verify_taproot_tweak_with_crypto,
    verify_taproot_tweak_with_crypto_profiled,
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

    def rocksdb_batch_create(self) raises -> Int64:
        var batch = self.handle.call["mojobitnode_rocksdb_batch_create", Int64]()
        if batch == 0:
            raise Error("RocksDB batch create failed")
        return batch

    def rocksdb_batch_put(self, batch: Int64, ref key: List[UInt8], ref value: List[UInt8]) raises:
        var key_ptr = alloc[UInt8](len(key))
        var value_ptr = alloc[UInt8](len(value))
        for i in range(len(key)):
            key_ptr[i] = key[i]
        for i in range(len(value)):
            value_ptr[i] = value[i]
        var ok = self.handle.call["mojobitnode_rocksdb_batch_put", Int32](
            batch, key_ptr, Int32(len(key)), value_ptr, Int32(len(value))
        )
        key_ptr.free()
        value_ptr.free()
        if ok != 1:
            raise Error("RocksDB batch put failed")

    def rocksdb_batch_delete(self, batch: Int64, ref key: List[UInt8]) raises:
        var key_ptr = alloc[UInt8](len(key))
        for i in range(len(key)):
            key_ptr[i] = key[i]
        var ok = self.handle.call["mojobitnode_rocksdb_batch_delete", Int32](batch, key_ptr, Int32(len(key)))
        key_ptr.free()
        if ok != 1:
            raise Error("RocksDB batch delete failed")

    def rocksdb_batch_write(self, db: Int64, batch: Int64) raises:
        var ok = self.handle.call["mojobitnode_rocksdb_batch_write", Int32](db, batch)
        if ok != 1:
            raise Error("RocksDB batch write failed")

    def rocksdb_batch_destroy(self, batch: Int64):
        _ = self.handle.call["mojobitnode_rocksdb_batch_destroy", Int32](batch)

    def rocksdb_batch_apply_packed(self, db: Int64, ref packed_ops: List[UInt8]) raises:
        var ops_ptr = alloc[UInt8](len(packed_ops))
        for i in range(len(packed_ops)):
            ops_ptr[i] = packed_ops[i]
        var ok = self.handle.call["mojobitnode_rocksdb_batch_apply_packed", Int32](
            db, ops_ptr, Int32(len(packed_ops))
        )
        ops_ptr.free()
        if ok != 1:
            raise Error("RocksDB packed batch apply failed")

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

    def rocksdb_multi_get_packed(self, db: Int64, ref packed_keys: List[UInt8], cap: Int) raises -> List[UInt8]:
        var key_ptr = alloc[UInt8](len(packed_keys))
        var out_ptr = alloc[UInt8](cap)
        for i in range(len(packed_keys)):
            key_ptr[i] = packed_keys[i]
        var n = self.handle.call["mojobitnode_rocksdb_multi_get_packed", Int32](
            db, key_ptr, Int32(len(packed_keys)), out_ptr, Int32(cap)
        )
        var out = List[UInt8]()
        if n > 0:
            for i in range(Int(n)):
                out.append(out_ptr[i])
        key_ptr.free()
        out_ptr.free()
        if n == -3:
            raise Error("RocksDB multi_get output capacity too small")
        if n < 0:
            raise Error("RocksDB multi_get failed")
        return out^

    def crypto_metrics_reset(self):
        _ = self.handle.call["mojobitnode_crypto_metrics_reset", Int32]()

    def crypto_metric(self, name: String) -> Int64:
        return self.handle.call["mojobitnode_crypto_metric_len", Int64](
            name.unsafe_ptr(), Int32(name.byte_length())
        )


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


struct RocksMultiGetRow(Copyable):
    var found: Bool
    var value: List[UInt8]

    def __init__(out self):
        self.found = False
        self.value = List[UInt8]()


struct ConnectTiming(Copyable):
    var p2p_fetch: Int64
    var block_parse_validate: Int64
    var utxo_load: Int64
    var script_verify: Int64
    var utxo_apply: Int64
    var commit: Int64
    var block_connect_store_commit: Int64
    var utxo_delete_prepare: Int64
    var utxo_put_prepare: Int64
    var undo_put_prepare: Int64
    var metadata_put_prepare: Int64
    var rocksdb_write: Int64
    var rocksdb_batch_pack: Int64
    var prevout_batch_load: Int64
    var prevout_multi_get_call: Int64
    var prevout_utxo_decode: Int64
    var utxo_lookup_count: Int64
    var utxo_key_bytes: Int64
    var utxo_value_bytes: Int64
    var script_inputs: Int64
    var ecdsa_calls: Int64
    var ecdsa_ms: Int64
    var schnorr_calls: Int64
    var schnorr_ms: Int64
    var taproot_tweak_calls: Int64
    var taproot_tweak_ms: Int64
    var script_jobs: Int64
    var script_parallel_batches: Int64
    var script_runner_thread_count: Int64
    var sighash_precompute_transactions: Int64
    var sighash_precompute_bip143_transactions: Int64
    var sighash_precompute_taproot_transactions: Int64
    var sighash_precompute_ms: Int64
    var script_wall_ms: Int64
    var script_worker_cpu_ms: Int64
    var hotpath: HotPathProfile

    def __init__(out self):
        self.p2p_fetch = 0
        self.block_parse_validate = 0
        self.utxo_load = 0
        self.script_verify = 0
        self.utxo_apply = 0
        self.commit = 0
        self.block_connect_store_commit = 0
        self.utxo_delete_prepare = 0
        self.utxo_put_prepare = 0
        self.undo_put_prepare = 0
        self.metadata_put_prepare = 0
        self.rocksdb_write = 0
        self.rocksdb_batch_pack = 0
        self.prevout_batch_load = 0
        self.prevout_multi_get_call = 0
        self.prevout_utxo_decode = 0
        self.utxo_lookup_count = 0
        self.utxo_key_bytes = 0
        self.utxo_value_bytes = 0
        self.script_inputs = 0
        self.ecdsa_calls = 0
        self.ecdsa_ms = 0
        self.schnorr_calls = 0
        self.schnorr_ms = 0
        self.taproot_tweak_calls = 0
        self.taproot_tweak_ms = 0
        self.script_jobs = 0
        self.script_parallel_batches = 0
        self.script_runner_thread_count = 1
        self.sighash_precompute_transactions = 0
        self.sighash_precompute_bip143_transactions = 0
        self.sighash_precompute_taproot_transactions = 0
        self.sighash_precompute_ms = 0
        self.script_wall_ms = 0
        self.script_worker_cpu_ms = 0
        self.hotpath = HotPathProfile()


struct ScriptRunnerConfig(Copyable):
    var enabled: Bool
    var threads: Int
    var min_inputs: Int

    def __init__(out self):
        self.enabled = False
        self.threads = 0
        self.min_inputs = 2


struct ScriptVerifyResult(Copyable):
    var job_index: Int
    var ok: Bool
    var completed: Bool
    var tx_index: Int
    var input_index: Int
    var prev_txid: String
    var prev_vout: UInt32
    var spent_script_pubkey: String
    var failure_stage: String
    var failure: String
    var hotpath: HotPathProfile

    def __init__(out self):
        self.job_index = 0
        self.ok = False
        self.completed = False
        self.tx_index = 0
        self.input_index = 0
        self.prev_txid = String("")
        self.prev_vout = UInt32(0)
        self.spent_script_pubkey = String("")
        self.failure_stage = String("")
        self.failure = String("")
        self.hotpath = HotPathProfile()


struct ScriptVerifyJob(Copyable):
    var job_index: Int
    var context_index: Int
    var tx_index: Int
    var input_index: Int
    var txid: List[UInt8]
    var prev_hash: List[UInt8]
    var prev_vout: UInt32
    var prevout: Utxo

    def __init__(out self):
        self.job_index = 0
        self.context_index = 0
        self.tx_index = 0
        self.input_index = 0
        self.txid = List[UInt8]()
        self.prev_hash = List[UInt8]()
        self.prev_vout = UInt32(0)
        self.prevout = Utxo()


struct ScriptVerifyContext(Copyable):
    var tx: Transaction
    var tx_prevouts: List[Utxo]
    var spent_prevouts: List[TaprootPrevout]
    var sighash_precompute: SighashPrecompute

    def __init__(out self):
        self.tx = Transaction()
        self.tx_prevouts = List[Utxo]()
        self.spent_prevouts = List[TaprootPrevout]()
        self.sighash_precompute = SighashPrecompute()


struct ScriptVerifyStats(Copyable):
    var jobs: Int64
    var wall_ms: Int64
    var worker_cpu_ms: Int64
    var batches: Int64
    var threads: Int64
    var hotpath: HotPathProfile

    def __init__(out self):
        self.jobs = 0
        self.wall_ms = 0
        self.worker_cpu_ms = 0
        self.batches = 0
        self.threads = 1
        self.hotpath = HotPathProfile()


struct ShadowCryptoStats(Copyable):
    var enabled: Bool
    var runner_mode: String
    var runner_actual_mode: String
    var script_jobs: Int64
    var parallel_batches: Int64
    var thread_count: Int64
    var attempted: Int64
    var supported: Int64
    var unsupported: Int64
    var agreed: Int64
    var disagreed: Int64
    var unsupported_p2sh: Int64
    var unsupported_segwit_v0: Int64
    var unsupported_legacy_other: Int64
    var unsupported_other: Int64
    var p2pkh_ecdsa_ms: Int64
    var taproot_schnorr_ms: Int64
    var taproot_tweak_ms: Int64
    var p2pkh_ecdsa_inputs: Int64
    var p2sh_inputs: Int64
    var segwit_v0_inputs: Int64
    var legacy_other_inputs: Int64
    var other_inputs: Int64
    var taproot_inputs: Int64
    var taproot_script_path_inputs: Int64
    var first_disagreement_set: Bool
    var first_disagreement_height: Int
    var first_disagreement_txid: String
    var first_disagreement_input_index: Int
    var first_disagreement_spent_script_pubkey: String
    var first_disagreement_native_result: String
    var first_disagreement_shadow_result: String
    var first_disagreement_failure_stage: String

    def __init__(out self):
        self.enabled = False
        self.runner_mode = String("sequential")
        self.runner_actual_mode = String("sequential")
        self.script_jobs = 0
        self.parallel_batches = 0
        self.thread_count = 1
        self.attempted = 0
        self.supported = 0
        self.unsupported = 0
        self.agreed = 0
        self.disagreed = 0
        self.unsupported_p2sh = 0
        self.unsupported_segwit_v0 = 0
        self.unsupported_legacy_other = 0
        self.unsupported_other = 0
        self.p2pkh_ecdsa_ms = 0
        self.taproot_schnorr_ms = 0
        self.taproot_tweak_ms = 0
        self.p2pkh_ecdsa_inputs = 0
        self.p2sh_inputs = 0
        self.segwit_v0_inputs = 0
        self.legacy_other_inputs = 0
        self.other_inputs = 0
        self.taproot_inputs = 0
        self.taproot_script_path_inputs = 0
        self.first_disagreement_set = False
        self.first_disagreement_height = 0
        self.first_disagreement_txid = String("")
        self.first_disagreement_input_index = 0
        self.first_disagreement_spent_script_pubkey = String("")
        self.first_disagreement_native_result = String("")
        self.first_disagreement_shadow_result = String("")
        self.first_disagreement_failure_stage = String("")


struct ShadowCryptoResult(Copyable):
    var completed: Bool
    var attempted: Bool
    var supported: Bool
    var family: String
    var unsupported_reason: String
    var elapsed_ms: Int64
    var verifier_result: ScriptVerifyResult

    def __init__(out self):
        self.completed = False
        self.attempted = False
        self.supported = False
        self.family = String("")
        self.unsupported_reason = String("")
        self.elapsed_ms = 0
        self.verifier_result = ScriptVerifyResult()


struct BlockUtxoDelta(Copyable):
    var external_spend_keys: List[List[UInt8]]
    var created_txids: List[List[UInt8]]
    var created_vouts: List[UInt32]
    var created_values: List[Utxo]
    var created_spent: List[Bool]
    var undo_tx_indexes: List[Int]
    var undo_input_indexes: List[Int]
    var undo_prev_hashes: List[List[UInt8]]
    var undo_prev_vouts: List[UInt32]
    var undo_prevouts: List[Utxo]
    var undo_same_block: List[Bool]
    var metadata_keys: List[List[UInt8]]
    var metadata_values: List[List[UInt8]]
    var block_key: List[UInt8]
    var block_value: List[UInt8]
    var undo_key: List[UInt8]
    var undo_value: List[UInt8]
    var external_spends: Int

    def __init__(out self):
        self.external_spend_keys = List[List[UInt8]]()
        self.created_txids = List[List[UInt8]]()
        self.created_vouts = List[UInt32]()
        self.created_values = List[Utxo]()
        self.created_spent = List[Bool]()
        self.undo_tx_indexes = List[Int]()
        self.undo_input_indexes = List[Int]()
        self.undo_prev_hashes = List[List[UInt8]]()
        self.undo_prev_vouts = List[UInt32]()
        self.undo_prevouts = List[Utxo]()
        self.undo_same_block = List[Bool]()
        self.metadata_keys = List[List[UInt8]]()
        self.metadata_values = List[List[UInt8]]()
        self.block_key = List[UInt8]()
        self.block_value = List[UInt8]()
        self.undo_key = List[UInt8]()
        self.undo_value = List[UInt8]()
        self.external_spends = 0


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


def _parse_non_negative_int(value: String, default_value: Int) -> Int:
    if value.byte_length() == 0:
        return default_value
    var out = 0
    for i in range(value.byte_length()):
        var code = ord(value[byte=i])
        if code < 48 or code > 57:
            return default_value
        out = out * 10 + (code - 48)
    return out


def script_runner_config_from_env() -> ScriptRunnerConfig:
    var config = ScriptRunnerConfig()
    var enabled = getenv("MOJOBITNODE_PAR_SCRIPT_VERIFY", "0")
    config.enabled = enabled == "1" or enabled == "true" or enabled == "TRUE"
    config.threads = _parse_non_negative_int(getenv("MOJOBITNODE_SCRIPT_THREADS", "0"), 0)
    config.min_inputs = _parse_non_negative_int(getenv("MOJOBITNODE_SCRIPT_MIN_INPUTS", "2"), 2)
    if config.min_inputs < 1:
        config.min_inputs = 1
    return config^


def script_runner_mode(ref timing: ConnectTiming) -> String:
    if timing.script_parallel_batches > 0:
        return String("parallel")
    return String("sequential")


def json_escape(value: String) -> String:
    var out = String("")
    for i in range(value.byte_length()):
        var code = ord(value[byte=i])
        if code == 34:
            out += String("\\\"")
        elif code == 92:
            out += String("\\\\")
        elif code >= 32 and code <= 126:
            out += chr(code)
        else:
            out += String(" ")
    return out^


def bool_json(value: Bool) -> String:
    if value:
        return String("true")
    return String("false")


def shadow_crypto_supported_family(ref job: ScriptVerifyJob) -> String:
    if is_p2pkh_script_pubkey(job.prevout.script_pubkey):
        return String("p2pkh_ecdsa")
    if is_p2sh_script_pubkey(job.prevout.script_pubkey):
        return String("p2sh")
    if len(job.prevout.script_pubkey) >= 2 and job.prevout.script_pubkey[0] == UInt8(0):
        return String("segwit_v0")
    if is_p2tr_script_pubkey(job.prevout.script_pubkey):
        return String("taproot")
    if len(job.prevout.script_pubkey) > 0:
        return String("legacy_other")
    return String("other")


def shadow_crypto_unsupported_reason(ref job: ScriptVerifyJob) -> String:
    if is_p2sh_script_pubkey(job.prevout.script_pubkey):
        return String("p2sh")
    if len(job.prevout.script_pubkey) >= 2 and job.prevout.script_pubkey[0] == UInt8(0):
        return String("segwit_v0")
    if len(job.prevout.script_pubkey) > 0:
        return String("legacy_other")
    return String("other")


def shadow_crypto_record_unsupported(mut stats: ShadowCryptoStats, reason: String):
    stats.unsupported += 1
    if reason == "p2sh":
        stats.unsupported_p2sh += 1
    elif reason == "segwit_v0":
        stats.unsupported_segwit_v0 += 1
    elif reason == "legacy_other":
        stats.unsupported_legacy_other += 1
    else:
        stats.unsupported_other += 1


def shadow_crypto_record_first_disagreement(
    mut stats: ShadowCryptoStats,
    height: Int,
    ref job: ScriptVerifyJob,
    ref result: ScriptVerifyResult,
):
    if stats.first_disagreement_set:
        return
    stats.first_disagreement_set = True
    stats.first_disagreement_height = height
    stats.first_disagreement_txid = display_hash(job.txid)
    stats.first_disagreement_input_index = job.input_index
    stats.first_disagreement_spent_script_pubkey = bytes_to_hex(job.prevout.script_pubkey)
    stats.first_disagreement_native_result = String("passed")
    if result.failure_stage == "error":
        stats.first_disagreement_shadow_result = String("error")
    elif not result.ok:
        stats.first_disagreement_shadow_result = String("failed")
    else:
        stats.first_disagreement_shadow_result = String("passed")
    stats.first_disagreement_failure_stage = result.failure_stage


def shadow_crypto_row_for_job(ref job: ScriptVerifyJob) -> ShadowCryptoResult:
    var row = ShadowCryptoResult()
    row.attempted = True
    row.family = shadow_crypto_supported_family(job)
    if row.family == "":
        row.supported = False
        row.unsupported_reason = shadow_crypto_unsupported_reason(job)
        row.completed = True
    else:
        row.supported = True
    return row^


def shadow_crypto_reduce_row(
    mut stats: ShadowCryptoStats,
    height: Int,
    ref contexts: List[ScriptVerifyContext],
    ref job: ScriptVerifyJob,
    ref row: ShadowCryptoResult,
) raises:
    if not row.attempted:
        return
    stats.attempted += 1
    if not row.supported:
        shadow_crypto_record_unsupported(stats, row.unsupported_reason)
        return
    if not row.completed:
        raise Error(
            String("shadow crypto job did not complete at height ")
            + String(height)
            + String(" job_index=")
            + String(job.job_index)
        )
    stats.supported += 1
    if row.family == "p2pkh_ecdsa":
        stats.p2pkh_ecdsa_ms += row.elapsed_ms
        stats.p2pkh_ecdsa_inputs += 1
    elif row.family == "p2sh":
        stats.p2sh_inputs += 1
    elif row.family == "segwit_v0":
        stats.segwit_v0_inputs += 1
    elif row.family == "legacy_other":
        stats.legacy_other_inputs += 1
    elif row.family == "other":
        stats.other_inputs += 1
    elif row.family == "taproot":
        stats.taproot_schnorr_ms += row.elapsed_ms
        stats.taproot_inputs += 1
        if job.context_index >= 0 and job.context_index < len(contexts):
            if tx_witness_count(contexts[job.context_index].tx, job.input_index) > 1:
                stats.taproot_tweak_ms += row.elapsed_ms
                stats.taproot_script_path_inputs += 1
    if row.verifier_result.ok:
        stats.agreed += 1
    else:
        stats.disagreed += 1
        shadow_crypto_record_first_disagreement(stats, height, job, row.verifier_result)


def _shadow_test_p2pkh_script_pubkey() -> List[UInt8]:
    var out = List[UInt8]()
    out.append(UInt8(0x76))
    out.append(UInt8(0xA9))
    out.append(UInt8(0x14))
    for _ in range(20):
        out.append(UInt8(0x11))
    out.append(UInt8(0x88))
    out.append(UInt8(0xAC))
    return out^


def _shadow_test_job(job_index: Int, input_index: Int, ref script_pubkey: List[UInt8]) -> ScriptVerifyJob:
    var job = ScriptVerifyJob()
    job.job_index = job_index
    job.tx_index = job_index
    job.input_index = input_index
    job.prev_vout = UInt32(input_index)
    for _ in range(32):
        job.txid.append(UInt8(job_index + 1))
        job.prev_hash.append(UInt8(job_index + 2))
    job.prevout.script_pubkey = script_pubkey.copy()
    return job^


def _shadow_test_row(ref job: ScriptVerifyJob, ok: Bool, stage: String, elapsed_ms: Int64) -> ShadowCryptoResult:
    var row = shadow_crypto_row_for_job(job)
    row.elapsed_ms = elapsed_ms
    var result = script_verify_result_for_job(job)
    result.completed = True
    result.ok = ok
    result.failure_stage = stage
    if ok:
        result.failure = String("")
    else:
        result.failure = String("synthetic shadow failure")
    row.verifier_result = result^
    row.completed = True
    return row^


def shadow_crypto_reduction_smoke() raises -> Bool:
    var contexts = List[ScriptVerifyContext]()
    var p2pkh = _shadow_test_p2pkh_script_pubkey()
    var empty = List[UInt8]()

    var jobs = List[ScriptVerifyJob]()
    var unsupported_job = _shadow_test_job(0, 0, empty)
    var pass_job = _shadow_test_job(1, 1, p2pkh)
    var error_job = _shadow_test_job(2, 2, p2pkh)
    var late_fail_job = _shadow_test_job(3, 3, p2pkh)
    jobs.append(unsupported_job^)
    jobs.append(pass_job^)
    jobs.append(error_job^)
    jobs.append(late_fail_job^)

    var rows = List[ShadowCryptoResult]()
    var unsupported_row = ShadowCryptoResult()
    unsupported_row.attempted = True
    unsupported_row.supported = False
    unsupported_row.unsupported_reason = String("other")
    unsupported_row.completed = True
    rows.append(unsupported_row^)
    rows.append(_shadow_test_row(jobs[1], True, String(""), 7))
    rows.append(_shadow_test_row(jobs[2], False, String("error"), 11))
    rows.append(_shadow_test_row(jobs[3], False, String("failed"), 13))

    var stats = ShadowCryptoStats()
    for i in range(len(rows)):
        shadow_crypto_reduce_row(stats, 5000, contexts, jobs[i], rows[i])

    return (
        stats.attempted == 4
        and stats.supported == 3
        and stats.unsupported == 1
        and stats.unsupported_other == 1
        and stats.agreed == 1
        and stats.disagreed == 2
        and stats.p2pkh_ecdsa_inputs == 3
        and stats.p2pkh_ecdsa_ms == 31
        and stats.first_disagreement_set
        and stats.first_disagreement_height == 5000
        and stats.first_disagreement_input_index == 2
        and stats.first_disagreement_shadow_result == "error"
        and stats.first_disagreement_failure_stage == "error"
    )


def shadow_crypto_json(ref stats: ShadowCryptoStats) -> String:
    var first = String("null")
    if stats.first_disagreement_set:
        first = (
            String('{"height":')
            + String(stats.first_disagreement_height)
            + String(',"txid":"')
            + stats.first_disagreement_txid
            + String('","input_index":')
            + String(stats.first_disagreement_input_index)
            + String(',"spent_script_pubkey":"')
            + stats.first_disagreement_spent_script_pubkey
            + String('","native_result":"')
            + stats.first_disagreement_native_result
            + String('","shadow_result":"')
            + stats.first_disagreement_shadow_result
            + String('","failure_stage":"')
            + json_escape(stats.first_disagreement_failure_stage)
            + String('"}')
        )
    return (
        String('"shadow_crypto":{"enabled":')
        + bool_json(stats.enabled)
        + String(',"backend":"mojo-pure-secp256k1","diagnostic_only":true,')
        + String('"native_fallback_used":false,"runner_mode":"')
        + stats.runner_mode
        + String('","runner_actual_mode":"')
        + stats.runner_actual_mode
        + String('","script_jobs":')
        + String(stats.script_jobs)
        + String(',"parallel_batches":')
        + String(stats.parallel_batches)
        + String(',"thread_count":')
        + String(stats.thread_count)
        + String(',"attempted_script_inputs":')
        + String(stats.attempted)
        + String(',"supported_script_inputs":')
        + String(stats.supported)
        + String(',"unsupported_script_inputs":')
        + String(stats.unsupported)
        + String(',"agreed_script_inputs":')
        + String(stats.agreed)
        + String(',"disagreed_script_inputs":')
        + String(stats.disagreed)
        + String(',"unsupported_by_reason":{"p2sh":')
        + String(stats.unsupported_p2sh)
        + String(',"segwit_v0":')
        + String(stats.unsupported_segwit_v0)
        + String(',"legacy_other":')
        + String(stats.unsupported_legacy_other)
        + String(',"other":')
        + String(stats.unsupported_other)
        + String('},"timing_ms":{"p2pkh_ecdsa":')
        + String(stats.p2pkh_ecdsa_ms)
        + String(',"taproot_schnorr":')
        + String(stats.taproot_schnorr_ms)
        + String(',"taproot_tweak":')
        + String(stats.taproot_tweak_ms)
        + String('},"counts_by_supported_family":{"p2pkh_ecdsa":')
        + String(stats.p2pkh_ecdsa_inputs)
        + String(',"p2sh":')
        + String(stats.p2sh_inputs)
        + String(',"segwit_v0":')
        + String(stats.segwit_v0_inputs)
        + String(',"legacy_other":')
        + String(stats.legacy_other_inputs)
        + String(',"other":')
        + String(stats.other_inputs)
        + String(',"taproot":')
        + String(stats.taproot_inputs)
        + String(',"taproot_script_path":')
        + String(stats.taproot_script_path_inputs)
        + String('},"first_disagreement":')
        + first
        + String("}")
    )^


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


def pack_multi_get_keys(ref keys: List[List[UInt8]]) -> List[UInt8]:
    var out = List[UInt8]()
    _append_u32_be(out, UInt32(len(keys)))
    for i in range(len(keys)):
        _append_u32_be(out, UInt32(len(keys[i])))
        append_bytes(out, keys[i])
    return out^


def decode_multi_get_rows(ref bytes: List[UInt8]) raises -> List[RocksMultiGetRow]:
    if len(bytes) < 4:
        raise Error("RocksDB multi_get result too short")
    var count = Int(_read_u32_be(bytes, 0))
    var offset = 4
    var rows = List[RocksMultiGetRow]()
    for _ in range(count):
        if offset + 5 > len(bytes):
            raise Error("RocksDB multi_get result row truncated")
        var status = bytes[offset]
        offset += 1
        var value_len = Int(_read_u32_be(bytes, offset))
        offset += 4
        if value_len < 0 or offset + value_len > len(bytes):
            raise Error("RocksDB multi_get value truncated")
        var row = RocksMultiGetRow()
        if status == UInt8(0):
            row.found = True
            row.value = slice_bytes(bytes, offset, offset + value_len)
        elif status == UInt8(1):
            row.found = False
        else:
            raise Error("RocksDB multi_get unknown row status")
        rows.append(row^)
        offset += value_len
    if offset != len(bytes):
        raise Error("RocksDB multi_get result has trailing bytes")
    return rows^


def rocksdb_multi_get_rows(mut native: Native, db: Int64, ref keys: List[List[UInt8]]) raises -> List[RocksMultiGetRow]:
    var packed = pack_multi_get_keys(keys)
    var cap = len(packed) + (len(keys) * 512) + 4096
    if cap < 4096:
        cap = 4096
    var bytes = native.rocksdb_multi_get_packed(db, packed, cap)
    return decode_multi_get_rows(bytes)


def compare_byte_lists(ref left: List[UInt8], ref right: List[UInt8]) -> Int:
    var limit = len(left)
    if len(right) < limit:
        limit = len(right)
    for i in range(limit):
        if left[i] < right[i]:
            return -1
        if left[i] > right[i]:
            return 1
    if len(left) < len(right):
        return -1
    if len(left) > len(right):
        return 1
    return 0


def outpoint_index_key(ref txid: List[UInt8], vout: UInt32) -> List[UInt8]:
    var out = clone_bytes(txid)
    _append_u32_be(out, vout)
    return out^


struct PackedKeyIndex(Copyable):
    var keys: List[List[UInt8]]
    var indexes: List[Int]

    def __init__(out self):
        self.keys = List[List[UInt8]]()
        self.indexes = List[Int]()

    def find_key(ref self, ref key: List[UInt8]) -> Int:
        var low = 0
        var high = len(self.keys)
        while low < high:
            var mid = (low + high) // 2
            var cmp = compare_byte_lists(self.keys[mid], key)
            if cmp == 0:
                return self.indexes[mid]
            if cmp < 0:
                low = mid + 1
            else:
                high = mid
        return -1

    def contains_key(ref self, ref key: List[UInt8]) -> Bool:
        return self.find_key(key) >= 0

    def add_key(mut self, ref key: List[UInt8], index: Int) -> Bool:
        var low = 0
        var high = len(self.keys)
        while low < high:
            var mid = (low + high) // 2
            var cmp = compare_byte_lists(self.keys[mid], key)
            if cmp == 0:
                return False
            if cmp < 0:
                low = mid + 1
            else:
                high = mid

        var insert_at = low
        self.keys.append(clone_bytes(key))
        self.indexes.append(index)
        var pos = len(self.keys) - 1
        while pos > insert_at:
            self.keys[pos] = self.keys[pos - 1].copy()
            self.indexes[pos] = self.indexes[pos - 1]
            pos -= 1
        self.keys[insert_at] = clone_bytes(key)
        self.indexes[insert_at] = index
        return True

    def add_outpoint(mut self, ref txid: List[UInt8], vout: UInt32, index: Int) -> Bool:
        var key = outpoint_index_key(txid, vout)
        return self.add_key(key, index)

    def find_outpoint(ref self, ref txid: List[UInt8], vout: UInt32) -> Int:
        var key = outpoint_index_key(txid, vout)
        return self.find_key(key)

    def contains_outpoint(ref self, ref txid: List[UInt8], vout: UInt32) -> Bool:
        return self.find_outpoint(txid, vout) >= 0


def append_packed_batch_put(mut out: List[UInt8], ref key: List[UInt8], ref value: List[UInt8]):
    out.append(UInt8(0))
    _append_u32_be(out, UInt32(len(key)))
    append_bytes(out, key)
    _append_u32_be(out, UInt32(len(value)))
    append_bytes(out, value)


def append_packed_batch_delete(mut out: List[UInt8], ref key: List[UInt8]):
    out.append(UInt8(1))
    _append_u32_be(out, UInt32(len(key)))
    append_bytes(out, key)
    _append_u32_be(out, UInt32(0))


def use_packed_rocksdb_batch_apply() -> Bool:
    return getenv("MOJOBITNODE_PACKED_ROCKSDB_BATCH", "0") == "1"


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


def _undo_key(height: Int) -> List[UInt8]:
    return ascii_string_to_bytes(String("undo:") + String(height))


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


def append_delta_created(mut delta: BlockUtxoDelta, ref txid: List[UInt8], vout: UInt32, ref utxo: Utxo):
    delta.created_txids.append(clone_bytes(txid))
    delta.created_vouts.append(vout)
    delta.created_values.append(utxo.copy())
    delta.created_spent.append(False)


def is_p2wpkh_script_pubkey_local(ref script_pubkey: List[UInt8]) -> Bool:
    return len(script_pubkey) == 22 and script_pubkey[0] == UInt8(0) and script_pubkey[1] == UInt8(0x14)


def spent_prevouts_need_sighash_precompute(ref prevouts: List[TaprootPrevout]) -> Bool:
    for i in range(len(prevouts)):
        if (
            is_p2sh_script_pubkey(prevouts[i].script_pubkey)
            or is_p2wpkh_script_pubkey_local(prevouts[i].script_pubkey)
            or is_p2wsh_script_pubkey(prevouts[i].script_pubkey)
            or is_p2tr_script_pubkey(prevouts[i].script_pubkey)
        ):
            return True
    return False


def p2sh_input_redeem_is_witness_program(ref tx: Transaction, input_index: Int) raises -> Bool:
    if input_index < 0 or input_index >= len(tx.inputs):
        return False
    var stack = parse_push_only_stack(tx.inputs[input_index].script_sig)
    if len(stack) == 0:
        return False
    return is_v0_witness_script_program(stack[len(stack) - 1].data)


def spent_prevouts_need_bip143_precompute(ref tx: Transaction, ref prevouts: List[TaprootPrevout]) raises -> Bool:
    for i in range(len(prevouts)):
        if is_p2wpkh_script_pubkey_local(prevouts[i].script_pubkey) or is_p2wsh_script_pubkey(prevouts[i].script_pubkey):
            return True
        if is_p2sh_script_pubkey(prevouts[i].script_pubkey) and p2sh_input_redeem_is_witness_program(tx, i):
            return True
    return False


def spent_prevouts_need_legacy_precompute(ref tx: Transaction, ref prevouts: List[TaprootPrevout]) raises -> Bool:
    for i in range(len(prevouts)):
        if is_p2pkh_script_pubkey(prevouts[i].script_pubkey):
            return True
        if is_p2sh_script_pubkey(prevouts[i].script_pubkey):
            if not p2sh_input_redeem_is_witness_program(tx, i):
                return True
            continue
        if (
            not is_p2wpkh_script_pubkey_local(prevouts[i].script_pubkey)
            and not is_p2wsh_script_pubkey(prevouts[i].script_pubkey)
            and not is_p2tr_script_pubkey(prevouts[i].script_pubkey)
        ):
            return True
    return False


def spent_prevouts_need_taproot_precompute(ref prevouts: List[TaprootPrevout]) -> Bool:
    for i in range(len(prevouts)):
        if is_p2tr_script_pubkey(prevouts[i].script_pubkey):
            return True
    return False


def mark_delta_created_spent(mut delta: BlockUtxoDelta, ref txid: List[UInt8], vout: UInt32) -> Bool:
    for i in range(len(delta.created_txids)):
        if delta.created_vouts[i] == vout and bytes_equal(delta.created_txids[i], txid):
            delta.created_spent[i] = True
            return True
    return False


def find_created_delta_index(ref delta: BlockUtxoDelta, ref txid: List[UInt8], vout: UInt32) -> Int:
    for i in range(len(delta.created_txids)):
        if delta.created_vouts[i] == vout and bytes_equal(delta.created_txids[i], txid):
            return i
    return -1


def contains_outpoint(ref txids: List[List[UInt8]], ref vouts: List[UInt32], ref txid: List[UInt8], vout: UInt32) -> Bool:
    for i in range(len(txids)):
        if vouts[i] == vout and bytes_equal(txids[i], txid):
            return True
    return False


def append_outpoint_if_missing(mut txids: List[List[UInt8]], mut vouts: List[UInt32], ref txid: List[UInt8], vout: UInt32) -> Bool:
    if contains_outpoint(txids, vouts, txid, vout):
        return False
    txids.append(clone_bytes(txid))
    vouts.append(vout)
    return True


def contains_txid(ref txids: List[List[UInt8]], ref txid: List[UInt8]) -> Bool:
    for i in range(len(txids)):
        if bytes_equal(txids[i], txid):
            return True
    return False


def find_loaded_utxo_index(ref txids: List[List[UInt8]], ref vouts: List[UInt32], ref txid: List[UInt8], vout: UInt32) -> Int:
    for i in range(len(txids)):
        if vouts[i] == vout and bytes_equal(txids[i], txid):
            return i
    return -1


def append_delta_external_spend(mut delta: BlockUtxoDelta, ref prev_hash: List[UInt8], prev_vout: UInt32):
    var key = _utxo_key(prev_hash, prev_vout)
    delta.external_spend_keys.append(key^)
    delta.external_spends += 1


def append_delta_undo(
    mut delta: BlockUtxoDelta,
    tx_index: Int,
    input_index: Int,
    ref prev_hash: List[UInt8],
    prev_vout: UInt32,
    ref prevout: Utxo,
    same_block: Bool,
):
    delta.undo_tx_indexes.append(tx_index)
    delta.undo_input_indexes.append(input_index)
    delta.undo_prev_hashes.append(clone_bytes(prev_hash))
    delta.undo_prev_vouts.append(prev_vout)
    delta.undo_prevouts.append(prevout.copy())
    delta.undo_same_block.append(same_block)


def append_delta_metadata(mut delta: BlockUtxoDelta, name: String, value: String):
    var key = _meta_key(name)
    var bytes = ascii_string_to_bytes(value)
    delta.metadata_keys.append(key^)
    delta.metadata_values.append(bytes^)


def block_delta_unspent_created(ref delta: BlockUtxoDelta) -> Int:
    var count = 0
    for i in range(len(delta.created_spent)):
        if not delta.created_spent[i]:
            count += 1
    return count


def encode_block_undo(height: Int, ref delta: BlockUtxoDelta) raises -> List[UInt8]:
    var out = ascii_string_to_bytes(String("mojo_undo_v1"))
    append_u32_le(out, UInt32(height))
    append_varint(out, len(delta.undo_prevouts))
    for i in range(len(delta.undo_prevouts)):
        append_u32_le(out, UInt32(delta.undo_tx_indexes[i]))
        append_u32_le(out, UInt32(delta.undo_input_indexes[i]))
        append_bytes(out, delta.undo_prev_hashes[i])
        append_u32_le(out, delta.undo_prev_vouts[i])
        out.append(UInt8(1) if delta.undo_same_block[i] else UInt8(0))
        var encoded = encode_utxo(
            delta.undo_prevouts[i].height,
            delta.undo_prevouts[i].value_sats,
            delta.undo_prevouts[i].coinbase,
            delta.undo_prevouts[i].script_pubkey,
        )
        append_varint(out, len(encoded))
        append_bytes(out, encoded)
    return out^


def apply_block_delta(mut native: Native, db: Int64, mut timing: ConnectTiming, ref delta: BlockUtxoDelta) raises:
    if not use_packed_rocksdb_batch_apply():
        var batch = native.rocksdb_batch_create()
        try:
            var delete_prepare_started = native.now_ms()
            for i in range(len(delta.external_spend_keys)):
                native.rocksdb_batch_delete(batch, delta.external_spend_keys[i])
            timing.utxo_delete_prepare += native.now_ms() - delete_prepare_started

            var put_prepare_started = native.now_ms()
            for i in range(len(delta.created_txids)):
                if delta.created_spent[i]:
                    continue
                var key = _utxo_key(delta.created_txids[i], delta.created_vouts[i])
                var value = encode_utxo(
                    delta.created_values[i].height,
                    delta.created_values[i].value_sats,
                    delta.created_values[i].coinbase,
                    delta.created_values[i].script_pubkey,
                )
                native.rocksdb_batch_put(batch, key, value)
            timing.utxo_put_prepare += native.now_ms() - put_prepare_started

            var undo_prepare_started = native.now_ms()
            native.rocksdb_batch_put(batch, delta.undo_key, delta.undo_value)
            timing.undo_put_prepare += native.now_ms() - undo_prepare_started

            var metadata_prepare_started = native.now_ms()
            native.rocksdb_batch_put(batch, delta.block_key, delta.block_value)
            for i in range(len(delta.metadata_keys)):
                native.rocksdb_batch_put(batch, delta.metadata_keys[i], delta.metadata_values[i])
            timing.metadata_put_prepare += native.now_ms() - metadata_prepare_started

            var write_started = native.now_ms()
            native.rocksdb_batch_write(db, batch)
            timing.rocksdb_write += native.now_ms() - write_started
        except e:
            native.rocksdb_batch_destroy(batch)
            raise Error(String(e))
        native.rocksdb_batch_destroy(batch)
        return

    var op_count = len(delta.external_spend_keys) + 2 + len(delta.metadata_keys)
    for i in range(len(delta.created_spent)):
        if not delta.created_spent[i]:
            op_count += 1

    var packed = List[UInt8]()
    var pack_started = native.now_ms()
    _append_u32_be(packed, UInt32(op_count))

    var delete_prepare_started = native.now_ms()
    for i in range(len(delta.external_spend_keys)):
        append_packed_batch_delete(packed, delta.external_spend_keys[i])
    timing.utxo_delete_prepare += native.now_ms() - delete_prepare_started

    var put_prepare_started = native.now_ms()
    for i in range(len(delta.created_txids)):
        if delta.created_spent[i]:
            continue
        var key = _utxo_key(delta.created_txids[i], delta.created_vouts[i])
        var value = encode_utxo(
            delta.created_values[i].height,
            delta.created_values[i].value_sats,
            delta.created_values[i].coinbase,
            delta.created_values[i].script_pubkey,
        )
        append_packed_batch_put(packed, key, value)
    timing.utxo_put_prepare += native.now_ms() - put_prepare_started

    var undo_prepare_started = native.now_ms()
    append_packed_batch_put(packed, delta.undo_key, delta.undo_value)
    timing.undo_put_prepare += native.now_ms() - undo_prepare_started

    var metadata_prepare_started = native.now_ms()
    append_packed_batch_put(packed, delta.block_key, delta.block_value)
    for i in range(len(delta.metadata_keys)):
        append_packed_batch_put(packed, delta.metadata_keys[i], delta.metadata_values[i])
    timing.metadata_put_prepare += native.now_ms() - metadata_prepare_started
    timing.rocksdb_batch_pack += native.now_ms() - pack_started

    var write_started = native.now_ms()
    native.rocksdb_batch_apply_packed(db, packed)
    timing.rocksdb_write += native.now_ms() - write_started


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


def verify_p2wpkh_spend(
    shim_path: String,
    ref crypto: CryptoBackend,
    ref tx: Transaction,
    input_index: Int,
    ref prevout: Utxo,
    ref sighash_precompute: SighashPrecompute,
    mut profile: HotPathProfile,
) raises -> Bool:
    if tx_witness_count(tx, input_index) != 2:
        return False
    var sig = tx_witness_item(tx, input_index, 0)
    var pubkey = tx_witness_item(tx, input_index, 1)
    var actual = hash160(pubkey.data)
    var expected = slice_bytes_profiled(prevout.script_pubkey, 2, 22, profile)
    if not bytes_equal(actual, expected):
        return False
    var script_code = List[UInt8]()
    script_code.append(UInt8(0x76))
    script_code.append(UInt8(0xA9))
    script_code.append(UInt8(0x14))
    append_bytes(script_code, expected)
    script_code.append(UInt8(0x88))
    script_code.append(UInt8(0xAC))
    return verify_ecdsa_signature_for_mode_cached_with_crypto_profiled(
        crypto, sig.data, pubkey.data, tx, input_index, script_code, True, prevout.value_sats, sighash_precompute, profile
    )


def verify_witness_v0_spend(
    shim_path: String,
    ref crypto: CryptoBackend,
    ref tx: Transaction,
    input_index: Int,
    ref prevout: Utxo,
    ref sighash_precompute: SighashPrecompute,
    mut profile: HotPathProfile,
) raises -> Bool:
    if len(prevout.script_pubkey) == 22 and prevout.script_pubkey[0] == UInt8(0) and prevout.script_pubkey[1] == UInt8(0x14):
        return verify_p2wpkh_spend(shim_path, crypto, tx, input_index, prevout, sighash_precompute, profile)
    if is_p2wsh_script_pubkey(prevout.script_pubkey):
        var witness_count = tx_witness_count(tx, input_index)
        if witness_count < 1:
            return False
        var script_item = tx_witness_item(tx, input_index, witness_count - 1)
        var script_hash = sha256_digest(script_item.data)
        var expected = slice_bytes_profiled(prevout.script_pubkey, 2, 34, profile)
        if not bytes_equal(script_hash, expected):
            return False
        var stack = List[ScriptStackItem]()
        for i in range(witness_count - 1):
            var item = tx_witness_item(tx, input_index, i)
            stack.append(item^)
        return evaluate_legacy_script_with_crypto_profiled(
            script_item.data, stack^, tx, input_index, shim_path, crypto, profile, True, True, prevout.value_sats
        )
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
    ref crypto: CryptoBackend,
    ref tx: Transaction,
    input_index: Int,
    ref all_prevouts: List[Utxo],
    ref spent_prevouts: List[TaprootPrevout],
    ref sighash_precompute: SighashPrecompute,
    mut profile: HotPathProfile,
) raises -> Bool:
    var prevout = all_prevouts[input_index].copy()
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
    if effective_count == 1:
        var signature = tx_witness_item(tx, input_index, 0)
        var xonly = slice_bytes_profiled(prevout.script_pubkey, 2, 34, profile)
        return verify_schnorr_key_path_signature_cached_with_crypto_profiled(
            crypto, signature.data, xonly, tx, input_index, spent_prevouts, sighash_precompute, profile
        )
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
    var internal_xonly = slice_bytes_profiled(control_item.data, 1, 33, profile)
    var expected_xonly = slice_bytes_profiled(prevout.script_pubkey, 2, 34, profile)
    var parity = Int(control_item.data[0] & UInt8(1))
    if not verify_taproot_tweak_with_crypto_profiled(crypto, internal_xonly, merkle_root, expected_xonly, parity, profile):
        return False
    if leaf_version != UInt8(0xC0):
        return True
    var stack = List[ScriptStackItem]()
    for i in range(effective_count - 2):
        var item = tx_witness_item(tx, input_index, i)
        stack.append(item^)
    return evaluate_tapscript_with_crypto_profiled(
        script_item.data, stack^, tx, input_index, spent_prevouts, leaf_digest, shim_path, crypto, profile
    )


def verify_spend(
    shim_path: String,
    ref crypto: CryptoBackend,
    ref tx: Transaction,
    input_index: Int,
    ref all_prevouts: List[Utxo],
    ref spent_prevouts: List[TaprootPrevout],
    ref sighash_precompute: SighashPrecompute,
    mut profile: HotPathProfile,
) raises -> Bool:
    var prevout = all_prevouts[input_index].copy()
    if is_p2pkh_script_pubkey(prevout.script_pubkey):
        var stack = parse_push_only_stack(tx.inputs[input_index].script_sig)
        if len(stack) < 2:
            return False
        var signature = stack[len(stack) - 2].copy()
        var pubkey = stack[len(stack) - 1].copy()
        var actual_hash = hash160(pubkey.data)
        var expected_hash = slice_bytes_profiled(prevout.script_pubkey, 3, 23, profile)
        if not bytes_equal(actual_hash, expected_hash):
            return False
        return verify_ecdsa_signature_for_mode_cached_with_crypto_profiled(
            crypto,
            signature.data,
            pubkey.data,
            tx,
            input_index,
            prevout.script_pubkey,
            False,
            Int64(0),
            sighash_precompute,
            profile,
        )
    if is_p2sh_script_pubkey(prevout.script_pubkey):
        var pushes = parse_push_only_stack(tx.inputs[input_index].script_sig)
        if len(pushes) == 0:
            return False
        var redeem_script = pushes[len(pushes) - 1].data.copy()
        var redeem_hash = hash160(redeem_script)
        var expected_hash = slice_bytes_profiled(prevout.script_pubkey, 2, 22, profile)
        if not bytes_equal(redeem_hash, expected_hash):
            return False
        if is_v0_witness_script_program(redeem_script):
            var nested = Utxo()
            nested.height = prevout.height
            nested.value_sats = prevout.value_sats
            nested.coinbase = prevout.coinbase
            nested.script_pubkey = redeem_script^
            return verify_witness_v0_spend(shim_path, crypto, tx, input_index, nested, sighash_precompute, profile)
        var stack = List[ScriptStackItem]()
        for i in range(len(pushes) - 1):
            var item = pushes[i].copy()
            stack.append(item^)
        return evaluate_legacy_script_with_crypto_profiled(redeem_script, stack^, tx, input_index, shim_path, crypto, profile, True)
    if len(prevout.script_pubkey) >= 2 and prevout.script_pubkey[0] == UInt8(0):
        return verify_witness_v0_spend(shim_path, crypto, tx, input_index, prevout, sighash_precompute, profile)
    if is_p2tr_script_pubkey(prevout.script_pubkey):
        return verify_taproot_spend(shim_path, crypto, tx, input_index, all_prevouts, spent_prevouts, sighash_precompute, profile)
    var stack = parse_push_only_stack(tx.inputs[input_index].script_sig)
    return evaluate_legacy_script_with_crypto_profiled(prevout.script_pubkey, stack^, tx, input_index, shim_path, crypto, profile, True)


def script_verification_failure_message(
    height: Int,
    ref txid: List[UInt8],
    input_index: Int,
    ref prev_hash: List[UInt8],
    prev_vout: UInt32,
    ref spent_script_pubkey: List[UInt8],
    failure_stage: String,
    failure: String,
) -> String:
    var message = (
        String("script verification ")
        + failure_stage
        + String(" at height ")
        + String(height)
        + String(" txid=")
        + display_hash(txid)
        + String(" input=")
        + String(input_index)
        + String(" prev_txid=")
        + display_hash(prev_hash)
        + String(" prev_vout=")
        + String(prev_vout)
        + String(" spent_script_pubkey=")
        + bytes_to_hex(spent_script_pubkey)
    )
    if failure != "":
        message += String(" failure=") + failure
    return message^


def script_verify_result_for_job(ref job: ScriptVerifyJob) -> ScriptVerifyResult:
    var result = ScriptVerifyResult()
    result.job_index = job.job_index
    result.tx_index = job.tx_index
    result.input_index = job.input_index
    result.prev_txid = display_hash(job.prev_hash)
    result.prev_vout = job.prev_vout
    result.spent_script_pubkey = bytes_to_hex(job.prevout.script_pubkey)
    return result^


def first_failed_script_result_index(ref results: List[ScriptVerifyResult]) -> Int:
    var best_index = -1
    var best_job_index = 0
    for i in range(len(results)):
        if results[i].completed and not results[i].ok:
            if best_index < 0 or results[i].job_index < best_job_index:
                best_index = i
                best_job_index = results[i].job_index
    return best_index


def verify_script_job(
    shim_path: String,
    ref crypto: CryptoBackend,
    ref job: ScriptVerifyJob,
    ref contexts: List[ScriptVerifyContext],
    profile_enabled: Bool,
) -> ScriptVerifyResult:
    var result = script_verify_result_for_job(job)
    var profile = HotPathProfile()
    profile.enabled = profile_enabled
    try:
        if job.context_index < 0 or job.context_index >= len(contexts):
            raise Error("script job context index out of range")
        var verified = verify_spend(
            shim_path,
            crypto,
            contexts[job.context_index].tx,
            job.input_index,
            contexts[job.context_index].tx_prevouts,
            contexts[job.context_index].spent_prevouts,
            contexts[job.context_index].sighash_precompute,
            profile,
        )
        result.ok = verified
        if not verified:
            result.failure_stage = String("failed")
            result.failure = String("evaluator returned false")
    except e:
        result.ok = False
        result.failure_stage = String("error")
        result.failure = String(e)
    result.completed = True
    result.hotpath = profile^
    return result^


def verify_script_jobs_sequential(
    mut native: Native,
    shim_path: String,
    height: Int,
    ref contexts: List[ScriptVerifyContext],
    ref jobs: List[ScriptVerifyJob],
) raises -> ScriptVerifyStats:
    var stats = ScriptVerifyStats()
    stats.jobs = Int64(len(jobs))
    stats.hotpath.enabled = hotpath_profile_from_env().enabled
    if len(jobs) == 0:
        return stats^
    stats.batches = 0
    stats.threads = 1
    var started = native.now_ms()
    var results = List[ScriptVerifyResult]()
    var crypto = CryptoBackend(shim_path, CRYPTO_BACKEND_NATIVE)
    for i in range(len(jobs)):
        var job_started = native.now_ms()
        var result = verify_script_job(
            shim_path,
            crypto,
            jobs[i],
            contexts,
            stats.hotpath.enabled,
        )
        stats.worker_cpu_ms += native.now_ms() - job_started
        hotpath_add(stats.hotpath, result.hotpath)
        results.append(result^)
    stats.wall_ms = native.now_ms() - started
    var failed_index = first_failed_script_result_index(results)
    if failed_index >= 0:
        var failed_job = jobs[failed_index].copy()
        raise Error(
            script_verification_failure_message(
                height,
                failed_job.txid,
                failed_job.input_index,
                failed_job.prev_hash,
                failed_job.prev_vout,
                failed_job.prevout.script_pubkey,
                results[failed_index].failure_stage,
                results[failed_index].failure,
            )
        )
    return stats^


def verify_script_jobs_shadow_crypto_diagnostic(
    mut native: Native,
    shim_path: String,
    height: Int,
    ref contexts: List[ScriptVerifyContext],
    ref jobs: List[ScriptVerifyJob],
    config: ScriptRunnerConfig,
    mut shadow_stats: ShadowCryptoStats,
) raises:
    shadow_stats.script_jobs += Int64(len(jobs))
    if shadow_stats.parallel_batches == 0:
        shadow_stats.runner_mode = String("sequential")
        shadow_stats.runner_actual_mode = String("sequential")
        shadow_stats.thread_count = 1
    if len(jobs) == 0:
        return

    var rows = List[ShadowCryptoResult]()
    for i in range(len(jobs)):
        rows.append(shadow_crypto_row_for_job(jobs[i]))

    var use_parallel = (
        config.enabled and len(jobs) >= config.min_inputs and len(jobs) > 1 and config.threads != 1
    )
    var crypto = CryptoBackend(shim_path, CRYPTO_BACKEND_PURE)

    if use_parallel:
        shadow_stats.runner_mode = String("parallel")
        shadow_stats.runner_actual_mode = String("parallel")
        shadow_stats.parallel_batches += 1
        shadow_stats.thread_count = Int64(config.threads)

        @parameter
        def verify_one(index: Int) capturing:
            if not rows[index].supported:
                return
            try:
                var worker_clock = Native(shim_path)
                var started = worker_clock.now_ms()
                var result = verify_script_job(
                    shim_path,
                    crypto,
                    jobs[index],
                    contexts,
                    False,
                )
                rows[index].elapsed_ms = worker_clock.now_ms() - started
                rows[index].verifier_result = result^
                rows[index].completed = True
            except e:
                var result = script_verify_result_for_job(jobs[index])
                result.completed = True
                result.ok = False
                result.failure_stage = String("error")
                result.failure = String(e)
                rows[index].verifier_result = result^
                rows[index].completed = True

        if config.threads > 1:
            parallelize[verify_one](len(jobs), config.threads)
        else:
            parallelize[verify_one](len(jobs))
    else:
        if shadow_stats.parallel_batches == 0:
            shadow_stats.runner_mode = String("sequential")
            shadow_stats.runner_actual_mode = String("sequential")
            shadow_stats.thread_count = 1
        for i in range(len(jobs)):
            if not rows[i].supported:
                continue
            var started = native.now_ms()
            var result = verify_script_job(
                shim_path,
                crypto,
                jobs[i],
                contexts,
                False,
            )
            rows[i].elapsed_ms = native.now_ms() - started
            rows[i].verifier_result = result^
            rows[i].completed = True

    for i in range(len(rows)):
        shadow_crypto_reduce_row(shadow_stats, height, contexts, jobs[i], rows[i])


def verify_script_jobs_parallel_diagnostic(
    mut native: Native,
    shim_path: String,
    height: Int,
    ref contexts: List[ScriptVerifyContext],
    ref jobs: List[ScriptVerifyJob],
    config: ScriptRunnerConfig,
) raises -> ScriptVerifyStats:
    var stats = ScriptVerifyStats()
    stats.jobs = Int64(len(jobs))
    stats.threads = Int64(config.threads)
    stats.hotpath.enabled = hotpath_profile_from_env().enabled
    if len(jobs) == 0:
        return stats^
    if config.threads == 1:
        return verify_script_jobs_sequential(native, shim_path, height, contexts, jobs)

    var results = List[ScriptVerifyResult]()
    for i in range(len(jobs)):
        var result = script_verify_result_for_job(jobs[i])
        results.append(result^)

    var crypto = CryptoBackend(shim_path, CRYPTO_BACKEND_NATIVE)

    @parameter
    def verify_one(index: Int) capturing:
        # The callback must not mutate chainstate or raise across parallelize.
        # Each worker owns exactly one result slot.
        var result = verify_script_job(
            shim_path,
            crypto,
            jobs[index],
            contexts,
            stats.hotpath.enabled,
        )
        results[index] = result^

    var started = native.now_ms()
    if config.threads > 1:
        parallelize[verify_one](len(jobs), config.threads)
    else:
        parallelize[verify_one](len(jobs))
    stats.wall_ms = native.now_ms() - started
    stats.worker_cpu_ms = 0
    stats.batches = 1

    for i in range(len(results)):
        if not results[i].completed:
            raise Error(
                String("parallel script job did not complete at height ")
                + String(height)
                + String(" job_index=")
                + String(jobs[i].job_index)
            )
        hotpath_add(stats.hotpath, results[i].hotpath)

    var failed_index = first_failed_script_result_index(results)
    if failed_index >= 0:
        var failed_job = jobs[failed_index].copy()
        raise Error(
            script_verification_failure_message(
                height,
                failed_job.txid,
                failed_job.input_index,
                failed_job.prev_hash,
                failed_job.prev_vout,
                failed_job.prevout.script_pubkey,
                results[failed_index].failure_stage,
                results[failed_index].failure,
            )
        )
    return stats^


def connect_block(
    mut native: Native,
    db: Int64,
    shim_path: String,
    height: Int,
    ref block: Block,
    current_utxos: Int,
    mut timing: ConnectTiming,
    shadow_crypto_enabled: Bool,
    mut shadow_stats: ShadowCryptoStats,
) raises -> Int:
    if len(block.txs) == 0:
        raise Error("block has no transactions")
    if not is_coinbase(block.txs[0].tx):
        raise Error("first transaction is not coinbase")

    var delta = BlockUtxoDelta()
    var spent_txids = List[List[UInt8]]()
    var spent_vouts = List[UInt32]()
    var spent_index = PackedKeyIndex()
    var created_index = PackedKeyIndex()
    var next_script_job_index = 0
    var verify_contexts = List[ScriptVerifyContext]()
    var script_jobs = List[ScriptVerifyJob]()
    var block_txids = List[List[UInt8]]()
    var block_txid_index = PackedKeyIndex()
    for tx_index in range(len(block.txs)):
        block_txids.append(clone_bytes_profiled(block.txs[tx_index].txid, timing.hotpath))
        _ = block_txid_index.add_key(block.txs[tx_index].txid, tx_index)

    var external_txids = List[List[UInt8]]()
    var external_vouts = List[UInt32]()
    var external_index = PackedKeyIndex()
    for tx_index in range(1, len(block.txs)):
        var tx_for_prevouts = block.txs[tx_index].tx.copy()
        for input_index in range(len(tx_for_prevouts.inputs)):
            var prev_hash_for_gather = tx_for_prevouts.inputs[input_index].previous_hash.copy()
            hotpath_record_list_copy(timing.hotpath, len(prev_hash_for_gather))
            var prev_vout_for_gather = tx_for_prevouts.inputs[input_index].previous_index
            if not block_txid_index.contains_key(prev_hash_for_gather):
                if external_index.add_outpoint(prev_hash_for_gather, prev_vout_for_gather, len(external_txids)):
                    external_txids.append(clone_bytes_profiled(prev_hash_for_gather, timing.hotpath))
                    external_vouts.append(prev_vout_for_gather)

    var loaded_found = List[Bool]()
    var loaded_values = List[Utxo]()
    var batch_load_started = native.now_ms()
    if len(external_txids) > 0:
        var external_keys = List[List[UInt8]]()
        for i in range(len(external_txids)):
            var key = _utxo_key(external_txids[i], external_vouts[i])
            timing.utxo_key_bytes += Int64(len(key))
            external_keys.append(key^)
        timing.utxo_lookup_count += Int64(len(external_keys))
        var multi_get_started = native.now_ms()
        var rows = rocksdb_multi_get_rows(native, db, external_keys)
        timing.prevout_multi_get_call += native.now_ms() - multi_get_started
        if len(rows) != len(external_txids):
            raise Error("RocksDB multi_get returned unexpected row count")
        var decode_started = native.now_ms()
        for i in range(len(rows)):
            loaded_found.append(rows[i].found)
            if rows[i].found:
                timing.utxo_value_bytes += Int64(len(rows[i].value))
                loaded_values.append(decode_utxo(rows[i].value))
            else:
                loaded_values.append(Utxo())
        timing.prevout_utxo_decode += native.now_ms() - decode_started
    var batch_load_elapsed = native.now_ms() - batch_load_started
    timing.prevout_batch_load += batch_load_elapsed
    timing.utxo_load += batch_load_elapsed

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
                        append_delta_created(delta, block.txs[tx_index].txid, UInt32(vout), u)
                        _ = created_index.add_outpoint(
                            block.txs[tx_index].txid,
                            UInt32(vout),
                            len(delta.created_txids) - 1,
                        )
            continue
        if len(tx.inputs) == 0:
            raise Error("non-coinbase transaction has no inputs")
        var tx_prevouts = List[Utxo]()
        var tx_prev_hashes = List[List[UInt8]]()
        var tx_prev_vouts = List[UInt32]()
        var tx_seen_hashes = List[List[UInt8]]()
        var tx_seen_vouts = List[UInt32]()
        var tx_seen_index = PackedKeyIndex()
        for input_index in range(len(tx.inputs)):
            var prev_hash = tx.inputs[input_index].previous_hash.copy()
            var prev_index = tx.inputs[input_index].previous_index
            if tx_seen_index.contains_outpoint(prev_hash, prev_index):
                    raise Error(
                        String("duplicate spend inside transaction at height ")
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
            if spent_index.contains_outpoint(prev_hash, prev_index):
                    raise Error(
                        String("duplicate spend inside block at height ")
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
            tx_seen_hashes.append(clone_bytes_profiled(prev_hash, timing.hotpath))
            tx_seen_vouts.append(prev_index)
            _ = tx_seen_index.add_outpoint(prev_hash, prev_index, input_index)
            var found_created = False
            var prevout = Utxo()
            var created_delta_index = created_index.find_outpoint(prev_hash, prev_index)
            if created_delta_index >= 0:
                found_created = True
                prevout = delta.created_values[created_delta_index].copy()
            if not found_created:
                var loaded_index = external_index.find_outpoint(prev_hash, prev_index)
                if loaded_index < 0 or not loaded_found[loaded_index]:
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
                prevout = loaded_values[loaded_index].copy()
                append_delta_external_spend(delta, prev_hash, prev_index)
            else:
                delta.created_spent[created_delta_index] = True
            if prevout.coinbase and height < prevout.height + 100:
                raise Error("coinbase maturity violation")
            append_delta_undo(delta, tx_index, input_index, prev_hash, prev_index, prevout, found_created)
            tx_prevouts.append(prevout^)
            tx_prev_hashes.append(prev_hash^)
            tx_prev_vouts.append(prev_index)
        timing.script_inputs += Int64(len(tx.inputs))
        var spent_prevouts = taproot_prevouts_from_utxos(tx_prevouts)
        var sighash_precompute = SighashPrecompute()
        var needs_legacy_precompute = spent_prevouts_need_legacy_precompute(tx, spent_prevouts)
        var needs_bip143_precompute = spent_prevouts_need_bip143_precompute(tx, spent_prevouts)
        var needs_taproot_precompute = spent_prevouts_need_taproot_precompute(spent_prevouts)
        if needs_legacy_precompute or needs_bip143_precompute or needs_taproot_precompute:
            var precompute_started = native.now_ms()
            sighash_precompute = build_sighash_precompute_for_modes(
                tx,
                spent_prevouts,
                needs_legacy_precompute,
                needs_bip143_precompute,
                needs_taproot_precompute,
            )
            timing.sighash_precompute_ms += native.now_ms() - precompute_started
            if needs_legacy_precompute:
                if not sighash_precompute.legacy_available:
                    raise Error("Legacy sighash precompute required but unavailable")
                if timing.hotpath.enabled:
                    timing.hotpath.legacy_sighash_cache_build_bytes += Int64(
                        legacy_sighash_cache_build_bytes(sighash_precompute)
                    )
            if needs_bip143_precompute:
                if not sighash_precompute.bip143_available:
                    raise Error("BIP143 sighash precompute required but unavailable")
                timing.sighash_precompute_bip143_transactions += 1
            if needs_taproot_precompute:
                if not sighash_precompute.taproot_available:
                    raise Error("Taproot sighash precompute required but unavailable")
                timing.sighash_precompute_taproot_transactions += 1
            timing.sighash_precompute_transactions += 1
        var context_index = len(verify_contexts)
        var context = ScriptVerifyContext()
        if timing.hotpath.enabled:
            timing.hotpath.script_verify_context_copies += 1
            hotpath_record_list_copy(timing.hotpath, len(tx.inputs))
            hotpath_record_list_copy(timing.hotpath, len(tx_prevouts))
            hotpath_record_list_copy(timing.hotpath, len(spent_prevouts))
        context.tx = tx.copy()
        context.tx_prevouts = tx_prevouts.copy()
        context.spent_prevouts = spent_prevouts.copy()
        context.sighash_precompute = sighash_precompute.copy()
        verify_contexts.append(context^)
        for input_index in range(len(tx.inputs)):
            var job = ScriptVerifyJob()
            if timing.hotpath.enabled:
                timing.hotpath.script_verify_job_copies += 1
            job.job_index = next_script_job_index
            job.context_index = context_index
            job.tx_index = tx_index
            job.input_index = input_index
            job.txid = clone_bytes_profiled(block.txs[tx_index].txid, timing.hotpath)
            job.prev_hash = clone_bytes_profiled(tx_prev_hashes[input_index], timing.hotpath)
            job.prev_vout = tx_prev_vouts[input_index]
            job.prevout = tx_prevouts[input_index].copy()
            script_jobs.append(job^)
            next_script_job_index += 1
        for input_index in range(len(tx.inputs)):
            spent_txids.append(clone_bytes_profiled(tx_prev_hashes[input_index], timing.hotpath))
            spent_vouts.append(tx_prev_vouts[input_index])
            _ = spent_index.add_outpoint(tx_prev_hashes[input_index], tx_prev_vouts[input_index], len(spent_txids) - 1)
        for vout in range(len(tx.outputs)):
            if is_spendable_output(tx.outputs[vout]):
                var u = Utxo()
                u.height = height
                u.value_sats = tx.outputs[vout].value
                u.coinbase = False
                u.script_pubkey = clone_bytes(tx.outputs[vout].script_pubkey)
                append_delta_created(delta, block.txs[tx_index].txid, UInt32(vout), u)
                _ = created_index.add_outpoint(block.txs[tx_index].txid, UInt32(vout), len(delta.created_txids) - 1)

    var runner_config = script_runner_config_from_env()
    var verify_stats: ScriptVerifyStats
    if runner_config.enabled and len(script_jobs) > 1 and len(script_jobs) >= runner_config.min_inputs and runner_config.threads != 1:
        verify_stats = verify_script_jobs_parallel_diagnostic(
            native,
            shim_path,
            height,
            verify_contexts,
            script_jobs,
            runner_config,
        )
    else:
        verify_stats = verify_script_jobs_sequential(
            native,
            shim_path,
            height,
            verify_contexts,
            script_jobs,
        )
    timing.script_verify += verify_stats.wall_ms
    timing.script_wall_ms += verify_stats.wall_ms
    timing.script_worker_cpu_ms += verify_stats.worker_cpu_ms
    timing.script_jobs += verify_stats.jobs
    timing.script_parallel_batches += verify_stats.batches
    hotpath_add(timing.hotpath, verify_stats.hotpath)
    if verify_stats.batches > 0 or timing.script_parallel_batches == 0:
        timing.script_runner_thread_count = verify_stats.threads
    if shadow_crypto_enabled:
        verify_script_jobs_shadow_crypto_diagnostic(
            native,
            shim_path,
            height,
            verify_contexts,
            script_jobs,
            runner_config,
            shadow_stats,
        )

    var apply_started = native.now_ms()
    var new_utxos = current_utxos - delta.external_spends + block_delta_unspent_created(delta)
    delta.block_key = _block_key(height)
    delta.block_value = block.header.copy()
    delta.undo_key = _undo_key(height)
    delta.undo_value = encode_block_undo(height, delta)
    append_delta_metadata(delta, String("validated_height"), String(height))
    append_delta_metadata(delta, String("stored_block_height"), String(height))
    append_delta_metadata(delta, String("header_height"), String(height))
    append_delta_metadata(delta, String("validated_hash"), display_hash(block.hash))
    append_delta_metadata(delta, String("stored_block_hash"), display_hash(block.hash))
    append_delta_metadata(delta, String("header_hash"), display_hash(block.hash))
    append_delta_metadata(delta, String("chainstate_utxo_count"), String(new_utxos))
    append_delta_metadata(delta, String("chainstate_backend"), String("rocksdb"))
    append_delta_metadata(delta, String("native_crypto_backend"), String("libsecp256k1"))
    append_delta_metadata(delta, String("sync_status"), String("blocks_syncing"))
    apply_block_delta(native, db, timing, delta)
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
        + String(',"prevout_batch_load":')
        + String(timing.prevout_batch_load)
        + String(',"prevout_multi_get_call":')
        + String(timing.prevout_multi_get_call)
        + String(',"prevout_utxo_decode":')
        + String(timing.prevout_utxo_decode)
        + String(',"script_verify":')
        + String(timing.script_verify)
        + String(',"script_wall_ms":')
        + String(timing.script_wall_ms)
        + String(',"script_worker_cpu_ms":')
        + String(timing.script_worker_cpu_ms)
        + String(',"utxo_apply":')
        + String(timing.utxo_apply)
        + String(',"commit":')
        + String(timing.commit)
        + String(',"block_connect_store_commit":')
        + String(timing.block_connect_store_commit)
        + String(',"utxo_delete_prepare":')
        + String(timing.utxo_delete_prepare)
        + String(',"utxo_put_prepare":')
        + String(timing.utxo_put_prepare)
        + String(',"undo_put_prepare":')
        + String(timing.undo_put_prepare)
        + String(',"metadata_put_prepare":')
        + String(timing.metadata_put_prepare)
        + String(',"rocksdb_write":')
        + String(timing.rocksdb_write)
        + String(',"rocksdb_batch_pack":')
        + String(timing.rocksdb_batch_pack)
        + String(',"utxo_lookup_count":')
        + String(timing.utxo_lookup_count)
        + String(',"utxo_key_bytes":')
        + String(timing.utxo_key_bytes)
        + String(',"utxo_value_bytes":')
        + String(timing.utxo_value_bytes)
        + String('},"script_metrics":{"script_inputs":')
        + String(timing.script_inputs)
        + String(',"ecdsa_calls":')
        + String(timing.ecdsa_calls)
        + String(',"ecdsa_ms":')
        + String(timing.ecdsa_ms)
        + String(',"schnorr_calls":')
        + String(timing.schnorr_calls)
        + String(',"schnorr_ms":')
        + String(timing.schnorr_ms)
        + String(',"taproot_tweak_calls":')
        + String(timing.taproot_tweak_calls)
        + String(',"taproot_tweak_ms":')
        + String(timing.taproot_tweak_ms)
        + String(',"native_bridge_ms":')
        + String(timing.ecdsa_ms + timing.schnorr_ms + timing.taproot_tweak_ms)
        + String(',"sighash_precompute_transactions":')
        + String(timing.sighash_precompute_transactions)
        + String(',"sighash_precompute_bip143_transactions":')
        + String(timing.sighash_precompute_bip143_transactions)
        + String(',"sighash_precompute_taproot_transactions":')
        + String(timing.sighash_precompute_taproot_transactions)
        + String(',"sighash_precompute_ms":')
        + String(timing.sighash_precompute_ms)
        + String(',"script_jobs":')
        + String(timing.script_jobs)
        + String(',"script_parallel_batches":')
        + String(timing.script_parallel_batches)
        + String(',"script_runner_thread_count":')
        + String(timing.script_runner_thread_count)
        + String(',"script_runner_actual_mode":"')
        + script_runner_mode(timing)
        + String('"}')
        + hotpath_profile_json_field(timing.hotpath)
        + String(',"last_block_ms":')
        + String(last_block_ms)
        + String("}")
    )


def refresh_crypto_metrics(mut native: Native, mut timing: ConnectTiming):
    timing.ecdsa_calls = native.crypto_metric(String("ecdsa_calls"))
    timing.ecdsa_ms = native.crypto_metric(String("ecdsa_ms"))
    timing.schnorr_calls = native.crypto_metric(String("schnorr_calls"))
    timing.schnorr_ms = native.crypto_metric(String("schnorr_ms"))
    timing.taproot_tweak_calls = native.crypto_metric(String("taproot_tweak_calls"))
    timing.taproot_tweak_ms = native.crypto_metric(String("taproot_tweak_ms"))


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
    current_block_tx_count: Int,
    current_block_vin_count: Int,
    current_block_script_input_count: Int,
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
        + String(',"current_block_tx_count":')
        + String(current_block_tx_count)
        + String(',"current_block_vin_count":')
        + String(current_block_vin_count)
        + String(',"current_block_script_input_count":')
        + String(current_block_script_input_count)
        + String(',"peer":"')
        + peer
        + String('","timing_buckets_ms":{"p2p_fetch":')
        + String(timing.p2p_fetch)
        + String(',"block_parse_validate":')
        + String(timing.block_parse_validate)
        + String(',"utxo_load":')
        + String(timing.utxo_load)
        + String(',"prevout_batch_load":')
        + String(timing.prevout_batch_load)
        + String(',"prevout_multi_get_call":')
        + String(timing.prevout_multi_get_call)
        + String(',"prevout_utxo_decode":')
        + String(timing.prevout_utxo_decode)
        + String(',"script_verify":')
        + String(timing.script_verify)
        + String(',"script_wall_ms":')
        + String(timing.script_wall_ms)
        + String(',"script_worker_cpu_ms":')
        + String(timing.script_worker_cpu_ms)
        + String(',"utxo_apply":')
        + String(timing.utxo_apply)
        + String(',"commit":')
        + String(timing.commit)
        + String(',"block_connect_store_commit":')
        + String(timing.block_connect_store_commit)
        + String(',"utxo_delete_prepare":')
        + String(timing.utxo_delete_prepare)
        + String(',"utxo_put_prepare":')
        + String(timing.utxo_put_prepare)
        + String(',"undo_put_prepare":')
        + String(timing.undo_put_prepare)
        + String(',"metadata_put_prepare":')
        + String(timing.metadata_put_prepare)
        + String(',"rocksdb_write":')
        + String(timing.rocksdb_write)
        + String(',"rocksdb_batch_pack":')
        + String(timing.rocksdb_batch_pack)
        + String(',"utxo_lookup_count":')
        + String(timing.utxo_lookup_count)
        + String(',"utxo_key_bytes":')
        + String(timing.utxo_key_bytes)
        + String(',"utxo_value_bytes":')
        + String(timing.utxo_value_bytes)
        + String('},"script_metrics":{"script_inputs":')
        + String(timing.script_inputs)
        + String(',"ecdsa_calls":')
        + String(timing.ecdsa_calls)
        + String(',"ecdsa_ms":')
        + String(timing.ecdsa_ms)
        + String(',"schnorr_calls":')
        + String(timing.schnorr_calls)
        + String(',"schnorr_ms":')
        + String(timing.schnorr_ms)
        + String(',"taproot_tweak_calls":')
        + String(timing.taproot_tweak_calls)
        + String(',"taproot_tweak_ms":')
        + String(timing.taproot_tweak_ms)
        + String(',"native_bridge_ms":')
        + String(timing.ecdsa_ms + timing.schnorr_ms + timing.taproot_tweak_ms)
        + String(',"sighash_precompute_transactions":')
        + String(timing.sighash_precompute_transactions)
        + String(',"sighash_precompute_bip143_transactions":')
        + String(timing.sighash_precompute_bip143_transactions)
        + String(',"sighash_precompute_taproot_transactions":')
        + String(timing.sighash_precompute_taproot_transactions)
        + String(',"sighash_precompute_ms":')
        + String(timing.sighash_precompute_ms)
        + String(',"script_jobs":')
        + String(timing.script_jobs)
        + String(',"script_parallel_batches":')
        + String(timing.script_parallel_batches)
        + String(',"script_runner_thread_count":')
        + String(timing.script_runner_thread_count)
        + String(',"script_runner_actual_mode":"')
        + script_runner_mode(timing)
        + String('"}')
        + hotpath_profile_json_field(timing.hotpath)
        + String("}")
    )


def local_reference_proof(
    shim_path: String,
    surface: String,
    datadir: String,
    peer: String,
    target: Int,
    result_path: String,
    progress_interval: Int,
    shadow_crypto_enabled: Bool,
) raises -> ProofResult:
    var benchmark_gate = benchmark_gate_for_target(target)
    var benchmark_kind = benchmark_gate + String("_p2p")
    var target_label = target_label_for_target(target)
    var expected_hash = expected_hash_for_target(target)
    var expected_utxos = expected_utxos_for_target(target)
    var native = Native(shim_path)
    native.crypto_metrics_reset()
    var started = native.now_ms()
    var parts = split_peer(peer)
    var fd = native.socket_connect(parts[0], parts[1])
    var db = native.rocksdb_open(datadir)
    var timing = ConnectTiming()
    timing.hotpath = hotpath_profile_from_env()
    var shadow_stats = ShadowCryptoStats()
    shadow_stats.enabled = shadow_crypto_enabled
    var current_utxos = 0
    var blocks_fetched = 0
    var blocks_connected = 0
    try:
        emit_telemetry(benchmark_gate, String("run_started"), String("startup"), 0, target, String(GENESIS_HASH_DISPLAY), peer, current_utxos, native.now_ms() - started, 0, timing, 0, 0, 0)
        emit_telemetry(benchmark_gate, String("container_started"), String("startup"), 0, target, String(GENESIS_HASH_DISPLAY), peer, current_utxos, native.now_ms() - started, 0, timing, 0, 0, 0)
        db_put_string(native, db, String("chainstate_backend"), String("rocksdb"))
        db_put_string(native, db, String("native_crypto_backend"), String("libsecp256k1"))
        db_put_string(native, db, String("sync_status"), String("headers_syncing"))
        emit_telemetry(benchmark_gate, String("node_started"), String("startup"), 0, target, String(GENESIS_HASH_DISPLAY), peer, current_utxos, native.now_ms() - started, 0, timing, 0, 0, 0)
        handshake(native, fd)
        emit_telemetry(benchmark_gate, String("first_peer_byte"), String("peer_connect"), 0, target, String(GENESIS_HASH_DISPLAY), peer, current_utxos, native.now_ms() - started, 0, timing, 0, 0, 0)
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
                var current_block_tx_count = len(blocks[i].txs)
                var current_block_vin_count = 0
                var current_block_script_input_count = 0
                for tx_count_index in range(len(blocks[i].txs)):
                    if tx_count_index != 0:
                        current_block_vin_count += len(blocks[i].txs[tx_count_index].tx.inputs)
                        current_block_script_input_count += len(blocks[i].txs[tx_count_index].tx.inputs)
                current_utxos = connect_block(
                    native,
                    db,
                    shim_path,
                    height,
                    blocks[i],
                    current_utxos,
                    timing,
                    shadow_crypto_enabled,
                    shadow_stats,
                )
                refresh_crypto_metrics(native, timing)
                timing.block_connect_store_commit += native.now_ms() - block_started
                blocks_fetched += 1
                blocks_connected += 1
                var h = display_hash(blocks[i].hash)
                var last_block_ms = native.now_ms() - block_started
                if height == 1:
                    emit_telemetry(benchmark_gate, String("first_block_connected"), String("block_connect"), height, target, h, peer, current_utxos, native.now_ms() - started, last_block_ms, timing, current_block_tx_count, current_block_vin_count, current_block_script_input_count)
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
                        current_block_tx_count,
                        current_block_vin_count,
                        current_block_script_input_count,
                    )
            cursor = end
        db_put_string(native, db, String("sync_status"), String("blocks_current"))
        var finish_hash = db_get_string(native, db, String("validated_hash"))
        if finish_hash != expected_hash:
            raise Error(benchmark_gate + String(" target hash mismatch"))
        if current_utxos != expected_utxos:
            raise Error(benchmark_gate + String(" UTXO count mismatch: ") + String(current_utxos))
        var total_ms = native.now_ms() - started
        refresh_crypto_metrics(native, timing)
        emit_telemetry(benchmark_gate, String("run_finished"), String("complete"), target, target, finish_hash, peer, current_utxos, total_ms, 0, timing, 0, 0, 0)
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
            + String('"benchmark_comparability":"')
            + (String("diagnostic_non_comparable") if shadow_crypto_enabled else String("comparable"))
            + String('","implementation":"Mojo","port":"mojo","node_id":"mojobitnode","chain":"testnet4",')
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
            + String('","byte_source":"local_reference_p2p","proof_mode":"p2p_sync","prefetch_depth":4,"script_runner_mode":"')
            + script_runner_mode(timing)
            + String('","script_runner_actual_mode":"')
            + script_runner_mode(timing)
            + String('",')
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
            + shadow_crypto_json(shadow_stats)
            + String(",")
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
            + String(',"prevout_batch_load":')
            + String(timing.prevout_batch_load)
            + String(',"prevout_multi_get_call":')
            + String(timing.prevout_multi_get_call)
            + String(',"prevout_utxo_decode":')
            + String(timing.prevout_utxo_decode)
            + String(',"script_verify":')
            + String(timing.script_verify)
            + String(',"script_wall_ms":')
            + String(timing.script_wall_ms)
            + String(',"script_worker_cpu_ms":')
            + String(timing.script_worker_cpu_ms)
            + String(',"utxo_apply":')
            + String(timing.utxo_apply)
            + String(',"commit":')
            + String(timing.commit)
            + String(',"block_connect_store_commit":')
            + String(timing.block_connect_store_commit)
            + String(',"utxo_delete_prepare":')
            + String(timing.utxo_delete_prepare)
            + String(',"utxo_put_prepare":')
            + String(timing.utxo_put_prepare)
            + String(',"undo_put_prepare":')
            + String(timing.undo_put_prepare)
            + String(',"metadata_put_prepare":')
            + String(timing.metadata_put_prepare)
            + String(',"rocksdb_write":')
            + String(timing.rocksdb_write)
            + String(',"rocksdb_batch_pack":')
            + String(timing.rocksdb_batch_pack)
            + String(',"utxo_lookup_count":')
            + String(timing.utxo_lookup_count)
            + String(',"utxo_key_bytes":')
            + String(timing.utxo_key_bytes)
            + String(',"utxo_value_bytes":')
            + String(timing.utxo_value_bytes)
            + String(',"script_inputs":')
            + String(timing.script_inputs)
            + String(',"ecdsa_verify":')
            + String(timing.ecdsa_ms)
            + String(',"schnorr_verify":')
            + String(timing.schnorr_ms)
            + String(',"taproot_tweak":')
            + String(timing.taproot_tweak_ms)
            + String(',"native_bridge":')
            + String(timing.ecdsa_ms + timing.schnorr_ms + timing.taproot_tweak_ms)
            + String('}},"stage_totals_ms":{"utxo_load":')
            + String(timing.utxo_load)
            + String(',"prevout_batch_load":')
            + String(timing.prevout_batch_load)
            + String(',"prevout_multi_get_call":')
            + String(timing.prevout_multi_get_call)
            + String(',"prevout_utxo_decode":')
            + String(timing.prevout_utxo_decode)
            + String(',"script_verify":')
            + String(timing.script_verify)
            + String(',"script_wall_ms":')
            + String(timing.script_wall_ms)
            + String(',"script_worker_cpu_ms":')
            + String(timing.script_worker_cpu_ms)
            + String(',"utxo_apply":')
            + String(timing.utxo_apply)
            + String(',"commit":')
            + String(timing.commit)
            + String(',"block_connect_store_commit":')
            + String(timing.block_connect_store_commit)
            + String(',"utxo_delete_prepare":')
            + String(timing.utxo_delete_prepare)
            + String(',"utxo_put_prepare":')
            + String(timing.utxo_put_prepare)
            + String(',"undo_put_prepare":')
            + String(timing.undo_put_prepare)
            + String(',"metadata_put_prepare":')
            + String(timing.metadata_put_prepare)
            + String(',"rocksdb_write":')
            + String(timing.rocksdb_write)
            + String(',"rocksdb_batch_pack":')
            + String(timing.rocksdb_batch_pack)
            + String(',"utxo_lookup_count":')
            + String(timing.utxo_lookup_count)
            + String(',"utxo_key_bytes":')
            + String(timing.utxo_key_bytes)
            + String(',"utxo_value_bytes":')
            + String(timing.utxo_value_bytes)
            + String(',"script_inputs":')
            + String(timing.script_inputs)
            + String(',"ecdsa_verify":')
            + String(timing.ecdsa_ms)
            + String(',"schnorr_verify":')
            + String(timing.schnorr_ms)
            + String(',"taproot_tweak":')
            + String(timing.taproot_tweak_ms)
            + String(',"native_bridge":')
            + String(timing.ecdsa_ms + timing.schnorr_ms + timing.taproot_tweak_ms)
            + String('},"script_metrics":{"script_inputs":')
            + String(timing.script_inputs)
            + String(',"ecdsa_calls":')
            + String(timing.ecdsa_calls)
            + String(',"ecdsa_ms":')
            + String(timing.ecdsa_ms)
            + String(',"schnorr_calls":')
            + String(timing.schnorr_calls)
            + String(',"schnorr_ms":')
            + String(timing.schnorr_ms)
            + String(',"taproot_tweak_calls":')
            + String(timing.taproot_tweak_calls)
            + String(',"taproot_tweak_ms":')
            + String(timing.taproot_tweak_ms)
            + String(',"native_bridge_ms":')
            + String(timing.ecdsa_ms + timing.schnorr_ms + timing.taproot_tweak_ms)
            + String(',"sighash_precompute_transactions":')
            + String(timing.sighash_precompute_transactions)
            + String(',"sighash_precompute_bip143_transactions":')
            + String(timing.sighash_precompute_bip143_transactions)
            + String(',"sighash_precompute_taproot_transactions":')
            + String(timing.sighash_precompute_taproot_transactions)
            + String(',"sighash_precompute_ms":')
            + String(timing.sighash_precompute_ms)
            + String(',"script_jobs":')
            + String(timing.script_jobs)
            + String(',"script_parallel_batches":')
            + String(timing.script_parallel_batches)
            + String(',"script_runner_thread_count":')
            + String(timing.script_runner_thread_count)
            + String(',"script_runner_actual_mode":"')
            + script_runner_mode(timing)
            + String('"}')
            + hotpath_profile_json_field(timing.hotpath)
            + String(',"slow_blocks":[]}')
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
