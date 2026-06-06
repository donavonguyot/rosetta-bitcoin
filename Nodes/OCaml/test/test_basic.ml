let test_hex_roundtrip () =
  let value = "0001020a0f10ff" in
  Alcotest.(check string) "hex roundtrip" value (Ocbitnode.Util.hex_of_bytes (Ocbitnode.Util.bytes_of_hex value))

let test_codec_vector_keys () =
  let key = Ocbitnode.Codec_v2.metadata_key "codec_version" in
  Alcotest.(check string) "metadata key" "6d0d636f6465635f76657273696f6e" (Ocbitnode.Util.hex_of_bytes key)

let test_tx_roundtrip () =
  let raw =
    Ocbitnode.Util.bytes_of_hex
      "01000000010000000000000000000000000000000000000000000000000000000000000000ffffffff00ffffffff0100f2052a01000000015100000000"
  in
  let tx, consumed = Ocbitnode.Tx.deserialize raw 0 in
  Alcotest.(check int) "consumed" (String.length raw) consumed;
  Alcotest.(check string) "serialized" raw (Ocbitnode.Tx.serialize tx ~include_witness:true)

let test_script_num_and_bool () =
  Alcotest.(check bool) "zero false" false (Ocbitnode.Script_verify.test_cast_to_bool "");
  Alcotest.(check bool) "negative zero false" false (Ocbitnode.Script_verify.test_cast_to_bool "\x80");
  Alcotest.(check bool) "one true" true (Ocbitnode.Script_verify.test_cast_to_bool "\x01");
  Alcotest.(check int64) "decode -1" (-1L) (Ocbitnode.Script_verify.test_decode_script_num "\x81" 4);
  Alcotest.(check string) "encode -1" "\x81" (Ocbitnode.Script_verify.test_encode_script_num (-1L) 4)

let test_block_merkle () =
  let tx_raw =
    Ocbitnode.Util.bytes_of_hex
      "01000000010000000000000000000000000000000000000000000000000000000000000000ffffffff00ffffffff0100f2052a01000000015100000000"
  in
  let raw = String.make 80 '\000' ^ "\001" ^ tx_raw in
  let block = Ocbitnode.Block.parse raw in
  let expected = Ocbitnode.Tx.txid_internal (List.hd block.transactions) in
  Alcotest.(check string) "merkle" expected (Ocbitnode.Block.merkle_root block.transactions)

let test_rocks_multi_get_and_sync_off_batch () =
  let dir = Filename.concat (Filename.get_temp_dir_name ()) ("ocbitnode-rocks-test-" ^ string_of_int (Unix.getpid ())) in
  Ocbitnode.Util.ensure_dir dir;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote dir)))
    (fun () ->
      Ocbitnode.Rocks.with_db dir (fun db ->
          Ocbitnode.Rocks.write_batch db ~disable_wal:false ~sync:false (fun batch ->
              Ocbitnode.Rocks.batch_put batch "a" "one";
              Ocbitnode.Rocks.batch_put batch "b" "two";
              Ocbitnode.Rocks.batch_delete batch "missing");
	      Alcotest.(check (list (option string))) "multi_get"
		[ Some "one"; None; Some "two" ]
		(Ocbitnode.Rocks.multi_get db [ "a"; "z"; "b" ])))

let test_rocks_multi_get_utxos () =
  let open Ocbitnode in
  let dir = Filename.concat (Filename.get_temp_dir_name ()) ("ocbitnode-rocks-utxo-test-" ^ string_of_int (Unix.getpid ())) in
  Util.ensure_dir dir;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote dir)))
    (fun () ->
      Rocks.with_db dir (fun db ->
          let txid_a = String.make 32 '\001' in
          let txid_b = String.make 32 '\002' in
          let script_a = Util.bytes_of_hex "76a914111111111111111111111111111111111111111188ac" in
          let key_a = Codec_v2.utxo_key ~chain:"testnet4" ~txid:txid_a ~vout:1 in
          let key_b = Codec_v2.utxo_key ~chain:"testnet4" ~txid:txid_b ~vout:2 in
          Rocks.write_batch db ~disable_wal:false ~sync:false (fun batch ->
              Rocks.batch_put batch key_a (Codec_v2.utxo_value ~height:101 ~vout:1 ~value_sats:5000L ~coinbase:false ~script_pubkey:script_a);
              Rocks.batch_put batch key_b (Codec_v2.utxo_value ~height:102 ~vout:2 ~value_sats:6000L ~coinbase:true ~script_pubkey:"\x51"));
          let outpoints = [|
            { Rocks.txid = txid_a; vout = 1 };
            { Rocks.txid = String.make 32 '\003'; vout = 9 };
            { Rocks.txid = txid_b; vout = 2 };
            { Rocks.txid = txid_a; vout = 1 };
          |] in
          let rows, stats = Rocks.multi_get_utxos db ~chain:"testnet4" outpoints in
          Alcotest.(check int) "lookup count" 4 stats.lookup_count;
          Alcotest.(check int) "key bytes" (4 * (1 + 1 + String.length "testnet4" + 32 + 4)) stats.key_bytes;
          Alcotest.(check bool) "value bytes positive" true (stats.value_bytes > 0);
          Alcotest.(check int) "result length" 4 (Array.length rows);
          (match rows.(0), rows.(1), rows.(2), rows.(3) with
          | Some a, None, Some b, Some dup ->
              Alcotest.(check int) "a height" 101 a.height;
              Alcotest.(check int64) "a value" 5000L a.value_sats;
              Alcotest.(check string) "a script" script_a a.script_pubkey;
              Alcotest.(check bool) "b coinbase" true b.coinbase;
              Alcotest.(check int) "duplicate vout" a.vout dup.vout
          | _ -> Alcotest.fail "unexpected typed UTXO multi_get result")))

let test_sighash_cache_equivalence () =
  let open Ocbitnode in
  let p2wpkh_script = Util.bytes_of_hex "00141111111111111111111111111111111111111111" in
  let p2tr_script = Util.bytes_of_hex ("5120" ^ String.make 64 '2') in
  let p2pkh_script_code = Util.bytes_of_hex "76a914111111111111111111111111111111111111111188ac" in
  let tx : Tx.t =
    {
      version = 2l;
      inputs =
        [
          { previous_output = { hash = Tx.parse_display_hash (String.make 64 'a'); index = 0l }; script_sig = ""; sequence = 0xfffffffdl };
          { previous_output = { hash = Tx.parse_display_hash (String.make 64 'b'); index = 1l }; script_sig = ""; sequence = 0xfffffffel };
        ];
      outputs =
        [
          { value = 900L; script_pubkey = p2wpkh_script };
          { value = 800L; script_pubkey = p2tr_script };
        ];
      lock_time = 0l;
      witness = [];
    }
  in
  let prevouts : Script_verify.spent_prevout list =
    [
      { amount = 1000L; script_pubkey = p2wpkh_script };
      { amount = 2000L; script_pubkey = p2tr_script };
    ]
  in
  List.iter
    (fun sighash_type ->
      Alcotest.(check string)
        ("bip143 cached " ^ string_of_int sighash_type)
        (Script_verify.test_bip143_sighash tx 0 p2pkh_script_code 1000L sighash_type)
        (Script_verify.test_bip143_sighash_cached tx prevouts 0 p2pkh_script_code 1000L sighash_type))
    [ 1; 3; 0x81 ];
  List.iter
    (fun hash_type ->
      Alcotest.(check string)
        ("taproot cached " ^ string_of_int hash_type)
        (Script_verify.test_taproot_sighash tx 1 prevouts hash_type)
        (Script_verify.test_taproot_sighash_cached tx 1 prevouts hash_type))
    [ 0; 1; 3; 0x81 ]

let test_legacy_sighash_cache_equivalence () =
  let open Ocbitnode in
  let fake_hash index = String.make 64 "0123456789abcdef".[index land 0xf] in
  let p2pkh_script_code = Util.bytes_of_hex "76a914111111111111111111111111111111111111111188ac" in
  let tx : Tx.t =
    {
      version = 1l;
      inputs =
        List.init 6 (fun index ->
            {
              Tx.previous_output = { Tx.hash = Tx.parse_display_hash (fake_hash index); index = Int32.of_int index };
              script_sig = "";
              sequence = Int32.of_int (0xfffffffe - index);
            });
      outputs =
        [
          { value = 900L; script_pubkey = p2pkh_script_code };
          { value = 800L; script_pubkey = p2pkh_script_code };
          { value = 700L; script_pubkey = p2pkh_script_code };
        ];
      lock_time = 0l;
      witness = [];
    }
  in
  let prevouts = List.map (fun _ -> { Script_verify.amount = 1000L; script_pubkey = p2pkh_script_code }) tx.inputs in
  List.iter
    (fun sighash_type ->
      Alcotest.(check string)
        ("legacy cached " ^ string_of_int sighash_type)
        (Script_verify.test_legacy_sighash tx 2 p2pkh_script_code sighash_type)
        (Script_verify.test_legacy_sighash_cached tx prevouts 2 p2pkh_script_code sighash_type))
    [ 1; 2; 3; 0x81 ]

let test_worker_verifier_lifecycle_and_ecdsa () =
  let open Ocbitnode in
  let pubkey = Util.bytes_of_hex "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798" in
  let msg_hash = Util.bytes_of_hex "281dd50f6f56bc6e867fe73dd614a73c55a647a479704f64804b574cafb0f5c5" in
  let signature =
    Util.bytes_of_hex
      "3044022079be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f8179802205e23c47196cc87e523dfb62c5b644dbb626c9867080a27fde59485e5098d33e4"
  in
  let verifier = Crypto.create_worker_verifier () in
  Fun.protect
    ~finally:(fun () ->
      Crypto.close_verifier verifier;
      Crypto.close_verifier verifier)
    (fun () ->
      Alcotest.(check string) "worker context mode" "libsecp256k1/reused_context_per_worker" (Crypto.verifier_context_mode verifier);
      Alcotest.(check bool) "worker ecdsa matches raw" true
        (Crypto.ecdsa_verify_bytes_with_verifier ~verifier ~pubkey ~msg_hash ~signature_der:signature);
      Alcotest.(check bool) "raw ecdsa valid" true (Crypto.ecdsa_verify_bytes ~pubkey ~msg_hash ~signature_der:signature))

let () =
  Alcotest.run "ocbitnode foundation" [
    ("util", [
      Alcotest.test_case "hex roundtrip" `Quick test_hex_roundtrip;
      Alcotest.test_case "codec metadata key" `Quick test_codec_vector_keys;
      Alcotest.test_case "tx roundtrip" `Quick test_tx_roundtrip;
      Alcotest.test_case "script num and bool" `Quick test_script_num_and_bool;
	      Alcotest.test_case "block merkle" `Quick test_block_merkle;
	      Alcotest.test_case "rocks multi_get and sync-off batch" `Quick test_rocks_multi_get_and_sync_off_batch;
	      Alcotest.test_case "rocks typed UTXO multi_get" `Quick test_rocks_multi_get_utxos;
	      Alcotest.test_case "sighash cache equivalence" `Quick test_sighash_cache_equivalence;
      Alcotest.test_case "legacy sighash cache equivalence" `Quick test_legacy_sighash_cache_equivalence;
      Alcotest.test_case "worker verifier lifecycle and ecdsa" `Quick test_worker_verifier_lifecycle_and_ecdsa;
    ]);
  ]
