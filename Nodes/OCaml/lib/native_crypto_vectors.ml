let vector_result vector =
  let open Util in
  let id = json_string "id" vector in
  let operation = json_string "operation" vector in
  let expected = json_string "expected" vector in
  let observed =
    match operation with
    | "verify_ecdsa" ->
        Crypto.ecdsa_verify
          ~pubkey_hex:(json_string "pubkey_hex" vector)
          ~msg_hash_hex:(json_string "msg_hash_hex" vector)
          ~signature_hex:(json_string "signature_hex" vector)
        |> Crypto.string_of_result
    | "verify_schnorr" ->
        Crypto.schnorr_verify
          ~xonly_pubkey_hex:(json_string "xonly_pubkey_hex" vector)
          ~msg_hash_hex:(json_string "msg_hash_hex" vector)
          ~signature_hex:(json_string "signature_hex" vector)
        |> Crypto.string_of_result
    | "taproot_tweak_xonly" ->
        Crypto.taproot_tweak_check
          ~xonly_pubkey_hex:(json_string "xonly_pubkey_hex" vector)
          ~merkle_root_hex:(json_string "merkle_root_hex" vector)
          ~expected_output_xonly_hex:(json_string "expected_output_xonly_hex" vector)
          ~expected_parity:(json_int "expected_parity" vector)
        |> Crypto.string_of_result
    | _ -> "malformed_input"
  in
  let passed = observed = expected in
  passed, `Assoc [
    "id", `String id;
    "operation", `String operation;
    "expected", `String expected;
    "observed", `String observed;
    "result", `String (if passed then "passed" else "failed");
  ]

let run ~vector_path ~result_path =
  let payload = Yojson.Safe.from_file vector_path in
  let vectors = Util.json_list "vectors" payload in
  let results = List.map vector_result vectors in
  let passed = List.fold_left (fun count (ok, _) -> if ok then count + 1 else count) 0 results in
  let failed = List.length results - passed in
  let smoke =
    try
      let output = Crypto.xonly_parse_serialize_hex "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798" in
      `Assoc ["id", `String "ocaml-xonly-parse-serialize-smoke"; "result", `String (if output <> "" then "passed" else "failed")]
    with _ -> `Assoc ["id", `String "ocaml-xonly-parse-serialize-smoke"; "result", `String "failed"]
  in
  let json = `Assoc [
    "schema", `String "port.native_crypto_vectors.v1";
    "category", `String "native_crypto";
    "port", `String "ocaml";
    "implementation", `String "ocbitnode";
    "node_id", `String "OCamlNode";
    "captured_at", `String (Util.utc_now ());
    "vector_source", `String vector_path;
    "native_crypto_backend", `String "libsecp256k1";
    "secp256k1_binding", `String "opam:secp256k1=0.5.0";
    "vector_count", `Int (List.length results);
    "passed", `Int passed;
    "failed", `Int failed;
    "result", `String (if failed = 0 then "passed" else "failed");
    "wrapper_smoke", smoke;
    "results", `List (List.map snd results);
  ] in
  Util.yojson_to_file result_path json;
  if failed = 0 then 0 else 1

