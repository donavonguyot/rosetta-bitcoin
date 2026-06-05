let assoc_fields = function
  | `Assoc fields -> fields
  | _ -> []

let json_int64 name json =
  match Util.json_member name json with
  | Some (`Int value) -> Int64.of_int value
  | Some (`Intlit value) -> Int64.of_string value
  | _ -> 0L

let files_map fixture =
  match Util.json_member "files" fixture with
  | Some (`Assoc fields) -> fields
  | _ -> []

let files_for fixture category =
  match List.assoc_opt category (files_map fixture) with
  | Some (`List rows) -> List.filter_map (function `String path -> Some path | _ -> None) rows
  | _ -> []

let first_file manifest_dir fixture category =
  match files_for fixture category with
  | path :: _ -> Some (Filename.concat manifest_dir path)
  | [] -> None

let read_hex_file path =
  let text = Util.read_file path in
  text
  |> String.split_on_char '\n'
  |> List.map String.trim
  |> String.concat ""
  |> String.split_on_char ' '
  |> List.map String.trim
  |> String.concat ""
  |> Util.bytes_of_hex

let source_file_hashes manifest_dir fixture =
  let rows =
    files_map fixture
    |> List.concat_map (fun (_category, json) ->
           match json with
           | `List paths -> List.filter_map (function `String path -> Some path | _ -> None) paths
           | _ -> [])
  in
  let checked =
    List.map
      (fun relative ->
        let path = Filename.concat manifest_dir relative in
        let content = Util.read_file path in
        relative, Util.sha256_hex content)
      rows
  in
  let file_sha256 = `Assoc (List.map (fun (path, sha) -> path, `String sha) checked) in
  let loaded_files = List.length checked in
  loaded_files, file_sha256, List.map fst checked

let load_prevouts manifest_dir fixture =
  match first_file manifest_dir fixture "prevouts" with
  | None ->
      let spk_path =
        match first_file manifest_dir fixture "prev_spk" with
        | Some path -> path
        | None -> failwith "fixture has no prevouts or prev_spk file"
      in
      [ { Script_verify.amount = json_int64 "prev_amount_sats" fixture; script_pubkey = read_hex_file spk_path } ]
  | Some path ->
      let parsed = Yojson.Safe.from_file path in
      (match parsed with
      | `List rows ->
          List.map
            (fun row ->
              let amount =
                match Util.json_member "amount_sats" row with
                | Some _ -> json_int64 "amount_sats" row
                | None -> (
                    match Util.json_member "amount" row with
                    | Some _ -> json_int64 "amount" row
                    | None -> json_int64 "value" row)
              in
              let script_hex =
                [ Util.json_string "spk" row; Util.json_string "script_pubkey" row; Util.json_string "scriptPubKey" row ]
                |> List.find_opt (fun value -> value <> "")
                |> Option.value ~default:""
              in
              if script_hex = "" then failwith "prevout missing script_pubkey";
              { Script_verify.amount; script_pubkey = Util.bytes_of_hex script_hex })
            rows
      | _ -> failwith "prevouts JSON must be a list")

let align_prevouts manifest_dir fixture transaction =
  let prevouts = load_prevouts manifest_dir fixture in
  if List.length prevouts = List.length transaction.Tx.inputs then prevouts
  else
    let input_index = Util.json_int "input_index" fixture in
    let target =
      if input_index < List.length prevouts then List.nth prevouts input_index
      else
        match prevouts with
        | first :: _ -> first
        | [] -> failwith "fixture has no prevout records"
    in
    let rec pad rows =
      if List.length rows >= List.length transaction.Tx.inputs then rows
      else pad (rows @ [ { Script_verify.amount = 0L; script_pubkey = "" } ])
    in
    pad prevouts |> List.mapi (fun index row -> if index = input_index then target else row)

let verify_fixture manifest_dir fixture =
  if Util.json_string "expected_result" fixture <> "valid" then failwith "unsupported non-valid fixture";
  let tx_path =
    match first_file manifest_dir fixture "tx" with
    | Some path -> path
    | None -> failwith "fixture has no transaction file"
  in
  let raw = read_hex_file tx_path in
  let transaction, consumed = Tx.deserialize raw 0 in
  if consumed <> String.length raw then failwith "transaction parser did not consume full fixture";
  let input_index = Util.json_int "input_index" fixture in
  let prevouts = align_prevouts manifest_dir fixture transaction in
  if input_index >= List.length prevouts then failwith "fixture input_index has no matching prevout";
  let target = List.nth prevouts input_index in
  match
    Script_verify.verify_transaction_input transaction input_index
      { script_pubkey = target.script_pubkey; amount = target.amount; spent_prevouts = prevouts }
  with
  | Ok () -> Ok ()
  | Error message -> Error message

let fixture_result manifest_dir fixture =
  let fixture_id = Util.json_string "fixture_id" fixture in
  let loaded_files, file_sha256, loaded_paths = source_file_hashes manifest_dir fixture in
  let result, failure, failure_stage, failure_type =
    try
      match verify_fixture manifest_dir fixture with
      | Ok () -> "passed", "", "", ""
      | Error message -> "failed", message, "script_verify", "consensus"
    with
    | Tx.Parse_error message -> "failed", message, "tx_parse", "parse"
    | Script_verify.Script_error message -> "failed", message, "script_verify", "consensus"
    | Failure message -> "failed", message, "load", "fixture"
    | Invalid_argument message -> "failed", message, "load", "fixture"
    | exn -> "failed", Printexc.to_string exn, "unknown", "exception"
  in
  `Assoc [
    "fixture_id", `String fixture_id;
    "height", `Int (Util.json_int "height" fixture);
    "block_hash", `String (Util.json_string "block_hash" fixture);
    "txid", `String (Util.json_string "txid" fixture);
    "input_index", `Int (Util.json_int "input_index" fixture);
    "expected_result", `String (Util.json_string "expected_result" fixture);
    "result", `String result;
    "failure", `String failure;
    "failure_stage", `String failure_stage;
    "failure_type", `String failure_type;
    "loaded_files", `Int loaded_files;
    "loaded_file_paths", `List (List.map (fun path -> `String path) loaded_paths);
    "file_sha256", file_sha256;
  ]

let run ~manifest_path ~result_path ~runtime_surface ?fixture_id () =
  let manifest = Yojson.Safe.from_file manifest_path in
  let manifest_dir = Filename.dirname manifest_path in
  let fixtures = Util.json_list "fixtures" manifest in
  let expected_count = Util.json_int "fixture_count" manifest in
  if expected_count <> 45 && fixture_id = None then failwith "shared script manifest fixture_count must be 45";
  if List.length fixtures <> expected_count && fixture_id = None then failwith "shared script manifest fixture list length mismatch";
  let selected =
    match fixture_id with
    | Some wanted -> List.filter (fun fixture -> Util.json_string "fixture_id" fixture = wanted) fixtures
    | None -> fixtures
  in
  if fixture_id <> None && selected = [] then failwith "fixture-id not found in manifest";
  let results = List.map (fixture_result manifest_dir) selected in
  let passed =
    List.fold_left
      (fun count result -> if Util.json_string "result" result = "passed" then count + 1 else count)
      0 results
  in
  let failed = List.length results - passed in
  let importer_fixtures =
    List.map
      (fun result ->
        `Assoc [
          "fixture_id", `String (Util.json_string "fixture_id" result);
          "height", `Int (Util.json_int "height" result);
          "structural_status", `String (if Util.json_string "result" result = "passed" then "complete" else "failed");
          "errors", `List (if Util.json_string "failure" result = "" then [] else [ `String (Util.json_string "failure" result) ]);
        ])
      results
  in
  let json = `Assoc [
    "schema", `String "port.script_corpus_result.v1";
    "category", `String "script_corpus";
    "result", `String (if failed = 0 then "passed" else "failed");
    "port", `String "ocaml";
    "implementation", `String "ocbitnode";
    "node_id", `String "OCamlNode";
    "runtime_surface", `String runtime_surface;
    "captured_at", `String (Util.utc_now ());
    "commit", `String (Util.git_commit ());
    "manifest", `String manifest_path;
    "fixture_count", `Int (List.length results);
    "loaded", `Int passed;
    "passed", `Int passed;
    "failed", `Int failed;
    "not_implemented", `Int 0;
    "native_crypto_backend", `String "libsecp256k1";
    "verifier", `Assoc [
      "engine", `String "ocbitnode-native-script";
      "crypto_backend", `String "libsecp256k1";
      "source", `String "Nodes/OCaml/lib/script_verify.ml";
      "delegated", `Bool false;
      "note", `String "OCaml runs an independent native script verifier over the shared script corpus.";
    ];
    "fixtures", `List importer_fixtures;
    "results", `List results;
  ] in
  Util.yojson_to_file result_path json;
  if failed = 0 then 0 else 1
