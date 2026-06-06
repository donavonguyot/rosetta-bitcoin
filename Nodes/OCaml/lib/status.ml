let run ~datadir =
  let db_path = Filename.concat datadir "chainstate-rocksdb" in
  let exists = Sys.file_exists db_path in
  let int_meta db name default =
    match Rocks.get db (Codec_v2.metadata_key name) with
    | Some value -> (try int_of_string value with _ -> default)
    | None -> default
  in
  let string_meta db name default =
    Option.value ~default (Rocks.get db (Codec_v2.metadata_key name))
  in
  let fields =
    if exists then
      try
        Rocks.with_db db_path (fun db ->
          [
            "chainstate_backend", `String "rocksdb";
            "runtime_truth_backend", `String "rocksdb";
            "rocksdb_runtime_truth", `Bool true;
            "native_storage", `Bool true;
            "rocksdb_version", `String (Rocks.version ());
            "sync_status", `String (string_meta db "status" "not_started");
            "validated_height", `Int (int_meta db "validated_height" 2);
            "header_height", `Int (int_meta db "header_height" 2);
            "stored_block_height", `Int (int_meta db "stored_block_height" 2);
            "validated_hash", `String (string_meta db "validated_hash" "");
            "chainstate_utxo_count", `Int (int_meta db "chainstate_utxo_count" (-1));
            "utxo_accounting_policy", `String (string_meta db "utxo_accounting_policy" "");
            "native_crypto_backend", `String (string_meta db "native_crypto_backend" "libsecp256k1");
            "current_blocker", `String (string_meta db "blocker" "none");
          ])
      with _ ->
        [
          "chainstate_backend", `String "rocksdb";
          "runtime_truth_backend", `String "rocksdb";
          "rocksdb_runtime_truth", `Bool false;
          "native_storage", `Bool true;
          "sync_status", `String "unreadable";
          "validated_height", `Int 0;
          "header_height", `Int 0;
          "stored_block_height", `Int 0;
          "current_blocker", `String "status_open_failed";
        ]
    else
      [
        "chainstate_backend", `String "rocksdb";
        "runtime_truth_backend", `String "rocksdb";
        "rocksdb_runtime_truth", `Bool false;
        "native_storage", `Bool true;
        "sync_status", `String "not_started";
        "validated_height", `Int 0;
        "header_height", `Int 0;
        "stored_block_height", `Int 0;
        "current_blocker", `String "none";
      ]
  in
  let json = `Assoc ([
    "schema", `String "ocbitnode.status.v1";
    "implementation", `String "ocbitnode";
    "node_id", `String "OCamlNode";
    "port", `String "ocaml";
    "chain", `String "testnet4";
    "datadir", `String datadir;
    "chainstate_path", `String db_path;
    "p2p_sync", `String "not_implemented";
    "binary_gate_status", `String "not_attempted";
    "captured_at", `String (Util.utc_now ());
  ] @ fields) in
  print_endline (Yojson.Safe.pretty_to_string json);
  0
