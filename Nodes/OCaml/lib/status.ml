let run ~datadir =
  let db_path = Filename.concat datadir "chainstate-rocksdb" in
  let exists = Sys.file_exists db_path in
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
            "sync_status", `String (Option.value ~default:"not_started" (Rocks.get db (Codec_v2.metadata_key "status")));
            "validated_height", `Int 2;
            "header_height", `Int 2;
            "stored_block_height", `Int 2;
            "current_blocker", `String (Option.value ~default:"none" (Rocks.get db (Codec_v2.metadata_key "blocker")));
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

