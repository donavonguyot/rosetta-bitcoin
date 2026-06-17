from block_core import (
    BlockUtxoDelta,
    ConnectTiming,
    Native,
    PackedKeyIndex,
    ScriptVerifyResult,
    Utxo,
    _utxo_key,
    append_delta_created,
    append_delta_metadata,
    append_delta_undo,
    append_outpoint_if_missing,
    append_packed_batch_delete,
    append_packed_batch_put,
    apply_block_delta,
    block_delta_unspent_created,
    check_pow,
    contains_outpoint,
    db_get_string,
    db_put_string,
    decode_utxo,
    encode_utxo,
    encode_block_undo,
    find_created_delta_index,
    first_failed_script_result_index,
    hash_from_display,
    merkle_root,
    outpoint_index_key,
    parse_block,
    rocksdb_multi_get_rows,
    shadow_crypto_reduction_smoke,
)
from script_corpus_foundation import (
    CRYPTO_BACKEND_NATIVE,
    CRYPTO_BACKEND_PURE,
    CRYPTO_RESULT_CONSENSUS_INVALID,
    CRYPTO_RESULT_MALFORMED,
    CRYPTO_RESULT_UNSUPPORTED,
    CRYPTO_RESULT_VALID,
    CryptoBackend,
    HotPathProfile,
    ScriptStackItem,
    TaprootPrevout,
    Transaction,
    TxInput,
    TxOutput,
    append_bytes,
    append_u32_le,
    append_varint,
    ascii_string_to_bytes,
    build_sighash_precompute_for_modes,
    bytes_to_hex,
    clone_bytes_profiled,
    evaluate_legacy_script_with_crypto_profiled,
    hash160,
    hash256,
    hex_text_to_bytes,
    legacy_find_and_delete,
    legacy_sighash,
    legacy_sighash_cached_preimage,
    legacy_sighash_cached_profiled,
    legacy_sighash_preimage,
    legacy_sighash_cached,
    legacy_sighash_profiled,
    parse_transaction,
    read_hex_file,
    serialize_tx_output,
    slice_bytes,
    slice_bytes_profiled,
    tapleaf_hash,
    taproot_tweak_hash,
    verify_taproot_tweak,
)
from pure_secp import (
    pure_test_ecdsa_parse_der,
    pure_test_ecdsa_glv_product_x,
    pure_test_ecdsa_glv_result,
    pure_test_ecdsa_fe52_glv_product_x,
    pure_test_ecdsa_fe52_glv_result,
    pure_test_ecdsa_fe52_glv_max_len,
    pure_test_ecdsa_fe52_glv_old_max_len,
    pure_test_ecdsa_fe52_simd2_wnaf_mismatches,
    pure_test_ecdsa_fe52_simd2_wnaf_result,
    pure_test_ecdsa_fe52_simd4_wnaf_mismatches,
    pure_test_ecdsa_fe52_simd4_wnaf_product_x,
    pure_test_ecdsa_fe52_simd4_wnaf_result,
    pure_test_ecdsa_fe52_simd8_wnaf_mismatches,
    pure_test_ecdsa_fe52_simd8_wnaf_result,
    pure_test_ecdsa_fe52_simd16_wnaf_mismatches,
    pure_test_ecdsa_fe52_simd16_wnaf_result,
    pure_test_ecdsa_fe52_wnaf_result,
    pure_test_ecdsa_reference_product_x,
    pure_test_ecdsa_reference_result,
    pure_test_ecdsa_fe52_wnaf_product_x,
    pure_test_ecdsa_wnaf_product_x,
    pure_test_ecdsa_wnaf_result,
    pure_test_endo_split_not_high,
    pure_test_fe52_add,
    pure_test_fe52_equal,
    pure_test_fe52_is_zero,
    pure_test_fe52_mul,
    pure_test_fe52x2_add_lane,
    pure_test_fe52x2_mul_lane,
    pure_test_fe52x2_sqr_lane,
    pure_test_fe52x4_add_lane,
    pure_test_fe52x4_mul_lane,
    pure_test_fe52x4_sqr_lane,
    pure_test_fe52_mul_int,
    pure_test_fe52_generator_beta_table_matches,
    pure_test_fe52_pubkey_beta_table_matches,
    pure_test_fe52_roundtrip,
    pure_test_fe52_scalar_mul_g_x,
    pure_test_fe52_scalar_mul_g_y,
    pure_test_fe52_sqr,
    pure_test_fe52_sub_via_negate,
    pure_test_ecdsa_fe52_reference_product_x,
    pure_test_glv_constants,
    pure_test_generator_endo_split_not_high,
    pure_test_odd_multiples_match_generator,
    pure_test_odd_multiples_match_pubkey,
    pure_test_odd_multiples_match_xonly,
    pure_test_scalar_split_lambda_identity,
    pure_test_scalar_mul_g_is_infinity,
    pure_test_scalar_mul_g_x,
    pure_test_scalar_mul_g_y,
    pure_test_schnorr_challenge,
    pure_test_schnorr_fe52_wnaf_result,
    pure_test_schnorr_reference_result,
    pure_test_taproot_tweak_fe52_result,
    pure_test_taproot_tweak_reference_result,
    pure_test_u256_add_mod,
    pure_test_u256_inv_field_fast,
    pure_test_u256_inv_field_reference,
    pure_test_u256_inv_mod,
    pure_test_u256_mul_field_fast,
    pure_test_u256_mul_mod,
    pure_test_u256_mul_scalar_fast,
    pure_test_u256_sqrt_field_fast,
    pure_test_u256_sqrt_field_reference,
    pure_test_u256_square_field,
    pure_test_u256_sub_mod,
)
from std.collections import List
from std.os import getenv
from std.testing import assert_equal, assert_true, TestSuite


comptime FIRST_FIXTURE_TX = "../Shared/conformance/fixtures/scripts/scripts.bare_multisig_27840/tx_bare_multisig_27840.hex"
comptime TAPROOT_SCRIPTPATH_44295_SCRIPT = "../Shared/conformance/fixtures/scripts/scripts.p2tr_scriptpath_44295/tx_p2tr_scriptpath_44295_tapscript.hex"
comptime TAPROOT_SCRIPTPATH_44295_CONTROL = "../Shared/conformance/fixtures/scripts/scripts.p2tr_scriptpath_44295/tx_p2tr_scriptpath_44295_control_block.hex"
comptime TAPROOT_SCRIPTPATH_44295_PREV_SPK = "../Shared/conformance/fixtures/scripts/scripts.p2tr_scriptpath_44295/tx_p2tr_scriptpath_44295_prev_spk.hex"


def test_transaction_and_merkle_parse() raises:
    var tx_bytes = read_hex_file(FIRST_FIXTURE_TX)
    var tx = parse_transaction(tx_bytes.copy())
    assert_equal(len(tx.inputs), 1)
    assert_equal(len(tx.outputs), 1)
    var txid = hash256(tx_bytes)
    var header = List[UInt8]()
    for _ in range(80):
        header.append(UInt8(0))
    var merkle = txid.copy()
    for i in range(32):
        header[36 + i] = merkle[i]
    var block = List[UInt8]()
    append_bytes(block, header)
    append_varint(block, 1)
    append_bytes(block, tx_bytes)
    var parsed = parse_block(block)
    assert_equal(len(parsed.txs), 1)
    var root = merkle_root(parsed.txs)
    assert_equal(bytes_to_hex(root), bytes_to_hex(merkle))


def test_hash_and_pow_helpers() raises:
    var genesis = hash_from_display(String("00000000da84f2bafbbc53dee25a72ae507ff4914b867c565be350b0da8bf043"))
    assert_equal(bytes_to_hex(genesis), String("43f08bdab050e35b567c864b91f47f50ae725ae2de53bcfbbaf284da00000000"))
    assert_true(check_pow(genesis, UInt32(0x1D00FFFF)))


def test_utxo_codec() raises:
    var script = List[UInt8]()
    script.append(UInt8(0x76))
    script.append(UInt8(0xA9))
    script.append(UInt8(0x14))
    var payload = List[UInt8]()
    payload.append(UInt8(1))
    payload.append(UInt8(2))
    payload.append(UInt8(3))
    var h = hash160(payload)
    append_bytes(script, h)
    script.append(UInt8(0x88))
    script.append(UInt8(0xAC))
    var encoded = encode_utxo(101, Int64(5000000000), True, script)
    var decoded = decode_utxo(encoded)
    assert_equal(decoded.height, 101)
    assert_equal(decoded.value_sats, Int64(5000000000))
    assert_true(decoded.coinbase)
    assert_equal(bytes_to_hex(decoded.script_pubkey), bytes_to_hex(script))


def test_status_persistence() raises:
    var shim = getenv("MOJOBITNODE_SHIM_PATH", "./build/libmojobitnode_shim.dylib")
    var native = Native(shim)
    var db = native.rocksdb_open(String("/tmp/mojo_block_core_smoke"))
    db_put_string(native, db, String("validated_height"), String("5000"))
    db_put_string(native, db, String("chainstate_backend"), String("rocksdb"))
    assert_equal(db_get_string(native, db, String("validated_height")), String("5000"))
    assert_equal(db_get_string(native, db, String("chainstate_backend")), String("rocksdb"))
    native.rocksdb_close(db)


def test_rocksdb_multi_get_order_and_missing_slots() raises:
    var shim = getenv("MOJOBITNODE_SHIM_PATH", "./build/libmojobitnode_shim.dylib")
    var native = Native(shim)
    var db = native.rocksdb_open(String("/tmp/mojo_block_core_multiget_smoke"))
    var suffix = String(native.now_ms())

    var key_a = ascii_string_to_bytes(String("multiget:a:") + suffix)
    var key_missing = ascii_string_to_bytes(String("multiget:missing:") + suffix)
    var key_b = ascii_string_to_bytes(String("multiget:b:") + suffix)
    var value_a = ascii_string_to_bytes(String("alpha"))
    var value_b = ascii_string_to_bytes(String("bravo"))
    native.rocksdb_put(db, key_a, value_a)
    native.rocksdb_put(db, key_b, value_b)

    var keys = List[List[UInt8]]()
    keys.append(key_a.copy())
    keys.append(key_missing.copy())
    keys.append(key_missing.copy())
    keys.append(key_b.copy())
    var rows = rocksdb_multi_get_rows(native, db, keys)
    assert_equal(len(rows), 4)
    assert_true(rows[0].found)
    assert_true(not rows[1].found)
    assert_true(not rows[2].found)
    assert_true(rows[3].found)
    assert_equal(bytes_to_hex(rows[0].value), bytes_to_hex(value_a))
    assert_equal(bytes_to_hex(rows[3].value), bytes_to_hex(value_b))
    native.rocksdb_close(db)


def test_packed_key_index_orders_and_finds_outpoints() raises:
    var txid_a = List[UInt8]()
    var txid_b = List[UInt8]()
    var txid_c = List[UInt8]()
    for _ in range(32):
        txid_a.append(UInt8(2))
        txid_b.append(UInt8(1))
        txid_c.append(UInt8(3))

    var index = PackedKeyIndex()
    assert_true(index.add_outpoint(txid_a, UInt32(5), 50))
    assert_true(index.add_outpoint(txid_b, UInt32(1), 10))
    assert_true(index.add_outpoint(txid_c, UInt32(2), 20))
    assert_true(not index.add_outpoint(txid_a, UInt32(5), 99))
    assert_equal(index.find_outpoint(txid_b, UInt32(1)), 10)
    assert_equal(index.find_outpoint(txid_c, UInt32(2)), 20)
    assert_equal(index.find_outpoint(txid_a, UInt32(5)), 50)
    assert_equal(index.find_outpoint(txid_a, UInt32(6)), -1)
    var key = outpoint_index_key(txid_a, UInt32(5))
    assert_equal(len(key), 36)


def test_outpoint_helpers_preserve_order_and_detect_duplicates() raises:
    var txid_a = List[UInt8]()
    var txid_b = List[UInt8]()
    for i in range(32):
        txid_a.append(UInt8(i))
        txid_b.append(UInt8(31 - i))

    var txids = List[List[UInt8]]()
    var vouts = List[UInt32]()
    assert_true(append_outpoint_if_missing(txids, vouts, txid_a, UInt32(0)))
    assert_true(append_outpoint_if_missing(txids, vouts, txid_b, UInt32(1)))
    assert_true(not append_outpoint_if_missing(txids, vouts, txid_a, UInt32(0)))
    assert_equal(len(txids), 2)
    assert_true(contains_outpoint(txids, vouts, txid_b, UInt32(1)))

    var delta = BlockUtxoDelta()
    var utxo = Utxo()
    utxo.height = 1
    utxo.value_sats = Int64(50)
    utxo.coinbase = False
    utxo.script_pubkey = ascii_string_to_bytes(String("script"))
    append_delta_created(delta, txid_a, UInt32(2), utxo)
    append_delta_created(delta, txid_b, UInt32(3), utxo)
    assert_equal(find_created_delta_index(delta, txid_a, UInt32(2)), 0)
    assert_equal(find_created_delta_index(delta, txid_b, UInt32(3)), 1)
    assert_equal(find_created_delta_index(delta, txid_b, UInt32(4)), -1)


def test_native_crypto_metrics() raises:
    var shim = getenv("MOJOBITNODE_SHIM_PATH", "./build/libmojobitnode_shim.dylib")
    var native = Native(shim)
    native.crypto_metrics_reset()
    var tapscript = read_hex_file(TAPROOT_SCRIPTPATH_44295_SCRIPT)
    var control = read_hex_file(TAPROOT_SCRIPTPATH_44295_CONTROL)
    var script_pubkey = read_hex_file(TAPROOT_SCRIPTPATH_44295_PREV_SPK)
    assert_true(
        verify_taproot_tweak(
            shim,
            slice_bytes(control, 1, 33),
            tapleaf_hash(UInt8(0xC0), tapscript),
            slice_bytes(script_pubkey, 2, 34),
            Int(control[0] & UInt8(1)),
        )
    )
    assert_equal(native.crypto_metric(String("taproot_tweak_calls")), Int64(1))
    assert_true(native.crypto_metric(String("taproot_tweak_ms")) >= 0)


def test_block_job_failure_reduction_uses_lowest_tx_input_order() raises:
    var high = ScriptVerifyResult()
    high.job_index = 9
    high.completed = True
    high.ok = False
    high.tx_index = 4
    high.input_index = 0
    high.failure_stage = String("error")
    high.failure = String("late failure")

    var passed_result = ScriptVerifyResult()
    passed_result.job_index = 1
    passed_result.completed = True
    passed_result.ok = True

    var low = ScriptVerifyResult()
    low.job_index = 3
    low.completed = True
    low.ok = False
    low.tx_index = 2
    low.input_index = 1
    low.failure_stage = String("failed")
    low.failure = String("first failure")

    var results = List[ScriptVerifyResult]()
    results.append(high^)
    results.append(passed_result^)
    results.append(low^)

    assert_equal(first_failed_script_result_index(results), 2)


def test_shadow_crypto_reduction_is_deterministic() raises:
    assert_true(shadow_crypto_reduction_smoke())


def test_hotpath_profile_counters_are_passive_and_nonzero() raises:
    var shim = getenv("MOJOBITNODE_SHIM_PATH", "./build/libmojobitnode_shim.dylib")
    var profile = HotPathProfile()
    profile.enabled = True

    var tx_bytes = read_hex_file(FIRST_FIXTURE_TX)
    var tx = parse_transaction(tx_bytes.copy())
    var cloned = clone_bytes_profiled(tx_bytes, profile)
    _ = slice_bytes_profiled(cloned, 0, 8, profile)

    var script = List[UInt8]()
    script.append(UInt8(0x51))
    script.append(UInt8(0x76))
    script.append(UInt8(0x75))
    var stack = List[ScriptStackItem]()
    var crypto = CryptoBackend(shim, CRYPTO_BACKEND_NATIVE)
    assert_true(
        evaluate_legacy_script_with_crypto_profiled(
            script,
            stack^,
            tx,
            0,
            shim,
            crypto,
            profile,
            False,
        )
    )

    var sig = List[UInt8]()
    sig.append(UInt8(0x30))
    sig.append(UInt8(0x01))
    _ = legacy_sighash_profiled(tx, 0, script, sig, profile)

    assert_true(profile.clone_calls > 0)
    assert_true(profile.slice_calls > 0)
    assert_true(profile.script_stack_pushes > 0)
    assert_true(profile.script_stack_pops > 0)
    assert_true(profile.script_stack_dup_copy_ops > 0)
    assert_true(profile.script_stack_max_depth > 0)
    assert_true(profile.legacy_sighash_calls > 0)
    assert_true(profile.legacy_sighash_bytes > 0)


def test_crypto_backend_result_classes_do_not_fallback_to_native() raises:
    var shim = getenv("MOJOBITNODE_SHIM_PATH", "./build/libmojobitnode_shim.dylib")
    var pubkey = List[UInt8]()
    var signature = List[UInt8]()
    var digest = List[UInt8]()
    var native = CryptoBackend(shim, CRYPTO_BACKEND_NATIVE)
    var pure = CryptoBackend(shim, CRYPTO_BACKEND_PURE)

    assert_true(not native.is_pure())
    assert_true(pure.is_pure())

    var native_result = native.verify_ecdsa_der_bytes(pubkey, signature, digest)
    var pure_result = pure.verify_ecdsa_der_bytes(pubkey, signature, digest)
    assert_true(native_result != CRYPTO_RESULT_UNSUPPORTED)
    assert_equal(pure_result, CRYPTO_RESULT_MALFORMED)

    pure_result = pure.verify_schnorr_bytes(pubkey, signature, digest)
    assert_equal(pure_result, CRYPTO_RESULT_MALFORMED)

    pure_result = pure.verify_taproot_tweak_precomputed(pubkey, signature, digest, 0)
    assert_equal(pure_result, CRYPTO_RESULT_MALFORMED)


def _hex_bytes(text: String) raises -> List[UInt8]:
    return hex_text_to_bytes(ascii_string_to_bytes(text))


def assert_field_inverse_matches_reference(ref candidate: List[UInt8], ref one: List[UInt8]) raises:
    assert_equal(
        bytes_to_hex(pure_test_u256_inv_field_fast(candidate)),
        bytes_to_hex(pure_test_u256_inv_field_reference(candidate)),
    )
    var inv_candidate = pure_test_u256_inv_field_fast(candidate)
    assert_equal(
        bytes_to_hex(pure_test_u256_mul_field_fast(candidate, inv_candidate)),
        bytes_to_hex(one),
    )


def assert_field_sqrt_matches_reference(ref residue: List[UInt8]) raises:
    assert_equal(
        bytes_to_hex(pure_test_u256_sqrt_field_fast(residue)),
        bytes_to_hex(pure_test_u256_sqrt_field_reference(residue)),
    )
    var root = pure_test_u256_sqrt_field_fast(residue)
    assert_equal(bytes_to_hex(pure_test_u256_square_field(root)), bytes_to_hex(residue))


def test_pure_secp_arithmetic_known_vectors() raises:
    var field_p = _hex_bytes(String("fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f"))
    var two = _hex_bytes(String("0000000000000000000000000000000000000000000000000000000000000002"))
    var three = _hex_bytes(String("0000000000000000000000000000000000000000000000000000000000000003"))
    var four = _hex_bytes(String("0000000000000000000000000000000000000000000000000000000000000004"))
    var five = _hex_bytes(String("0000000000000000000000000000000000000000000000000000000000000005"))
    var six = _hex_bytes(String("0000000000000000000000000000000000000000000000000000000000000006"))
    var one = _hex_bytes(String("0000000000000000000000000000000000000000000000000000000000000001"))
    var p_minus_one = _hex_bytes(String("fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2e"))
    var p_plus_one = _hex_bytes(String("fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc30"))
    var p_minus_two = _hex_bytes(String("fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2d"))
    var zero = _hex_bytes(String("0000000000000000000000000000000000000000000000000000000000000000"))
    var inv_two = _hex_bytes(String("7fffffffffffffffffffffffffffffffffffffffffffffffffffffff7ffffe18"))
    var carry_field_b = _hex_bytes(String("fffffffffffffffffffffffffffffffffffffffffffffffffffffffdfffff85e"))
    var carry_field_expected = _hex_bytes(String("00000000000000000000000000000000000000000000000000000001000003d1"))
    var high_a = _hex_bytes(String("f73dafc19d228263cb4ed5db0500e47f603b61fa65eeae217ccb74acc1d36143"))
    var high_b = _hex_bytes(String("6114c8de454c9b5272e1284cd8f2974118b8b15da4f2439136e5d08b7eb03b7b"))
    var high_a_square = _hex_bytes(String("0af5a4cc9a91fdcec8e6b8f2c606b20f03751f5dd04a98faaa6233e598f62133"))

    assert_equal(bytes_to_hex(pure_test_u256_add_mod(two, three, field_p)), bytes_to_hex(five))
    assert_equal(bytes_to_hex(pure_test_u256_sub_mod(three, five, field_p)), bytes_to_hex(p_minus_two))
    assert_equal(bytes_to_hex(pure_test_u256_mul_mod(two, three, field_p)), bytes_to_hex(six))
    assert_equal(bytes_to_hex(pure_test_u256_mul_mod(field_p, one, field_p.copy())), bytes_to_hex(zero))
    assert_equal(bytes_to_hex(pure_test_u256_mul_mod(p_plus_one, one, field_p)), bytes_to_hex(one))
    assert_equal(bytes_to_hex(pure_test_u256_inv_mod(two, field_p)), bytes_to_hex(inv_two))
    assert_field_inverse_matches_reference(one, one.copy())
    assert_field_inverse_matches_reference(two, one)
    assert_field_inverse_matches_reference(p_minus_one, one)
    assert_field_inverse_matches_reference(p_plus_one, one)
    assert_field_inverse_matches_reference(p_minus_two, one)
    assert_field_inverse_matches_reference(high_a, one)
    assert_equal(bytes_to_hex(pure_test_u256_mul_field_fast(p_minus_one, carry_field_b)), bytes_to_hex(carry_field_expected))
    assert_equal(bytes_to_hex(pure_test_u256_mul_field_fast(p_minus_two, p_minus_two.copy())), bytes_to_hex(four))
    assert_equal(
        bytes_to_hex(pure_test_u256_add_mod(high_a, high_b, field_p)),
        String("5852789fe26f1db63e2ffe27ddf37bc078f413580ae0f1b2b3b145394083a08f"),
    )
    assert_equal(
        bytes_to_hex(pure_test_u256_sub_mod(high_a, high_b, field_p)),
        String("9628e6e357d5e711586dad8e2c0e4d3e4782b09cc0fc6a9045e5a421432325c8"),
    )
    assert_equal(
        bytes_to_hex(pure_test_u256_mul_mod(high_a, high_b, field_p)),
        String("422effa10d0f872f33c4ad3ee7134e1b01485ff67d9fd681aa8caeb057552e0c"),
    )
    assert_equal(bytes_to_hex(pure_test_u256_square_field(high_a)), bytes_to_hex(high_a_square))
    assert_field_sqrt_matches_reference(four)
    assert_field_sqrt_matches_reference(high_a_square)
    assert_equal(bytes_to_hex(pure_test_u256_square_field(p_minus_one)), bytes_to_hex(one))
    assert_equal(bytes_to_hex(pure_test_u256_square_field(p_minus_two)), bytes_to_hex(four))
    assert_equal(
        bytes_to_hex(pure_test_u256_square_field(two)),
        bytes_to_hex(pure_test_u256_mul_mod(two, two.copy(), field_p)),
    )
    assert_equal(bytes_to_hex(pure_test_fe52_roundtrip(zero)), bytes_to_hex(zero))
    assert_equal(bytes_to_hex(pure_test_fe52_roundtrip(one)), bytes_to_hex(one))
    assert_equal(bytes_to_hex(pure_test_fe52_roundtrip(field_p)), bytes_to_hex(zero))
    assert_equal(bytes_to_hex(pure_test_fe52_roundtrip(p_plus_one)), bytes_to_hex(one))
    assert_equal(bytes_to_hex(pure_test_fe52_add(two, three)), bytes_to_hex(five))
    assert_equal(bytes_to_hex(pure_test_fe52x2_add_lane(two, three, 0)), bytes_to_hex(five))
    assert_equal(bytes_to_hex(pure_test_fe52x2_add_lane(two, three, 1)), bytes_to_hex(five))
    assert_equal(bytes_to_hex(pure_test_fe52x4_add_lane(two, three, 0)), bytes_to_hex(five))
    assert_equal(bytes_to_hex(pure_test_fe52x4_add_lane(two, three, 3)), bytes_to_hex(five))
    assert_equal(bytes_to_hex(pure_test_fe52_add(p_minus_one, two)), bytes_to_hex(one))
    assert_equal(bytes_to_hex(pure_test_fe52_sub_via_negate(three, five)), bytes_to_hex(p_minus_two))
    assert_equal(bytes_to_hex(pure_test_fe52_sub_via_negate(two, two.copy())), bytes_to_hex(zero))
    assert_equal(bytes_to_hex(pure_test_fe52_mul(two, three)), bytes_to_hex(six))
    assert_equal(bytes_to_hex(pure_test_fe52x2_mul_lane(two, three, 0)), bytes_to_hex(six))
    assert_equal(bytes_to_hex(pure_test_fe52x2_mul_lane(two, three, 1)), bytes_to_hex(six))
    assert_equal(bytes_to_hex(pure_test_fe52x4_mul_lane(two, three, 0)), bytes_to_hex(six))
    assert_equal(bytes_to_hex(pure_test_fe52x4_mul_lane(two, three, 3)), bytes_to_hex(six))
    assert_equal(bytes_to_hex(pure_test_fe52_mul(p_minus_one, carry_field_b)), bytes_to_hex(carry_field_expected))
    assert_equal(bytes_to_hex(pure_test_fe52x4_mul_lane(p_minus_one, carry_field_b, 0)), bytes_to_hex(carry_field_expected))
    assert_equal(bytes_to_hex(pure_test_fe52x4_mul_lane(p_minus_one, carry_field_b, 3)), bytes_to_hex(carry_field_expected))
    assert_equal(bytes_to_hex(pure_test_fe52_mul(high_a, high_b)), String("422effa10d0f872f33c4ad3ee7134e1b01485ff67d9fd681aa8caeb057552e0c"))
    assert_equal(bytes_to_hex(pure_test_fe52_sqr(high_a)), bytes_to_hex(high_a_square))
    assert_equal(bytes_to_hex(pure_test_fe52x2_sqr_lane(high_a, 0)), bytes_to_hex(high_a_square))
    assert_equal(bytes_to_hex(pure_test_fe52x2_sqr_lane(high_a, 1)), bytes_to_hex(high_a_square))
    assert_equal(bytes_to_hex(pure_test_fe52x4_sqr_lane(high_a, 0)), bytes_to_hex(high_a_square))
    assert_equal(bytes_to_hex(pure_test_fe52x4_sqr_lane(high_a, 3)), bytes_to_hex(high_a_square))
    assert_equal(bytes_to_hex(pure_test_fe52_sqr(p_minus_one)), bytes_to_hex(one))
    assert_equal(bytes_to_hex(pure_test_fe52_sqr(p_minus_two)), bytes_to_hex(four))
    assert_equal(bytes_to_hex(pure_test_fe52_mul_int(two, UInt32(3))), bytes_to_hex(six))
    assert_true(pure_test_fe52_equal(field_p, zero))
    assert_true(pure_test_fe52_equal(p_plus_one, one))
    assert_true(not pure_test_fe52_equal(two, three))
    assert_true(pure_test_fe52_is_zero(field_p))
    assert_true(not pure_test_fe52_is_zero(one))

    var scalar_two = two.copy()
    assert_equal(
        bytes_to_hex(pure_test_scalar_mul_g_x(scalar_two)),
        String("c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5"),
    )
    assert_equal(
        bytes_to_hex(pure_test_fe52_scalar_mul_g_x(scalar_two)),
        bytes_to_hex(pure_test_scalar_mul_g_x(scalar_two)),
    )
    assert_equal(
        bytes_to_hex(pure_test_scalar_mul_g_y(scalar_two)),
        String("1ae168fea63dc339a3c58419466ceaeef7f632653266d0e1236431a950cfe52a"),
    )
    assert_equal(
        bytes_to_hex(pure_test_fe52_scalar_mul_g_y(scalar_two)),
        bytes_to_hex(pure_test_scalar_mul_g_y(scalar_two)),
    )
    var scalar_12345 = _hex_bytes(String("0000000000000000000000000000000000000000000000000000000000003039"))
    assert_equal(
        bytes_to_hex(pure_test_scalar_mul_g_x(scalar_12345)),
        String("f01d6b9018ab421dd410404cb869072065522bf85734008f105cf385a023a80f"),
    )
    assert_equal(
        bytes_to_hex(pure_test_fe52_scalar_mul_g_x(scalar_12345)),
        bytes_to_hex(pure_test_scalar_mul_g_x(scalar_12345)),
    )
    assert_equal(
        bytes_to_hex(pure_test_scalar_mul_g_y(scalar_12345)),
        String("0eba29d0f0c5408ed681984dc525982abefccd9f7ff01dd26da4999cf3f6a295"),
    )
    assert_equal(
        bytes_to_hex(pure_test_fe52_scalar_mul_g_y(scalar_12345)),
        bytes_to_hex(pure_test_scalar_mul_g_y(scalar_12345)),
    )
    var scalar_n = _hex_bytes(String("fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141"))
    var scalar_n_minus_one = _hex_bytes(String("fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364140"))
    var scalar_n_plus_one = _hex_bytes(String("fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364142"))
    var scalar_n_minus_two = _hex_bytes(String("fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd036413f"))
    var scalar_half_n = _hex_bytes(String("7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0"))
    var scalar_carry_b = _hex_bytes(String("fffffffffffffffffffffffffffffffdbaaedce6af48a03bbfd25e8cd0364141"))
    var scalar_carry_expected = _hex_bytes(String("0000000000000000000000000000000200000000000000000000000000000000"))
    assert_equal(bytes_to_hex(pure_test_u256_mul_mod(scalar_n, one, scalar_n.copy())), bytes_to_hex(zero))
    assert_equal(bytes_to_hex(pure_test_u256_mul_mod(scalar_n_plus_one, one, scalar_n)), bytes_to_hex(one))
    assert_equal(bytes_to_hex(pure_test_u256_mul_mod(scalar_n_minus_one, scalar_n_minus_one.copy(), scalar_n)), bytes_to_hex(one))
    assert_equal(bytes_to_hex(pure_test_u256_mul_scalar_fast(scalar_n_minus_two, scalar_n_minus_two.copy())), bytes_to_hex(four))
    assert_equal(bytes_to_hex(pure_test_u256_mul_scalar_fast(scalar_n_minus_two, scalar_carry_b)), bytes_to_hex(scalar_carry_expected))
    assert_equal(
        bytes_to_hex(pure_test_u256_mul_mod(high_a, high_b, scalar_n)),
        String("409d760cc8e690cee14030d059b1d84a10c2b3aa3281a64aab2f9655bd397af1"),
    )
    assert_true(pure_test_scalar_mul_g_is_infinity(scalar_n))
    assert_true(pure_test_glv_constants())
    assert_true(pure_test_scalar_split_lambda_identity(zero))
    assert_true(pure_test_scalar_split_lambda_identity(one))
    assert_true(pure_test_scalar_split_lambda_identity(two))
    assert_true(pure_test_scalar_split_lambda_identity(scalar_n_minus_one))
    assert_true(pure_test_scalar_split_lambda_identity(scalar_half_n))
    assert_true(pure_test_scalar_split_lambda_identity(high_a))


def test_pure_schnorr_and_taproot_vectors() raises:
    var shim = getenv("MOJOBITNODE_SHIM_PATH", "./build/libmojobitnode_shim.dylib")
    var pure = CryptoBackend(shim, CRYPTO_BACKEND_PURE)

    var schnorr_pubkey = _hex_bytes(String("f01d6b9018ab421dd410404cb869072065522bf85734008f105cf385a023a80f"))
    var schnorr_msg = _hex_bytes(String("3ad22a0437431f2d102505b27048dfce20b1f90b32fe2116130d2bd4b35084b9"))
    var schnorr_sig = _hex_bytes(String("632f89d23c32b7d66873d7ef89e730f44f3d063394f8661e4421469979ac5784c80478f3845b4719c92c339fe1032890f9d96b6b0b44a8ea05da6ce88a133b7b"))
    var schnorr_r = _hex_bytes(String("632f89d23c32b7d66873d7ef89e730f44f3d063394f8661e4421469979ac5784"))
    assert_equal(
        bytes_to_hex(pure_test_schnorr_challenge(schnorr_r, schnorr_pubkey, schnorr_msg)),
        String("f18b17f0caabbdce27f649e8f9b33d3c753c40dd023cea53a3722359ca6db388"),
    )
    assert_equal(pure.verify_schnorr_bytes(schnorr_pubkey, schnorr_sig, schnorr_msg), CRYPTO_RESULT_VALID)
    assert_equal(pure_test_schnorr_reference_result(schnorr_pubkey, schnorr_sig, schnorr_msg), CRYPTO_RESULT_VALID)
    assert_equal(pure_test_schnorr_fe52_wnaf_result(schnorr_pubkey, schnorr_sig, schnorr_msg), CRYPTO_RESULT_VALID)
    assert_equal(
        pure_test_schnorr_fe52_wnaf_result(schnorr_pubkey, schnorr_sig, schnorr_msg),
        pure_test_schnorr_reference_result(schnorr_pubkey, schnorr_sig, schnorr_msg),
    )

    var mutated_sig = schnorr_sig.copy()
    mutated_sig[63] = mutated_sig[63] ^ UInt8(1)
    assert_equal(pure.verify_schnorr_bytes(schnorr_pubkey, mutated_sig, schnorr_msg), CRYPTO_RESULT_CONSENSUS_INVALID)
    assert_equal(
        pure_test_schnorr_fe52_wnaf_result(schnorr_pubkey, mutated_sig, schnorr_msg),
        pure_test_schnorr_reference_result(schnorr_pubkey, mutated_sig, schnorr_msg),
    )

    var short_sig = List[UInt8]()
    short_sig.append(UInt8(1))
    assert_equal(pure.verify_schnorr_bytes(schnorr_pubkey, short_sig, schnorr_msg), CRYPTO_RESULT_MALFORMED)
    assert_equal(
        pure_test_schnorr_fe52_wnaf_result(schnorr_pubkey, short_sig, schnorr_msg),
        pure_test_schnorr_reference_result(schnorr_pubkey, short_sig, schnorr_msg),
    )

    var taproot_internal = _hex_bytes(String("85a7b790fc9d962493788317e4874a4ab07f1e9c78c773c47f2f6c96df756f05"))
    var taproot_merkle_root = _hex_bytes(String("446ba384864eb34196e08044029fb463d97748e4549dfd0e2612f60d74c4f165"))
    var taproot_tweak = taproot_tweak_hash(taproot_internal, taproot_merkle_root)
    var taproot_expected = _hex_bytes(String("4b3e30f94e0ae82945cbb40d83088b8f3bea370c24c575b7788889ad5e64da8b"))
    assert_equal(
        pure.verify_taproot_tweak_precomputed(taproot_internal, taproot_tweak, taproot_expected, 1),
        CRYPTO_RESULT_VALID,
    )
    assert_equal(
        pure_test_taproot_tweak_reference_result(taproot_internal, taproot_tweak, taproot_expected, 1),
        CRYPTO_RESULT_VALID,
    )
    assert_equal(
        pure_test_taproot_tweak_fe52_result(taproot_internal, taproot_tweak, taproot_expected, 1),
        CRYPTO_RESULT_VALID,
    )
    assert_equal(
        pure_test_taproot_tweak_fe52_result(taproot_internal, taproot_tweak, taproot_expected, 1),
        pure_test_taproot_tweak_reference_result(taproot_internal, taproot_tweak, taproot_expected, 1),
    )
    assert_equal(
        pure.verify_taproot_tweak_precomputed(taproot_internal, taproot_tweak, taproot_expected, 0),
        CRYPTO_RESULT_CONSENSUS_INVALID,
    )
    assert_equal(
        pure_test_taproot_tweak_fe52_result(taproot_internal, taproot_tweak, taproot_expected, 0),
        pure_test_taproot_tweak_reference_result(taproot_internal, taproot_tweak, taproot_expected, 0),
    )
    assert_equal(
        pure.verify_taproot_tweak_precomputed(short_sig, taproot_tweak, taproot_expected, 1),
        CRYPTO_RESULT_MALFORMED,
    )
    assert_equal(
        pure_test_taproot_tweak_fe52_result(short_sig, taproot_tweak, taproot_expected, 1),
        pure_test_taproot_tweak_reference_result(short_sig, taproot_tweak, taproot_expected, 1),
    )


def test_pure_ecdsa_der_vectors_match_native() raises:
    var shim = getenv("MOJOBITNODE_SHIM_PATH", "./build/libmojobitnode_shim.dylib")
    var native = CryptoBackend(shim, CRYPTO_BACKEND_NATIVE)
    var pure = CryptoBackend(shim, CRYPTO_BACKEND_PURE)

    var pubkey = _hex_bytes(String("0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"))
    var msg = _hex_bytes(String("281dd50f6f56bc6e867fe73dd614a73c55a647a479704f64804b574cafb0f5c5"))
    var wrong_msg = _hex_bytes(String("ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"))
    var sig = _hex_bytes(String("3044022079be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f8179802205e23c47196cc87e523dfb62c5b644dbb626c9867080a27fde59485e5098d33e4"))
    var uncompressed_pubkey = _hex_bytes(String("0479be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8"))

    assert_equal(
        bytes_to_hex(pure_test_ecdsa_parse_der(sig)),
        String("79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f817985e23c47196cc87e523dfb62c5b644dbb626c9867080a27fde59485e5098d33e4"),
    )
    assert_equal(pure.verify_ecdsa_der_bytes(pubkey, sig, msg), native.verify_ecdsa_der_bytes(pubkey, sig, msg))
    assert_equal(pure.verify_ecdsa_der_bytes(pubkey, sig, msg), CRYPTO_RESULT_VALID)
    assert_equal(pure_test_ecdsa_reference_result(pubkey, sig, msg), CRYPTO_RESULT_VALID)
    assert_equal(pure_test_ecdsa_wnaf_result(pubkey, sig, msg), CRYPTO_RESULT_VALID)
    assert_equal(pure_test_ecdsa_glv_result(pubkey, sig, msg), CRYPTO_RESULT_VALID)
    assert_equal(pure_test_ecdsa_fe52_wnaf_result(pubkey, sig, msg), CRYPTO_RESULT_VALID)
    assert_equal(pure.verify_ecdsa_der_bytes(uncompressed_pubkey, sig, msg), native.verify_ecdsa_der_bytes(uncompressed_pubkey, sig, msg))
    assert_equal(pure.verify_ecdsa_der_bytes(uncompressed_pubkey, sig, msg), CRYPTO_RESULT_VALID)
    assert_true(pure_test_odd_multiples_match_generator(8))
    assert_true(pure_test_odd_multiples_match_pubkey(pubkey, 8))
    var scalar_half_n = _hex_bytes(String("7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0"))
    var scalar_high = _hex_bytes(String("fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364140"))
    assert_true(pure_test_endo_split_not_high(scalar_half_n, pubkey))
    assert_true(pure_test_endo_split_not_high(scalar_high, pubkey))
    assert_true(pure_test_generator_endo_split_not_high(scalar_half_n))
    assert_true(pure_test_generator_endo_split_not_high(scalar_high))
    assert_true(pure_test_fe52_generator_beta_table_matches(8))
    assert_true(pure_test_fe52_pubkey_beta_table_matches(pubkey, 8))
    var taproot_xonly = _hex_bytes(String("85a7b790fc9d962493788317e4874a4ab07f1e9c78c773c47f2f6c96df756f05"))
    assert_true(pure_test_odd_multiples_match_xonly(taproot_xonly, 8))
    var old_glv_max_len = pure_test_ecdsa_fe52_glv_old_max_len(pubkey, sig, msg)
    var new_glv_max_len = pure_test_ecdsa_fe52_glv_max_len(pubkey, sig, msg)
    assert_true(old_glv_max_len > 200)
    assert_true(new_glv_max_len < old_glv_max_len)
    assert_true(new_glv_max_len <= 170)
    assert_equal(
        bytes_to_hex(pure_test_ecdsa_wnaf_product_x(pubkey, sig, msg)),
        bytes_to_hex(pure_test_ecdsa_reference_product_x(pubkey, sig, msg)),
    )
    assert_equal(
        bytes_to_hex(pure_test_ecdsa_fe52_reference_product_x(pubkey, sig, msg)),
        bytes_to_hex(pure_test_ecdsa_reference_product_x(pubkey, sig, msg)),
    )
    assert_equal(
        bytes_to_hex(pure_test_ecdsa_glv_product_x(pubkey, sig, msg)),
        bytes_to_hex(pure_test_ecdsa_wnaf_product_x(pubkey, sig, msg)),
    )
    assert_equal(
        bytes_to_hex(pure_test_ecdsa_fe52_wnaf_product_x(pubkey, sig, msg)),
        bytes_to_hex(pure_test_ecdsa_wnaf_product_x(pubkey, sig, msg)),
    )
    assert_equal(
        bytes_to_hex(pure_test_ecdsa_fe52_simd4_wnaf_product_x(pubkey, sig, msg, 0)),
        bytes_to_hex(pure_test_ecdsa_fe52_wnaf_product_x(pubkey, sig, msg)),
    )
    assert_equal(
        bytes_to_hex(pure_test_ecdsa_fe52_simd4_wnaf_product_x(pubkey, sig, msg, 3)),
        bytes_to_hex(pure_test_ecdsa_fe52_wnaf_product_x(pubkey, sig, msg)),
    )
    assert_equal(pure_test_ecdsa_fe52_simd2_wnaf_result(pubkey, sig, msg), pure_test_ecdsa_fe52_wnaf_result(pubkey, sig, msg))
    assert_equal(pure_test_ecdsa_fe52_simd2_wnaf_mismatches(pubkey, sig, msg), 0)
    assert_equal(pure_test_ecdsa_fe52_simd4_wnaf_result(pubkey, sig, msg), pure_test_ecdsa_fe52_wnaf_result(pubkey, sig, msg))
    assert_equal(pure_test_ecdsa_fe52_simd4_wnaf_mismatches(pubkey, sig, msg), 0)
    assert_equal(pure_test_ecdsa_fe52_simd8_wnaf_result(pubkey, sig, msg), pure_test_ecdsa_fe52_wnaf_result(pubkey, sig, msg))
    assert_equal(pure_test_ecdsa_fe52_simd8_wnaf_mismatches(pubkey, sig, msg), 0)
    assert_equal(pure_test_ecdsa_fe52_simd16_wnaf_result(pubkey, sig, msg), pure_test_ecdsa_fe52_wnaf_result(pubkey, sig, msg))
    assert_equal(pure_test_ecdsa_fe52_simd16_wnaf_mismatches(pubkey, sig, msg), 0)
    assert_equal(pure_test_ecdsa_fe52_wnaf_result(pubkey, sig, msg), pure_test_ecdsa_wnaf_result(pubkey, sig, msg))
    assert_equal(
        bytes_to_hex(pure_test_ecdsa_fe52_glv_product_x(pubkey, sig, msg)),
        bytes_to_hex(pure_test_ecdsa_glv_product_x(pubkey, sig, msg)),
    )
    assert_equal(pure_test_ecdsa_fe52_glv_result(pubkey, sig, msg), pure_test_ecdsa_glv_result(pubkey, sig, msg))
    assert_equal(
        pure.verify_ecdsa_der_bytes(pubkey, sig, wrong_msg),
        native.verify_ecdsa_der_bytes(pubkey, sig, wrong_msg),
    )
    assert_equal(pure.verify_ecdsa_der_bytes(pubkey, sig, wrong_msg), CRYPTO_RESULT_CONSENSUS_INVALID)
    assert_equal(pure_test_ecdsa_wnaf_result(pubkey, sig, wrong_msg), pure_test_ecdsa_reference_result(pubkey, sig, wrong_msg))
    assert_equal(pure_test_ecdsa_fe52_wnaf_result(pubkey, sig, wrong_msg), pure_test_ecdsa_wnaf_result(pubkey, sig, wrong_msg))
    assert_equal(pure_test_ecdsa_fe52_simd2_wnaf_result(pubkey, sig, wrong_msg), pure_test_ecdsa_fe52_wnaf_result(pubkey, sig, wrong_msg))
    assert_equal(pure_test_ecdsa_fe52_simd2_wnaf_mismatches(pubkey, sig, wrong_msg), 0)
    assert_equal(pure_test_ecdsa_fe52_simd4_wnaf_result(pubkey, sig, wrong_msg), pure_test_ecdsa_fe52_wnaf_result(pubkey, sig, wrong_msg))
    assert_equal(pure_test_ecdsa_fe52_simd4_wnaf_mismatches(pubkey, sig, wrong_msg), 0)
    assert_equal(pure_test_ecdsa_glv_result(pubkey, sig, wrong_msg), pure_test_ecdsa_wnaf_result(pubkey, sig, wrong_msg))
    assert_equal(pure_test_ecdsa_fe52_glv_result(pubkey, sig, wrong_msg), pure_test_ecdsa_glv_result(pubkey, sig, wrong_msg))

    var high_s_sig = _hex_bytes(String("3045022079be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798022100a1dc3b8e6933781adc2049d3a49bb2435842447fa73e783dda3dd8a7c6a90d5d"))
    assert_equal(
        pure.verify_ecdsa_der_bytes(pubkey, high_s_sig, msg),
        native.verify_ecdsa_der_bytes(pubkey, high_s_sig, msg),
    )
    assert_equal(pure.verify_ecdsa_der_bytes(pubkey, high_s_sig, msg), CRYPTO_RESULT_VALID)
    assert_equal(pure_test_ecdsa_wnaf_result(pubkey, high_s_sig, msg), pure_test_ecdsa_reference_result(pubkey, high_s_sig, msg))
    assert_equal(pure_test_ecdsa_glv_result(pubkey, high_s_sig, msg), pure_test_ecdsa_wnaf_result(pubkey, high_s_sig, msg))
    assert_equal(
        bytes_to_hex(pure_test_ecdsa_glv_product_x(pubkey, high_s_sig, msg)),
        bytes_to_hex(pure_test_ecdsa_wnaf_product_x(pubkey, high_s_sig, msg)),
    )
    assert_equal(
        bytes_to_hex(pure_test_ecdsa_fe52_reference_product_x(pubkey, high_s_sig, msg)),
        bytes_to_hex(pure_test_ecdsa_reference_product_x(pubkey, high_s_sig, msg)),
    )
    assert_equal(
        bytes_to_hex(pure_test_ecdsa_fe52_wnaf_product_x(pubkey, high_s_sig, msg)),
        bytes_to_hex(pure_test_ecdsa_wnaf_product_x(pubkey, high_s_sig, msg)),
    )
    assert_equal(pure_test_ecdsa_fe52_simd2_wnaf_result(pubkey, high_s_sig, msg), pure_test_ecdsa_fe52_wnaf_result(pubkey, high_s_sig, msg))
    assert_equal(pure_test_ecdsa_fe52_simd2_wnaf_mismatches(pubkey, high_s_sig, msg), 0)
    assert_equal(pure_test_ecdsa_fe52_simd4_wnaf_result(pubkey, high_s_sig, msg), pure_test_ecdsa_fe52_wnaf_result(pubkey, high_s_sig, msg))
    assert_equal(pure_test_ecdsa_fe52_simd4_wnaf_mismatches(pubkey, high_s_sig, msg), 0)
    assert_equal(pure_test_ecdsa_fe52_wnaf_result(pubkey, high_s_sig, msg), pure_test_ecdsa_wnaf_result(pubkey, high_s_sig, msg))
    assert_equal(
        bytes_to_hex(pure_test_ecdsa_fe52_glv_product_x(pubkey, high_s_sig, msg)),
        bytes_to_hex(pure_test_ecdsa_glv_product_x(pubkey, high_s_sig, msg)),
    )
    assert_equal(pure_test_ecdsa_fe52_glv_result(pubkey, high_s_sig, msg), pure_test_ecdsa_glv_result(pubkey, high_s_sig, msg))

    var empty_pubkey = List[UInt8]()
    assert_equal(pure.verify_ecdsa_der_bytes(empty_pubkey, sig, msg), CRYPTO_RESULT_MALFORMED)
    var malformed_sig = _hex_bytes(String("3144022079be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f8179802205e23c47196cc87e523dfb62c5b644dbb626c9867080a27fde59485e5098d33e4"))
    assert_equal(pure.verify_ecdsa_der_bytes(pubkey, malformed_sig, msg), CRYPTO_RESULT_MALFORMED)
    var zero_r_sig = _hex_bytes(String("3006020100020101"))
    assert_equal(pure.verify_ecdsa_der_bytes(pubkey, zero_r_sig, msg), CRYPTO_RESULT_CONSENSUS_INVALID)


def _fake_hash(seed: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(32):
        out.append(UInt8((seed + i) & 0xFF))
    return out^


def _legacy_cache_test_tx(output_count: Int) -> Transaction:
    var tx = Transaction()
    tx.version = Int32(1)
    tx.lock_time = UInt32(0)
    for i in range(6):
        var input = TxInput()
        input.previous_hash = _fake_hash(i * 17)
        input.previous_index = UInt32(i)
        input.sequence = UInt32(0xFFFFFFFE - i)
        tx.inputs.append(input^)
    for i in range(output_count):
        var output = TxOutput()
        output.value = Int64(900 - i * 100)
        output.script_pubkey = ascii_string_to_bytes(String("legacy-cache-output-") + String(i))
        tx.outputs.append(output^)
    return tx^


def _legacy_sig(sighash_type: UInt8) -> List[UInt8]:
    var sig = List[UInt8]()
    sig.append(UInt8(0x30))
    sig.append(UInt8(0x01))
    sig.append(sighash_type)
    return sig^


def _p2pkh_script_code() -> List[UInt8]:
    var script = List[UInt8]()
    script.append(UInt8(0x76))
    script.append(UInt8(0xA9))
    script.append(UInt8(0x14))
    for _ in range(20):
        script.append(UInt8(0x11))
    script.append(UInt8(0x88))
    script.append(UInt8(0xAC))
    return script^


def assert_legacy_cached_matches_reference(ref tx: Transaction, input_index: Int, ref script: List[UInt8], sighash_type: UInt8) raises:
    var prevouts = List[TaprootPrevout]()
    var cache = build_sighash_precompute_for_modes(tx, prevouts, True, False, False)
    var sig = _legacy_sig(sighash_type)
    if not ((Int(sighash_type) & 0x1F) == 3 and input_index >= len(tx.outputs)):
        var trimmed = legacy_find_and_delete(script, sig)
        var reference_preimage = legacy_sighash_preimage(tx, input_index, trimmed, sighash_type)
        var cached_preimage = legacy_sighash_cached_preimage(tx, input_index, trimmed, sighash_type, cache)
        assert_equal(bytes_to_hex(cached_preimage), bytes_to_hex(reference_preimage))
    var reference = legacy_sighash(tx, input_index, script, sig)
    var cached = legacy_sighash_cached(tx, input_index, script, sig, cache)
    assert_equal(bytes_to_hex(cached), bytes_to_hex(reference))


def test_legacy_sighash_cache_matches_reference_modes() raises:
    var tx = _legacy_cache_test_tx(3)
    var one_output_tx = _legacy_cache_test_tx(1)
    var script = _p2pkh_script_code()
    for input_index in [0, 2, 5]:
        for sighash_type in [UInt8(0x01), UInt8(0x02), UInt8(0x03), UInt8(0x81), UInt8(0x82), UInt8(0x83)]:
            assert_legacy_cached_matches_reference(tx, input_index, script, sighash_type)
            assert_legacy_cached_matches_reference(one_output_tx, input_index, script, sighash_type)

    var prevouts = List[TaprootPrevout]()
    var cache = build_sighash_precompute_for_modes(one_output_tx, prevouts, True, False, False)
    var out_of_range = legacy_sighash_cached(one_output_tx, 2, script, _legacy_sig(UInt8(0x03)), cache)
    assert_equal(out_of_range[0], UInt8(1))
    for i in range(1, 32):
        assert_equal(out_of_range[i], UInt8(0))

    var sig_a = _legacy_sig(UInt8(0x01))
    sig_a.append(UInt8(0xAA))
    var sig_b = _legacy_sig(UInt8(0x01))
    sig_b.append(UInt8(0xBB))
    var multisig_script = List[UInt8]()
    multisig_script.append(UInt8(len(sig_a)))
    append_bytes(multisig_script, sig_a)
    append_bytes(multisig_script, script)
    multisig_script.append(UInt8(len(sig_b)))
    append_bytes(multisig_script, sig_b)
    var once = legacy_find_and_delete(multisig_script, sig_a)
    var cleaned = legacy_find_and_delete(once, sig_b)
    var reference = legacy_sighash(tx, 1, cleaned, _legacy_sig(UInt8(0x01)))
    var cached = legacy_sighash_cached(tx, 1, cleaned, _legacy_sig(UInt8(0x01)), build_sighash_precompute_for_modes(tx, prevouts, True, False, False))
    assert_equal(bytes_to_hex(cached), bytes_to_hex(reference))

    var profile = HotPathProfile()
    profile.enabled = True
    _ = legacy_sighash_cached_profiled(tx, 0, script, _legacy_sig(UInt8(0x01)), build_sighash_precompute_for_modes(tx, prevouts, True, False, False), profile)
    assert_true(profile.legacy_sighash_cached_calls > 0)
    assert_true(profile.legacy_sighash_reference_calls == 0)


def test_block_delta_batch_apply_and_undo() raises:
    var shim = getenv("MOJOBITNODE_SHIM_PATH", "./build/libmojobitnode_shim.dylib")
    var native = Native(shim)
    var db = native.rocksdb_open(String("/tmp/mojo_block_core_batch_smoke"))
    var suffix = String(native.now_ms())

    var delta = BlockUtxoDelta()
    var txid = List[UInt8]()
    var txid_unspent = List[UInt8]()
    for i in range(32):
        txid.append(UInt8(i))
        txid_unspent.append(UInt8(255 - i))
    var script = List[UInt8]()
    script.append(UInt8(0x51))
    var utxo = Utxo()
    utxo.height = 77
    utxo.value_sats = Int64(12345)
    utxo.coinbase = False
    utxo.script_pubkey = script.copy()

    append_delta_created(delta, txid, UInt32(0), utxo)
    delta.created_spent[0] = True
    assert_equal(block_delta_unspent_created(delta), 0)
    append_delta_undo(delta, 2, 1, txid, UInt32(0), utxo, True)

    var external_key = ascii_string_to_bytes(String("batch_smoke:delete:") + suffix)
    var external_value = ascii_string_to_bytes(String("delete-me"))
    native.rocksdb_put(db, external_key, external_value)
    delta.external_spend_keys.append(external_key.copy())
    delta.external_spends += 1
    append_delta_created(delta, txid_unspent, UInt32(1), utxo)

    delta.block_key = ascii_string_to_bytes(String("batch_smoke:block:") + suffix)
    delta.block_value = ascii_string_to_bytes(String("block-ok"))
    delta.undo_key = ascii_string_to_bytes(String("batch_smoke:undo:") + suffix)
    delta.undo_value = encode_block_undo(77, delta)
    var meta_name = String("batch_smoke_meta_") + suffix
    append_delta_metadata(delta, meta_name, String("meta-ok"))

    assert_equal(len(native.rocksdb_get(db, delta.block_key, 64)), 0)
    var timing = ConnectTiming()
    apply_block_delta(native, db, timing, delta)

    assert_equal(bytes_to_hex(native.rocksdb_get(db, delta.block_key, 64)), bytes_to_hex(delta.block_value))
    assert_true(len(native.rocksdb_get(db, delta.undo_key, 4096)) > 0)
    assert_equal(db_get_string(native, db, meta_name), String("meta-ok"))
    assert_equal(len(native.rocksdb_get(db, external_key, 64)), 0)
    var suppressed_key = _utxo_key(txid, UInt32(0))
    assert_equal(len(native.rocksdb_get(db, suppressed_key, 4096)), 0)
    var created_key = _utxo_key(txid_unspent, UInt32(1))
    assert_true(len(native.rocksdb_get(db, created_key, 4096)) > 0)
    assert_true(timing.rocksdb_write >= 0)
    assert_true(timing.rocksdb_batch_pack >= 0)
    native.rocksdb_close(db)


def test_packed_rocksdb_batch_apply_order() raises:
    var shim = getenv("MOJOBITNODE_SHIM_PATH", "./build/libmojobitnode_shim.dylib")
    var native = Native(shim)
    var db = native.rocksdb_open(String("/tmp/mojo_block_core_packed_batch_smoke"))
    var suffix = String(native.now_ms())

    var key_delete = ascii_string_to_bytes(String("packed:delete:") + suffix)
    var key_put = ascii_string_to_bytes(String("packed:put:") + suffix)
    var value_old = ascii_string_to_bytes(String("old"))
    var value_new = ascii_string_to_bytes(String("new"))
    native.rocksdb_put(db, key_delete, value_old)

    var packed = List[UInt8]()
    packed.append(UInt8(0))
    packed.append(UInt8(0))
    packed.append(UInt8(0))
    packed.append(UInt8(2))
    append_packed_batch_delete(packed, key_delete)
    append_packed_batch_put(packed, key_put, value_new)
    native.rocksdb_batch_apply_packed(db, packed)

    assert_equal(len(native.rocksdb_get(db, key_delete, 64)), 0)
    assert_equal(bytes_to_hex(native.rocksdb_get(db, key_put, 64)), bytes_to_hex(value_new))
    native.rocksdb_close(db)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
