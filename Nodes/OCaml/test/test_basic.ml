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

let () =
  Alcotest.run "ocbitnode foundation" [
    ("util", [
      Alcotest.test_case "hex roundtrip" `Quick test_hex_roundtrip;
      Alcotest.test_case "codec metadata key" `Quick test_codec_vector_keys;
      Alcotest.test_case "tx roundtrip" `Quick test_tx_roundtrip;
      Alcotest.test_case "script num and bool" `Quick test_script_num_and_bool;
      Alcotest.test_case "block merkle" `Quick test_block_merkle;
      Alcotest.test_case "rocks multi_get and sync-off batch" `Quick test_rocks_multi_get_and_sync_off_batch;
      Alcotest.test_case "sighash cache equivalence" `Quick test_sighash_cache_equivalence;
      Alcotest.test_case "legacy sighash cache equivalence" `Quick test_legacy_sighash_cache_equivalence;
    ]);
  ]
