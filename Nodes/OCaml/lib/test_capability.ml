type outcome = {
  capability : string;
  passed : int;
  total : int;
  notes : string;
}

let status row = if row.passed = row.total then "pass" else "fail"

let outcome_json row =
  `Assoc [
    "capability", `String row.capability;
    "status", `String (status row);
    "case_passed", `Int row.passed;
    "case_total", `Int row.total;
    "notes", `String row.notes;
  ]

let repo_root () =
  let rec loop dir =
    if Sys.file_exists (Filename.concat dir "Nodes/Shared")
       && Sys.file_exists (Filename.concat dir "Nodes/OCaml")
    then dir
    else if Sys.file_exists (Filename.concat dir "Shared")
            && Sys.file_exists (Filename.concat dir "OCaml")
    then dir
    else
      let parent = Filename.dirname dir in
      if parent = dir then failwith "could not locate repository root";
      loop parent
  in
  loop (Sys.getcwd ())

let shared_path root path =
  let host_path = Filename.concat root (Filename.concat "Nodes/Shared" path) in
  if Sys.file_exists host_path then host_path else Filename.concat root (Filename.concat "Shared" path)

let split_csv line = String.split_on_char ',' line

let run_bip340 path =
  let lines =
    Util.read_file path
    |> String.split_on_char '\n'
    |> List.filter (fun row -> String.trim row <> "")
  in
  let rows = match lines with _header :: rest -> rest | [] -> [] in
  let failures = ref [] in
  let passed = ref 0 in
  List.iter
    (fun line ->
      match split_csv line with
      | index :: _secret :: pubkey :: _aux :: message :: signature :: expected :: _ ->
          let want = expected = "TRUE" in
          let got =
            Crypto.schnorr_verify_message_bytes
              ~xonly_pubkey:(Util.bytes_of_hex pubkey)
              ~message:(Util.bytes_of_hex message)
              ~signature:(Util.bytes_of_hex signature)
          in
          if got = want then incr passed else failures := index :: !failures
      | _ -> failwith "malformed BIP340 vector row")
    rows;
  let total = List.length rows in
  let notes =
    match List.rev !failures with
    | [] -> "all BIP340 vectors matched expected verification result"
    | failures -> "mismatched BIP340 vector indexes: " ^ String.concat "," failures
  in
  { capability = "crypto_bip340_vectors"; passed = !passed; total; notes }

let run_native_vectors path =
  let payload = Yojson.Safe.from_file path in
  let vectors = Util.json_list "vectors" payload in
  let results = List.map Native_crypto_vectors.vector_result vectors in
  let passed = List.fold_left (fun count (ok, _) -> if ok then count + 1 else count) 0 results in
  let failures =
    List.filter_map
      (fun (ok, json) -> if ok then None else Some (Util.json_string "id" json))
      results
  in
  let notes =
    match failures with
    | [] -> Printf.sprintf "native crypto vectors %d/%d" passed (List.length vectors)
    | failures -> "native vector failures: " ^ String.concat "," failures
  in
  { capability = "native_crypto_vectors"; passed; total = List.length vectors; notes }

let run_crypto_vectors () =
  let root = repo_root () in
  let bip = run_bip340 (shared_path root "testing/fixtures/bip340/test-vectors.csv") in
  let native = run_native_vectors (shared_path root "conformance/fixtures/native_crypto_v1_vectors.json") in
  let equivalence = {
    capability = "crypto_libsecp256k1_equivalence";
    passed = bip.passed + native.passed;
    total = bip.total + native.total;
    notes = bip.notes ^ "; " ^ native.notes;
  } in
  [ bip; equivalence ]

let run_fixture manifest fixture =
  let path = Filename.temp_file "ocbitnode_backend_probe_" ".json" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with _ -> ())
    (fun () ->
      let exit =
        Script_corpus.run
          ~manifest_path:manifest
          ~result_path:path
          ~runtime_surface:"host"
          ~fixture_id:fixture
          ()
      in
      let doc = Yojson.Safe.from_file path in
      let passed = exit = 0 && Util.json_string "result" doc = "passed" && Util.json_int "passed" doc = 1 in
      passed, fixture ^ " result=" ^ Util.json_string "result" doc)

let run_block_connect_backend () =
  let root = repo_root () in
  let manifest = shared_path root "conformance/fixtures/scripts/manifest.json" in
  let fixtures = [ "scripts.p2pkh_sighash_single_38010"; "scripts.p2tr_scriptpath_44295" ] in
  let results = List.map (run_fixture manifest) fixtures in
  let passed = List.fold_left (fun count (ok, _) -> if ok then count + 1 else count) 0 results in
  let notes = results |> List.map snd |> String.concat "; " in
  [ { capability = "block_connect_with_backend"; passed; total = List.length fixtures; notes } ]

let run ~kind ~outcome_path =
  let outcomes =
    match kind with
    | "crypto-vectors" -> run_crypto_vectors ()
    | "block-connect-backend" -> run_block_connect_backend ()
    | _ -> failwith ("unknown kind: " ^ kind)
  in
  let json = `Assoc [
    "port", `String "ocaml";
    "backend", `String "libsecp256k1";
    "outcomes", `List (List.map outcome_json outcomes);
  ] in
  Util.yojson_to_file outcome_path json;
  0
