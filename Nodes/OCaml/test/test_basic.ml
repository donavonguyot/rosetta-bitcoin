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

let () =
  Alcotest.run "ocbitnode foundation" [
    ("util", [
      Alcotest.test_case "hex roundtrip" `Quick test_hex_roundtrip;
      Alcotest.test_case "codec metadata key" `Quick test_codec_vector_keys;
      Alcotest.test_case "tx roundtrip" `Quick test_tx_roundtrip;
      Alcotest.test_case "script num and bool" `Quick test_script_num_and_bool;
      Alcotest.test_case "block merkle" `Quick test_block_merkle;
    ]);
  ]
