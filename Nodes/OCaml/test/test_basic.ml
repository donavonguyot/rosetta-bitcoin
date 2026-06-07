let test_hex_roundtrip () =
  let value = "0001020a0f10ff" in
  Alcotest.(check string) "hex roundtrip" value (Ocbitnode.Util.hex_of_bytes (Ocbitnode.Util.bytes_of_hex value))

let test_codec_vector_keys () =
  let key = Ocbitnode.Codec_v2.metadata_key "codec_version" in
  Alcotest.(check string) "metadata key" "6d0d636f6465635f76657273696f6e" (Ocbitnode.Util.hex_of_bytes key);
  Alcotest.(check string) "compact size fc" "fc" (Ocbitnode.Util.hex_of_bytes (Ocbitnode.Codec_v2.compact_size 0xfc));
  Alcotest.(check string) "compact size fd" "fdfd00" (Ocbitnode.Util.hex_of_bytes (Ocbitnode.Codec_v2.compact_size 0xfd));
  Alcotest.(check string) "compact size 256" "fd0001" (Ocbitnode.Util.hex_of_bytes (Ocbitnode.Codec_v2.compact_size 0x100));
  Alcotest.(check string) "compact size 65536" "fe00000100" (Ocbitnode.Util.hex_of_bytes (Ocbitnode.Codec_v2.compact_size 0x10000))

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
  Alcotest.(check bool) "nonzero ending sign byte true" true (Ocbitnode.Script_verify.test_cast_to_bool "\x01\x80");
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

let block_52404_spend_hex =
  "0200000000010d979f9593e81ec068c4b2297fdf505d62e1e2753da26858f229f0b77713b9f00b0300000000fffffffff7c72af6d12c8249cf169e3187acec03a4baf48d1f37572a9e9cb9783605b42e0000000000fffffffff7c72af6d12c8249cf169e3187acec03a4baf48d1f37572a9e9cb9783605b42e0100000000fffffffff7c72af6d12c8249cf169e3187acec03a4baf48d1f37572a9e9cb9783605b42e0200000000fffffffff7c72af6d12c8249cf169e3187acec03a4baf48d1f37572a9e9cb9783605b42e0300000000fffffffff7c72af6d12c8249cf169e3187acec03a4baf48d1f37572a9e9cb9783605b42e0400000000fffffffff7c72af6d12c8249cf169e3187acec03a4baf48d1f37572a9e9cb9783605b42e0500000000fffffffff7c72af6d12c8249cf169e3187acec03a4baf48d1f37572a9e9cb9783605b42e0600000000fffffffff7c72af6d12c8249cf169e3187acec03a4baf48d1f37572a9e9cb9783605b42e0700000000fffffffff7c72af6d12c8249cf169e3187acec03a4baf48d1f37572a9e9cb9783605b42e0800000000fffffffff7c72af6d12c8249cf169e3187acec03a4baf48d1f37572a9e9cb9783605b42e0900000000fffffffff7c72af6d12c8249cf169e3187acec03a4baf48d1f37572a9e9cb9783605b42e0a00000000fffffffff7c72af6d12c8249cf169e3187acec03a4baf48d1f37572a9e9cb9783605b42e0b00000000ffffffff0d22020000000000002251206ba53a31f00fffdce9c40d7e6bd0f063ce039fed7ad9e258b0881d973f4bd5b32202000000000000225120ba0fe2d7ece9728521e3fdcf88d7af69eb7556a47c957187ebe213e0c8444f692202000000000000225120076911a51bf842e262921f97d74bf267d6609e0d05aa07853c9b1bf0cc590aff22020000000000002251207e5940746c2e8467a4a628408e05707e0f1f620cd6a46ff2620c88787e51c9632202000000000000225120d62affdf6641dd068604b6134dbafd76e33e28705bdcef6a1a4a194dc348e2a822020000000000002251206312cbc37a340e129cffb3dc5dafc18b1b8f18412c524d603c15cd5510c58570220200000000000022512007dfd1c944099768ee2f5fe115475e83119fdedeb9bfbfe743f486d20462ea83220200000000000022512024c489afe6a8a60f1625f88c07cd7c77aa63ff70c8f10380351daf325a73809822020000000000002251207562c1387cfb0fe73e07292dd613a13008d550fa8268f6b077c709e0da47e77622020000000000002251205933b0cf5553e219a3fd9a3b04a764684775bd6829e74b90765613675533e3e32202000000000000225120b23221f53ddd736e98ccb3ff9a049edac9d91aef6adb8dd3fd8ed734b425ad1722020000000000002251203983e2ba10134ac5093261d4114db766031bee67f362e02ee002d8b2b55f41132406000000000000225120874e953e1f4c61f099220507668ca3d8e4e6f9c2ee118d35989ac024b37faed0034072f0f9fbe75852370a9354e3213e1d7de0ac630093d6e4d8f24affe99b7e4e8932e1271950335cd9ee21bd258f0f0face74a30361564c26f156d4634aa3ee9074520880432461a43420a669374a30f847985df5f12b704d9faa9302b2106cf659e75ac632044ddea4459edcd14166de09a3638d7c39801c5750dd46be61add1d2ed1f45bc36821c0880432461a43420a669374a30f847985df5f12b704d9faa9302b2106cf659e75034098f0e947a8592fc1ee923190927cb3bbc2d756c1ea34794820c44a2c17b71320a5d47ddce15dd5480f0961a6e98c019079c14c474e52825b8f1cb4ca744db3594520880432461a43420a669374a30f847985df5f12b704d9faa9302b2106cf659e75ac63207bcf7600129bf42e088d1cf3a84099532d03c8b5f153e15680600c5027e4410f6821c0880432461a43420a669374a30f847985df5f12b704d9faa9302b2106cf659e750340c38df0284362247e8a2cfdfdc4b8a4299760fde4dd51c0b8406e787ba3bf96bfd7c66532fee7435c89775dc8bde58e3584f3837807da035c8ab25b4e14baa2104520880432461a43420a669374a30f847985df5f12b704d9faa9302b2106cf659e75ac6320caf442278091392eaf52745bea18c7e5c2d6b8fd23b1639e98fab8204b00e3806821c0880432461a43420a669374a30f847985df5f12b704d9faa9302b2106cf659e750340b18ecc89db0eb636004ae1beb093e4a13bf6d63c7ea0fa78d46fcfae8255505f0d8da4558f96c232c0ed4ed6cfe603ca91085ceed95495c9f48c4611e773c0484520880432461a43420a669374a30f847985df5f12b704d9faa9302b2106cf659e75ac6320c08bcae6f60e9176742c0acdc2827596b9ccb038fb824b9d019afc144ee49c376821c0880432461a43420a669374a30f847985df5f12b704d9faa9302b2106cf659e7503403248a697356c418044ffaac27af3f3fe232e531c1de71b90cae35cab3829bdc87516e0299e22a5cee91c23acc41e4fecfc633cae069c68d7beee397ef0fa97124520880432461a43420a669374a30f847985df5f12b704d9faa9302b2106cf659e75ac6320c7498d7ad3a7ba8a582681ec17cd2372dfcf79f2bd597bd16bbf9d476db0b8de6821c1880432461a43420a669374a30f847985df5f12b704d9faa9302b2106cf659e7503402036cb9e1640d71a9090330c918801bcb50f2758d93e4177e7a1c4ed616c9fa82b51d4cdd4c84f363ff47018df00e9e2e2e34694c2219db2cd0815408f5d60c74520880432461a43420a669374a30f847985df5f12b704d9faa9302b2106cf659e75ac63200af8d583a7958bb601895549b76546592817c54b6ecabca2aae61ec3998c36d26821c1880432461a43420a669374a30f847985df5f12b704d9faa9302b2106cf659e750340a4a4e5da6fe10ddd873dc98d3eacd1f00c458499b14f4aee02b3a73662a69b7d0240ad912bfda3f69ced625a38cf9656b94170df2e30ad2a67b67975f6b1fa934520880432461a43420a669374a30f847985df5f12b704d9faa9302b2106cf659e75ac6320b6cde3f0628d80fc3ea3f5e2d905aa2e4bfa1b61415224410b3b8fbe459b02676821c0880432461a43420a669374a30f847985df5f12b704d9faa9302b2106cf659e750340f5c0180596d6c61087b5768dad46280b5f576fae704747eb551e74502f76723077dddd4e6622ede66dc84c6fb984e5ec7e94f133e3b50a75f175f654b33776de4520880432461a43420a669374a30f847985df5f12b704d9faa9302b2106cf659e75ac6320aa304c7144d901d2d76142d0c51bf79889f05c82eda2a6533cdeff8d9cd324986821c0880432461a43420a669374a30f847985df5f12b704d9faa9302b2106cf659e750340da527e0f5034451c4ccc5a536c1ab8fae24a2af9f1cce32d160b344df824cbdc0622741843b446a4eac97057aceefaf3fedf0a10bf1672bc5ee223856e1e2ceb4520880432461a43420a669374a30f847985df5f12b704d9faa9302b2106cf659e75ac63200366900416d14c8fb257298726cd47356b6642bc878ecbcde53ada09888c8e496821c0880432461a43420a669374a30f847985df5f12b704d9faa9302b2106cf659e750340bfc1bf5d49b0274c27492a7b18f84e012fa37a9087333701709aef9d904567bdc63f54dbd0219af1db84385819e572d0b2facf5e2646933b84158a088c73a0df4520880432461a43420a669374a30f847985df5f12b704d9faa9302b2106cf659e75ac6320b1d2e7d02d48bbbcfdf7effe51a7a69337da8f12640b7192f934fbc3a9a558cc6821c0880432461a43420a669374a30f847985df5f12b704d9faa9302b2106cf659e750340c6bde61ff02fa2bad90726318752900da6e872a457ce6dd1ec386291e2de86f198948ddeec2009cc0b4ed7be7b248c46882a351172756efacd6571b06a64c13c4520880432461a43420a669374a30f847985df5f12b704d9faa9302b2106cf659e75ac6320c834968002d8dfde07a7fc2d5a3207e732e75a5e43c3b2cdd4b17315e399b3946821c1880432461a43420a669374a30f847985df5f12b704d9faa9302b2106cf659e7503406604478ef4fdecc110e43728cb862ead82f99d08842b43c33e9d1c8aeaab3458a77732e052fa58ec8686378fd8921e57f889545ed751868c0542cba7a686506a4520880432461a43420a669374a30f847985df5f12b704d9faa9302b2106cf659e75ac63200a7218545bbd9b5cd2f29d6f71d6e5df299cd7d2fa72d6c968aeb98054347e016821c0880432461a43420a669374a30f847985df5f12b704d9faa9302b2106cf659e7503400da98a46a1bf12cfc3b9d730cc042a6dfc22309a9cc87f3448dc2ba8404d665d1078f14cae8c9b7715374c8452fa6bc6ced5d29139f96820501987022342586f4520880432461a43420a669374a30f847985df5f12b704d9faa9302b2106cf659e75ac6320bc474e86767264abb42370a134f7eebf78a5e38561fc2b8373a4b056da2a0ec86821c0880432461a43420a669374a30f847985df5f12b704d9faa9302b2106cf659e7500000000"

let block_52404_prevouts =
  [
    (546L, "51206ba53a31f00fffdce9c40d7e6bd0f063ce039fed7ad9e258b0881d973f4bd5b3");
    (546L, "5120ba0fe2d7ece9728521e3fdcf88d7af69eb7556a47c957187ebe213e0c8444f69");
    (546L, "5120076911a51bf842e262921f97d74bf267d6609e0d05aa07853c9b1bf0cc590aff");
    (546L, "51207e5940746c2e8467a4a628408e05707e0f1f620cd6a46ff2620c88787e51c963");
    (546L, "5120d62affdf6641dd068604b6134dbafd76e33e28705bdcef6a1a4a194dc348e2a8");
    (546L, "51206312cbc37a340e129cffb3dc5dafc18b1b8f18412c524d603c15cd5510c58570");
    (546L, "512007dfd1c944099768ee2f5fe115475e83119fdedeb9bfbfe743f486d20462ea83");
    (546L, "512024c489afe6a8a60f1625f88c07cd7c77aa63ff70c8f10380351daf325a738098");
    (546L, "51207562c1387cfb0fe73e07292dd613a13008d550fa8268f6b077c709e0da47e776");
    (546L, "51205933b0cf5553e219a3fd9a3b04a764684775bd6829e74b90765613675533e3e3");
    (546L, "5120b23221f53ddd736e98ccb3ff9a049edac9d91aef6adb8dd3fd8ed734b425ad17");
    (546L, "51203983e2ba10134ac5093261d4114db766031bee67f362e02ee002d8b2b55f4113");
    (15288L, "5120874e953e1f4c61f099220507668ca3d8e4e6f9c2ee118d35989ac024b37faed0");
  ]

let block_52404_tx_and_prevouts () =
  let open Ocbitnode in
  let raw = Util.bytes_of_hex block_52404_spend_hex in
  let tx, consumed = Tx.deserialize raw 0 in
  Alcotest.(check int) "52404 tx consumed" (String.length raw) consumed;
  let prevouts =
    List.map
      (fun (amount, script_hex) -> { Script_verify.amount; script_pubkey = Util.bytes_of_hex script_hex })
      block_52404_prevouts
  in
  tx, prevouts

let test_block_52404_tapscript_verify () =
  let open Ocbitnode in
  let tx, prevouts = block_52404_tx_and_prevouts () in
  let prevout = List.nth prevouts 2 in
  match Script_verify.verify_transaction_input tx 2 { script_pubkey = prevout.script_pubkey; amount = prevout.amount; spent_prevouts = prevouts } with
  | Ok () -> ()
  | Error message -> Alcotest.fail ("block 52404 input 2 should verify: " ^ message)

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
      Alcotest.test_case "block 52404 tapscript verify" `Quick test_block_52404_tapscript_verify;
      Alcotest.test_case "worker verifier lifecycle and ecdsa" `Quick test_worker_verifier_lifecycle_and_ecdsa;
    ]);
  ]
