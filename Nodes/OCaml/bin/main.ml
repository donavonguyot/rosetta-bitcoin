let usage () =
  prerr_endline "usage:";
  prerr_endline "  ocbitnode status --datadir <path>";
  prerr_endline "  ocbitnode storage-proof --datadir <path> --result-path <json>";
  prerr_endline "  ocbitnode native-crypto-vectors --result-path <json> [--vectors <json>]";
  prerr_endline "  ocbitnode test-capability --kind <crypto-vectors|block-connect-backend> --outcome-path <json>";
  prerr_endline "  ocbitnode script-corpus --manifest <path> --result-path <json> --runtime-surface <host|docker> [--fixture-id <id>]";
  prerr_endline "  ocbitnode local-reference-proof --datadir <path> --target <height> --peer <host:port> --result-path <json> --runtime-surface <host|docker> [--progress <n>] [--telemetry-log <path>]";
  2

let rec option_value name = function
  | [] -> None
  | flag :: value :: _ when flag = name -> Some value
  | _ :: rest -> option_value name rest

let require name args =
  match option_value name args with
  | Some value -> value
  | None -> failwith ("missing required option " ^ name)

let default_vectors = "../../Nodes/Shared/conformance/fixtures/native_crypto_v1_vectors.json"

let () =
  let args = Array.to_list Sys.argv |> List.tl in
  let code =
    try
      match args with
      | "status" :: rest ->
          Ocbitnode.Status.run ~datadir:(require "--datadir" rest)
      | "storage-proof" :: rest ->
          Ocbitnode.Storage_proof.run
            ~datadir:(require "--datadir" rest)
            ~result_path:(require "--result-path" rest)
      | "native-crypto-vectors" :: rest ->
          Ocbitnode.Native_crypto_vectors.run
            ~vector_path:(Option.value ~default:default_vectors (option_value "--vectors" rest))
            ~result_path:(require "--result-path" rest)
      | "test-capability" :: rest ->
          Ocbitnode.Test_capability.run
            ~kind:(require "--kind" rest)
            ~outcome_path:(require "--outcome-path" rest)
      | "script-corpus" :: rest ->
          Ocbitnode.Script_corpus.run
            ~manifest_path:(require "--manifest" rest)
            ~result_path:(require "--result-path" rest)
            ~runtime_surface:(require "--runtime-surface" rest)
            ?fixture_id:(option_value "--fixture-id" rest)
            ()
      | "local-reference-proof" :: rest ->
          let code =
            Ocbitnode.Local_reference.run
              ~datadir:(require "--datadir" rest)
              ~target:(int_of_string (Option.value ~default:"5000" (option_value "--target" rest)))
              ~peer:(Option.value ~default:"127.0.0.1:48333" (option_value "--peer" rest))
              ~result_path:(require "--result-path" rest)
              ~runtime_surface:(Option.value ~default:"host" (option_value "--runtime-surface" rest))
              ~progress:(int_of_string (Option.value ~default:"1000" (option_value "--progress" rest)))
              ~telemetry_log:(Option.value ~default:"" (option_value "--telemetry-log" rest))
          in
          flush_all ();
          Unix._exit code
      | _ -> usage ()
    with exn ->
      prerr_endline ("ocbitnode: " ^ Printexc.to_string exn);
      1
  in
  exit code
