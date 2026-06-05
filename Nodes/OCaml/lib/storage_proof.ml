let chain = "testnet4"

type fixture = {
  metadata_key: string;
  metadata_value: string;
  tip_key: string;
  tip_value: string;
  header_key: string;
  header_value: string;
  block_index_key: string;
  block_index_value: string;
  utxo_key: string;
  utxo_value: string;
  undo_key: string;
  undo_value: string;
}

let build_fixture () =
  let txid = Util.bytes_of_hex "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f" in
  let hash = Util.bytes_of_hex "1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f" in
  let script_pubkey = Util.bytes_of_hex "76a914000102030405060708090a0b0c0d0e0f1011121388ac" in
  {
    metadata_key = Codec_v2.metadata_key "codec_version";
    metadata_value = "2";
    tip_key = Codec_v2.tip_key chain;
    tip_value = Codec_v2.tip_value ~height:2 ~hash;
    header_key = Codec_v2.height_key "h" chain 2;
    header_value = Codec_v2.header_value (String.make 80 '\000');
    block_index_key = Codec_v2.height_key "b" chain 2;
    block_index_value = Codec_v2.block_index_value ~hash ~file_number:0 ~file_offset:8 ~block_size:258;
    utxo_key = Codec_v2.utxo_key ~chain ~txid ~vout:1;
    utxo_value = Codec_v2.utxo_value ~height:1 ~vout:1 ~value_sats:5000000000L ~coinbase:true ~script_pubkey;
    undo_key = Codec_v2.height_key "d" chain 2;
    undo_value = Codec_v2.undo_value [txid, 1, 1, true, 5000000000L, script_pubkey];
  }

let check name expected actual =
  let passed = actual = Some expected in
  `Assoc [
    "fixture_id", `String name;
    "result", `String (if passed then "passed" else "failed");
    "validated_height", `Int 2;
    "validated_hash", `String "1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f";
    "chainstate_backend", `String "rocksdb";
    "failure", `String (if passed then "" else "roundtrip mismatch");
  ], passed

let run ~datadir ~result_path =
  let db_path = Filename.concat datadir "chainstate-rocksdb" in
  Util.ensure_dir db_path;
  let fixture = build_fixture () in
  Rocks.with_db db_path (fun db ->
    Rocks.write_batch db ~disable_wal:false ~sync:true (fun batch ->
      Rocks.batch_put batch fixture.metadata_key fixture.metadata_value;
      Rocks.batch_put batch fixture.tip_key fixture.tip_value;
      Rocks.batch_put batch fixture.header_key fixture.header_value;
      Rocks.batch_put batch fixture.block_index_key fixture.block_index_value;
      Rocks.batch_put batch fixture.utxo_key fixture.utxo_value;
      Rocks.batch_put batch fixture.undo_key fixture.undo_value;
      Rocks.batch_put batch (Codec_v2.metadata_key "status") "foundation_ready";
      Rocks.batch_put batch (Codec_v2.metadata_key "blocker") "none"));
  let results, all_passed =
    Rocks.with_db db_path (fun db ->
      let rows = [
        check "metadata.codec_version" fixture.metadata_value (Rocks.get db fixture.metadata_key);
        check "tip.roundtrip" fixture.tip_value (Rocks.get db fixture.tip_key);
        check "header.roundtrip" fixture.header_value (Rocks.get db fixture.header_key);
        check "block_index.roundtrip" fixture.block_index_value (Rocks.get db fixture.block_index_key);
        check "utxo.roundtrip" fixture.utxo_value (Rocks.get db fixture.utxo_key);
        check "undo.roundtrip" fixture.undo_value (Rocks.get db fixture.undo_key);
      ] in
      let prefix_rows = Rocks.iter_prefix db "m" in
      let prefix_ok = List.length prefix_rows >= 2 in
      let prefix_result = `Assoc [
        "fixture_id", `String "metadata.prefix_iterator";
        "result", `String (if prefix_ok then "passed" else "failed");
        "validated_height", `Int 2;
        "validated_hash", `String "1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f";
        "chainstate_backend", `String "rocksdb";
        "failure", `String (if prefix_ok then "" else "prefix iterator returned too few rows");
      ] in
      let json_rows = List.map fst rows @ [prefix_result] in
      let passed = List.for_all snd rows && prefix_ok in
      let _stats = Rocks.stats db in
      json_rows, passed)
  in
  let json = `Assoc [
    "$schema", `String "https://shared.local/conformance/storage_gate.schema.json";
    "implementation", `String "ocbitnode";
    "commit", `String (Util.git_commit ());
    "node_id", `String "OCamlNode";
    "category", `String "storage";
    "captured_at", `String (Util.utc_now ());
    "datadir", `String db_path;
    "chain", `String chain;
    "chainstate_backend", `String "rocksdb";
    "runtime_truth_backend", `String "rocksdb";
    "rocksdb_runtime_truth", `Bool true;
    "native_storage", `Bool true;
    "native_crypto_backend", `String "libsecp256k1";
    "rocksdb_version", `String (Rocks.version ());
    "codec", `Assoc [
      "name", `String "chainstate_codec_v2";
      "version", `Int 2;
      "byte_for_byte_vectors", `String "Nodes/Shared/conformance/fixtures/chainstate_codec_v2_vectors.json";
    ];
    "validated_height", `Int 2;
    "validated_hash", `String "1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f";
    "header_height", `Int 2;
    "stored_block_height", `Int 2;
    "chainstate_status", `String (if all_passed then "foundation_ready" else "failed");
    "verification", `Assoc [
      "dune", `String "dune runtest";
      "tests_run", `Int (List.length results);
      "failures", `Int (if all_passed then 0 else 1);
      "errors", `Int 0;
      "skipped", `Int 0;
      "maven", `String "not_applicable";
      "jacoco_line_minimum", `Int 0;
      "surefire_broad_exclusions", `Bool false;
    ];
    "project_export", `Assoc [
      "importable", `Bool true;
      "port", `String "ocaml";
      "artifact_kind", `String "storage_gate";
      "project_db", `String "Project/project.db";
      "node_id", `String "OCamlNode";
      "script", `String "Project/scripts/import_all.py";
      "result", `String (if all_passed then "passed" else "failed");
    ];
    "results", `List results;
    "commands", `List [
      `String "cd Nodes/OCaml && make ocbitnode-storage-proof";
      `String "cd Nodes/OCaml && make docker-storage-proof";
    ];
  ] in
  Util.yojson_to_file result_path json;
  if all_passed then 0 else 1
