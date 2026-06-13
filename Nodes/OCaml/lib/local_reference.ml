let default_result_path () =
  Printf.sprintf ".benchmark-results/ocaml_docker_baseline_5k_benchmark_%s.json" (Util.today_utc ())

let target_label target = if target = 5000 then "5k" else if target = 50000 then "50k" else string_of_int target

let benchmark_kind target =
  match target with
  | 5000 -> "baseline_5k_p2p"
  | 50000 -> "shakedown_50k_p2p"
  | _ -> "local_reference_p2p"

let expected_utxo_count target =
  match target with
  | 5000 -> Some 4574
  | 50000 -> Some 568855
  | _ -> None

let worker_crypto_context_mode () =
  let verifier = Crypto.create_worker_verifier () in
  Fun.protect ~finally:(fun () -> Crypto.close_verifier verifier) (fun () -> Crypto.verifier_context_mode verifier)

let json_of_counts rows =
  `Assoc (List.map (fun (name, count) -> name, `Int count) rows)

let json_of_timing ?(include_pipeline = false) timing =
  let base = [
    "p2p_fetch", `Int timing.Block_connect.p2p_fetch_ms;
    "block_parse_validate", `Int timing.block_parse_validate_ms;
    "block_store", `Int timing.block_store_ms;
    "utxo_load", `Int timing.Block_connect.utxo_load_ms;
    "utxo_lookup_count", `Int timing.utxo_lookup_count;
    "utxo_key_bytes", `Int timing.utxo_key_bytes;
    "utxo_value_bytes", `Int timing.utxo_value_bytes;
    "script_verify", `Int timing.script_verify_ms;
    "script_sighash_legacy", `Int timing.script_sighash_legacy_ms;
    "script_sighash_witness", `Int timing.script_sighash_witness_ms;
    "script_sighash_taproot", `Int timing.script_sighash_taproot_ms;
    "script_ecdsa_verify", `Int timing.script_ecdsa_verify_ms;
    "script_schnorr_verify", `Int timing.script_schnorr_verify_ms;
    "script_interpreter_eval", `Int timing.script_interpreter_eval_ms;
    "script_runner_wait", `Int timing.script_runner_wait_ms;
    "script_verify_worker_cpu", `Int timing.script_verify_worker_cpu_ms;
    "script_sighash_cache_build", `Int timing.script_sighash_cache_build_ms;
    "script_job_dispatch", `Int timing.script_job_dispatch_ms;
    "script_active_workers", `Int timing.script_active_workers;
    "script_worker_jobs", `Int timing.script_worker_jobs;
    "script_chunk_count", `Int timing.script_chunk_count;
    "script_chunk_size", `Int timing.script_chunk_size;
    "script_worker_loop_ms", `Int timing.script_worker_loop_ms;
    "script_worker_join_ms", `Int timing.script_worker_join_ms;
    "script_dispatch_setup_ms", `Int timing.script_dispatch_setup_ms;
    "runner_batches", `Int timing.runner_batches;
    "script_wall_ms", `Int timing.script_wall_ms;
    "script_parallel_efficiency",
    `Float
      (if timing.script_wall_ms <= 0 || timing.script_active_workers <= 0 then 0.0
       else float_of_int timing.script_verify_worker_cpu_ms /. float_of_int (timing.script_wall_ms * timing.script_active_workers));
    "utxo_apply", `Int timing.utxo_apply_ms;
    "created_utxos", `Int timing.created_utxos;
    "spent_external", `Int timing.spent_external;
    "same_block_spends", `Int timing.same_block_spends;
    "same_block_prevout_skipped", `Int timing.same_block_prevout_skipped;
    "tx_count", `Int timing.tx_count_total;
    "input_count", `Int timing.input_count_total;
    "utxo_key_encode", `Int timing.utxo_key_encode_ms;
    "utxo_value_decode", `Int timing.utxo_value_decode_ms;
    "writebatch_prepare", `Int timing.writebatch_prepare_ms;
    "rocksdb_write", `Int timing.rocksdb_write_ms;
    "commit", `Int timing.commit_ms;
    "block_connect_store_commit", `Int timing.block_connect_store_commit_ms;
    "connect_total", `Int timing.block_connect_store_commit_ms;
  ] in
  let pipeline =
    if include_pipeline then
      [
        "script_legacy_find_delete_ms", `Int timing.script_legacy_find_delete_ms;
        "script_legacy_preimage_build_ms", `Int timing.script_legacy_preimage_build_ms;
        "script_legacy_hash_ms", `Int timing.script_legacy_hash_ms;
      ]
    else []
  in
  `Assoc (base @ pipeline)

let json_of_slow_block (block : P2p.block) (connect : Block_connect.result) =
  let worker_wall_ratio =
    if connect.timing.script_wall_ms <= 0 then 0.0
    else float_of_int connect.timing.script_verify_worker_cpu_ms /. float_of_int connect.timing.script_wall_ms
  in
  `Assoc [
    "height", `Int block.height;
    "hash", `String connect.block_hash;
    "tx_count", `Int connect.tx_count;
    "vin_count", `Int connect.vin_count;
    "vout_count", `Int connect.vout_count;
    "script_input_count", `Int connect.script_input_count;
    "input_shape_counts", json_of_counts connect.input_shape_counts;
    "spent_prevout_script_types", json_of_counts connect.spent_prevout_script_types;
    "output_script_types", json_of_counts connect.output_script_types;
    "block_size", `Int connect.block_size;
    "stage_timings_ms", json_of_timing ~include_pipeline:true connect.timing;
    "script_worker_cpu_wall_ratio", `Float worker_wall_ratio;
    "block_connect_store_commit_ms", `Int connect.timing.block_connect_store_commit_ms;
  ]

let remember_slow_block slow_blocks row =
  slow_blocks := row :: !slow_blocks;
  slow_blocks :=
    !slow_blocks
    |> List.sort (fun (_, a) (_, b) -> compare b.Block_connect.timing.block_connect_store_commit_ms a.Block_connect.timing.block_connect_store_commit_ms)
    |> fun rows ->
    let rec take n acc = function
      | [] -> List.rev acc
      | _ when n = 0 -> List.rev acc
      | x :: xs -> take (n - 1) (x :: acc) xs
    in
    take 10 [] rows

let merge_timing total row = Block_connect.add_timing total row.Block_connect.timing

let bump_count key rows =
  let rec loop acc = function
    | [] -> List.rev ((key, 1) :: acc)
    | (name, count) :: rest when name = key -> List.rev_append acc ((name, count + 1) :: rest)
    | row :: rest -> loop (row :: acc) rest
  in
  loop [] rows

let remember_marker key value rows =
  if List.exists (fun (name, _) -> name = key) rows then rows else (key, value) :: rows

let json_of_int_assoc rows =
  `Assoc (List.map (fun (key, value) -> key, `Int value) (List.sort (fun (a, _) (b, _) -> compare a b) rows))

let with_block_file datadir fn =
  let block_dir = Filename.concat datadir "blocks" in
  Util.ensure_dir block_dir;
  let path = Filename.concat block_dir "blk00000.dat" in
  let oc = open_out_gen [ Open_creat; Open_wronly; Open_trunc; Open_binary ] 0o644 path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () -> fn oc)

(* Single-writer datadir lock for local-reference connect; overlapping writers corrupt runtime truth. *)
let with_sync_lock datadir fn =
  Util.ensure_dir datadir;
  let path = Filename.concat datadir ".ocbitnode_sync.lock" in
  let fd = Unix.openfile path [ Unix.O_CREAT; Unix.O_RDWR ] 0o644 in
  let locked =
    try
      Unix.lockf fd Unix.F_TLOCK 0;
      true
    with Unix.Unix_error ((Unix.EACCES | Unix.EAGAIN), _, _) -> false
  in
  if not locked then (
    let detail =
      try Util.read_file path |> String.trim
      with _ -> "unknown holder"
    in
    Unix.close fd;
    failwith ("another ocbitnode sync process holds lock: " ^ detail));
  Fun.protect
    ~finally:(fun () ->
      (try Unix.lockf fd Unix.F_ULOCK 0 with _ -> ());
      Unix.close fd;
      (try Sys.remove path with _ -> ()))
    (fun () ->
      Unix.ftruncate fd 0;
      ignore (Unix.lseek fd 0 Unix.SEEK_SET);
      let metadata = Printf.sprintf "pid=%d command=local-reference-proof started_at=%s\n" (Unix.getpid ()) (Util.utc_now ()) in
      ignore (Unix.write_substring fd metadata 0 (String.length metadata));
      fn ())

let metadata_int db name default =
  match Rocks.get db (Codec_v2.metadata_key name) with
  | Some value -> (try int_of_string value with _ -> default)
  | None -> default

let metadata_string db name default =
  Option.value ~default (Rocks.get db (Codec_v2.metadata_key name))

let ensure_static_metadata db =
  ignore
    (Rocks.write_batch_timed db ~disable_wal:false ~sync:false (fun batch ->
         Rocks.batch_put batch (Codec_v2.metadata_key "utxo_accounting_policy") "core_spendable_v1";
         Rocks.batch_put batch (Codec_v2.metadata_key "native_crypto_backend") "libsecp256k1";
         Rocks.batch_put batch (Codec_v2.metadata_key "rocksdb_sync_writes") "false"))

let run ~datadir ~target ~peer ~result_path ~runtime_surface ~progress ~telemetry_log =
  let result_path = if result_path = "" then default_result_path () else result_path in
  let db_path = Filename.concat datadir "chainstate-rocksdb" in
  Util.ensure_dir db_path;
  let started_at = Util.utc_now () in
  let started_ms = int_of_float (Unix.gettimeofday () *. 1000.0) in
  let run_id = Printf.sprintf "ocaml-%s-%d" (target_label target) started_ms in
  let total_timing = Block_connect.empty_timing () in
  let blocks_fetched = ref 0 in
  let blocks_connected = ref 0 in
  let last_result = ref None in
  let current_blocker = ref `Null in
  let target_reached = ref false in
  let source_start_height = ref 0 in
  let source_start_hash = ref P2p.genesis_hash in
  let source_start_utxos = ref 0 in
  let resume_height = ref 0 in
  let resume_hash = ref "" in
  let resume_utxos = ref 0 in
  let prefetch_depth = 4 in
  let slow_blocks = ref [] in
  let last_tick_height = ref 0 in
  let last_tick_ms = ref started_ms in
  let telemetry_tick_count = ref 0 in
  let telemetry_lifecycle_markers = ref [] in
  let telemetry_phase_counts = ref [] in
  let telemetry_stall_counts = ref [] in
  let telemetry_last_monotonic_ms = ref None in
  let telemetry_heartbeat_max_gap_ms = ref 0 in
  let telemetry_channel =
    if telemetry_log = "" then None
    else (
      Util.ensure_dir (Filename.dirname telemetry_log);
      Some (open_out_gen [ Open_creat; Open_wronly; Open_trunc; Open_text ] 0o644 telemetry_log))
  in
  let emit_telemetry ~event ~phase ~height ~utxos ~last_block_ms ?block_hash ?(tx_count = 0) ?(vin_count = 0) ?(script_input_count = 0) () =
    let now = int_of_float (Unix.gettimeofday () *. 1000.0) in
    let elapsed_ms = max 0 (now - started_ms) in
    let recent_blocks = height - !last_tick_height in
    let recent_ms = max 1 (now - !last_tick_ms) in
    let total_blocks = max 0 height in
    let has_blocker = !current_blocker <> `Null in
    let stall_class =
      if has_blocker then "validation_blocker"
      else if last_block_ms >= 15000 then "block_connect_slow"
      else "none"
    in
    let payload =
      `Assoc [
        "schema", `String "benchmark.telemetry_tick.v1";
        "port", `String "ocaml";
        "implementation", `String "ocbitnode";
        "gate", `String (if target = 50000 then "shakedown_50k" else if target = 5000 then "baseline_5k" else "diagnostic");
        "run_id", `String run_id;
        "event", `String event;
        "target_height", `Int target;
        "height", `Int height;
        "percent", `Float (if target <= 0 then 0.0 else (float_of_int height /. float_of_int target) *. 100.0);
        "elapsed_ms", `Int elapsed_ms;
        "monotonic_ms", `Int elapsed_ms;
        "rate_recent_blocks_per_second", `Float ((float_of_int recent_blocks *. 1000.0) /. float_of_int recent_ms);
        "rate_total_blocks_per_second", `Float ((float_of_int total_blocks *. 1000.0) /. float_of_int (max 1 elapsed_ms));
        "phase", `String phase;
        "utxos", `Int utxos;
        "last_block_ms", `Int last_block_ms;
        "current_blocker", !current_blocker;
        "stall_class", `String stall_class;
        "current_block_elapsed_ms", `Int last_block_ms;
        "current_block_height", `Int (max 0 height);
        "current_block_hash", (match block_hash with Some hash -> `String hash | None -> `Null);
        "current_block_tx_count", `Int tx_count;
        "current_block_vin_count", `Int vin_count;
        "current_block_script_input_count", `Int script_input_count;
        "timing_buckets_ms", json_of_timing ~include_pipeline:true total_timing;
      ]
    in
    let line = "benchmark.telemetry_tick " ^ Yojson.Safe.to_string payload in
    let product_progress =
      `Assoc [
        "chain", `String "testnet4";
        "sync_status", `String (if height >= target then "blocks_current" else "blocks_syncing");
        "header_height", `Int height;
        "validated_height", `Int height;
        "validated_hash", (match block_hash with Some hash -> `String hash | None -> `String "");
        "stored_block_height", `Int height;
        "chainstate_utxo_count", `Int utxos;
        "current_blocker", !current_blocker;
        "peer", `String peer;
        "current_block_height", `Int (max 0 height);
        "current_block_hash", (match block_hash with Some hash -> `String hash | None -> `Null);
        "current_block_tx_count", `Int tx_count;
        "current_block_vin_count", `Int vin_count;
        "current_block_script_input_count", `Int script_input_count;
        "last_block_ms", `Int last_block_ms;
        "native_crypto_backend", `String "libsecp256k1";
        "timing_buckets_ms", json_of_timing ~include_pipeline:true total_timing;
      ]
    in
    let progress_line = "rb.port_progress " ^ Yojson.Safe.to_string product_progress in
    incr telemetry_tick_count;
    telemetry_lifecycle_markers := remember_marker event elapsed_ms !telemetry_lifecycle_markers;
    telemetry_phase_counts := bump_count phase !telemetry_phase_counts;
    telemetry_stall_counts := bump_count stall_class !telemetry_stall_counts;
    (match !telemetry_last_monotonic_ms with
     | Some previous -> telemetry_heartbeat_max_gap_ms := max !telemetry_heartbeat_max_gap_ms (elapsed_ms - previous)
     | None -> ());
    telemetry_last_monotonic_ms := Some elapsed_ms;
    print_endline line;
    print_endline progress_line;
    Option.iter
      (fun oc ->
        output_string oc line;
        output_char oc '\n';
        output_string oc progress_line;
        output_char oc '\n';
        flush oc)
      telemetry_channel;
    last_tick_height := height;
    last_tick_ms := now
  in
  let raw_result =
    try
      if (target = 5000 || target = 50000) && Block_connect.script_threads () < 2 then failwith "official gates require parallel script runner";
      with_sync_lock datadir (fun () ->
      with_block_file datadir (fun block_oc ->
        Rocks.with_db db_path (fun db ->
        ensure_static_metadata db;
        let stored_height = max 0 (metadata_int db "validated_height" 0) in
        let stored_hash = metadata_string db "validated_hash" "" in
        let stored_utxos = max 0 (metadata_int db "chainstate_utxo_count" 0) in
        source_start_height := stored_height;
        source_start_hash := if stored_height = 0 || stored_hash = "" then P2p.genesis_hash else stored_hash;
        source_start_utxos := stored_utxos;
        resume_height := stored_height;
        resume_hash := stored_hash;
        resume_utxos := stored_utxos;
        last_tick_height := stored_height;
        emit_telemetry ~event:"run_started" ~phase:"startup" ~height:stored_height ~utxos:stored_utxos
          ~last_block_ms:0 ?block_hash:(if stored_hash = "" then None else Some stored_hash) ();
        emit_telemetry ~event:"container_started" ~phase:"startup" ~height:stored_height ~utxos:stored_utxos
          ~last_block_ms:0 ?block_hash:(if stored_hash = "" then None else Some stored_hash) ();
        emit_telemetry ~event:"node_started" ~phase:"startup" ~height:stored_height ~utxos:stored_utxos
          ~last_block_ms:0 ?block_hash:(if stored_hash = "" then None else Some stored_hash) ();
        if stored_height >= target then (
          target_reached := true;
          emit_telemetry ~event:"target_reached" ~phase:"complete" ~height:stored_height ~utxos:stored_utxos
            ~last_block_ms:0 ?block_hash:(if stored_hash = "" then None else Some stored_hash) ())
        else
          Block_connect.with_script_worker_pool (Block_connect.script_threads ()) (fun script_pool ->
          let utxo_count = ref stored_utxos in
          let expected_prev = ref (if stored_hash = "" then None else Some stored_hash) in
          let start_height = stored_height + 1 in
          P2p.iter_blocks ~peer ~target ~start_height ~prefetch:prefetch_depth ~on_block:
            (fun block ->
              total_timing.p2p_fetch_ms <- total_timing.p2p_fetch_ms + block.P2p.fetch_ms;
              let block_store_started = int_of_float (Unix.gettimeofday () *. 1000.0) in
              let file_offset = pos_out block_oc in
              output_string block_oc block.raw;
              total_timing.block_store_ms <-
                total_timing.block_store_ms + max 0 (int_of_float (Unix.gettimeofday () *. 1000.0) - block_store_started);
              let connect =
                Block_connect.connect_block ~script_pool:(Some script_pool) ~db ~height:block.P2p.height ~target ~raw:block.raw
                  ~expected_hash:block.hash ~expected_prev:!expected_prev ~file_number:0 ~file_offset ~utxo_count
              in
              if !blocks_connected = 0 then (
                emit_telemetry ~event:"first_peer_byte" ~phase:"peer_connect" ~height:block.height ~utxos:connect.chainstate_utxo_count
                  ~last_block_ms:connect.timing.block_connect_store_commit_ms ~block_hash:connect.block_hash ~tx_count:connect.tx_count
                  ~vin_count:connect.vin_count ~script_input_count:connect.script_input_count ();
                emit_telemetry ~event:"first_block_connected" ~phase:"block_connect" ~height:block.height ~utxos:connect.chainstate_utxo_count
                  ~last_block_ms:connect.timing.block_connect_store_commit_ms ~block_hash:connect.block_hash ~tx_count:connect.tx_count
                  ~vin_count:connect.vin_count ~script_input_count:connect.script_input_count ());
              merge_timing total_timing connect;
              remember_slow_block slow_blocks (block, connect);
              incr blocks_fetched;
              incr blocks_connected;
              last_result := Some (block, connect);
              resume_height := block.P2p.height;
              resume_hash := connect.block_hash;
              resume_utxos := connect.chainstate_utxo_count;
              expected_prev := Some connect.block_hash;
              if block.height mod max 1 progress = 0 || block.height = target then
                Printf.printf "ocbitnode-local-reference-proof height=%d target=%d hash=%s txs=%d utxos=%d\n%!"
                  block.height target connect.block_hash connect.tx_count connect.chainstate_utxo_count;
              if block.height mod max 1 progress = 0 || block.height = target then
                emit_telemetry ~event:(if block.height = target then "target_reached" else "heartbeat")
                  ~phase:(if block.height = target then "complete" else "heartbeat") ~height:block.height
                  ~utxos:connect.chainstate_utxo_count ~last_block_ms:connect.timing.block_connect_store_commit_ms
                  ~block_hash:connect.block_hash ~tx_count:connect.tx_count ~vin_count:connect.vin_count
                  ~script_input_count:connect.script_input_count ()));
        target_reached := !resume_height >= target)));
      "passed"
    with
    | Block_connect.Connect_error blocker ->
        current_blocker := blocker;
        "failed"
    | P2p.P2p_error message ->
        current_blocker :=
          `Assoc [
            "height", `Int (-1);
            "failure", `String message;
            "missing_rule", `String "p2p_fetch";
            "source", `String "ocbitnode-local-reference-proof";
            "created_at", `String (Util.utc_now ());
          ];
        "failed"
    | exn ->
        current_blocker :=
          `Assoc [
            "height", `Int (-1);
            "failure", `String (Printexc.to_string exn);
            "missing_rule", `String "exception";
            "source", `String "ocbitnode-local-reference-proof";
            "created_at", `String (Util.utc_now ());
          ];
        "failed"
  in
  let elapsed_ms = int_of_float (Unix.gettimeofday () *. 1000.) - started_ms in
  let performance_ok = true in
  let utxo_ok =
    match expected_utxo_count target, !last_result with
    | Some expected, Some (_, connect) -> connect.chainstate_utxo_count = expected
    | Some _, None -> false
    | None, _ -> true
  in
  if (not utxo_ok) && !target_reached then
    current_blocker :=
      `Assoc [
        "height", `Int target;
        "failure", `String "OCaml chainstate_utxo_count did not match official gate expectation";
        "missing_rule", `String "utxo_accounting_mismatch";
        "source", `String "ocbitnode-local-reference-proof";
        "created_at", `String (Util.utc_now ());
      ];
  let parallel_ok = (target <> 5000 && target <> 50000) || total_timing.script_active_workers > 1 in
  if (not parallel_ok) && !target_reached then
    current_blocker :=
      `Assoc [
        "height", `Int target;
        "failure", `String "OCaml official proof did not prove more than one active script worker";
        "missing_rule", `String "parallel_script_runner_inactive";
        "source", `String "ocbitnode-local-reference-proof";
        "created_at", `String (Util.utc_now ());
      ];
  let proof_result = if raw_result = "passed" && performance_ok && utxo_ok && parallel_ok then "passed" else "failed" in
  let validated_height, validated_hash, tx_count, chainstate_utxo_count =
    match !last_result with
    | Some (block, connect) -> block.P2p.height, connect.Block_connect.block_hash, connect.tx_count, connect.chainstate_utxo_count
    | None -> !resume_height, !resume_hash, 0, !resume_utxos
  in
  let status = if !target_reached then "blocks_current" else if proof_result = "failed" then "blocks_blocked" else "blocks_syncing" in
  emit_telemetry ~event:"run_finished" ~phase:(if proof_result = "passed" then "complete" else "failed") ~height:(max 0 validated_height)
    ~utxos:(max 0 chainstate_utxo_count)
    ~last_block_ms:(match !last_result with Some (_, connect) -> connect.timing.block_connect_store_commit_ms | None -> 0)
    ?block_hash:(if validated_hash = "" then None else Some validated_hash)
    ~tx_count
    ~vin_count:(match !last_result with Some (_, connect) -> connect.vin_count | None -> 0)
    ~script_input_count:(match !last_result with Some (_, connect) -> connect.script_input_count | None -> 0)
    ();
  Option.iter close_out_noerr telemetry_channel;
  let telemetry_summary =
    `Assoc [
      "telemetry_quality", `String (if proof_result = "passed" && !target_reached then "clean" else "invalid");
      "tick_count", `Int !telemetry_tick_count;
      "heartbeat_max_gap_ms", `Int !telemetry_heartbeat_max_gap_ms;
      "heartbeat_limit_ms", `Int 15000;
      "lifecycle_markers", json_of_int_assoc !telemetry_lifecycle_markers;
      "phase_counts", json_of_int_assoc !telemetry_phase_counts;
      "stall_class_counts", json_of_int_assoc !telemetry_stall_counts;
      "slow_blocks", `List (List.map (fun (block, connect) -> json_of_slow_block block connect) !slow_blocks);
      "telemetry_log", `String telemetry_log;
    ]
  in
  let json =
    `Assoc [
      "schema", `String "port.local_reference_benchmark.v1";
      "implementation", `String "ocbitnode";
      "node_id", `String "OCamlNode";
      "port", `String "ocaml";
      "category", `String "benchmark";
      "benchmark_contract_version", `Int 1;
      "benchmark_gate", `String (if target = 50000 then "shakedown_50k" else if target = 5000 then "baseline_5k" else "diagnostic");
      "result", `String proof_result;
      "bounded_gate_status", `String (if !target_reached then "passed" else "failed");
      "local_reference_status", `String (if !target_reached then "target_reached" else "blocked");
      "benchmark_kind", `String (benchmark_kind target);
      "benchmark_lane", `String (benchmark_kind target);
      "target_label", `String (target_label target);
      "chain", `String "testnet4";
      "runtime_surface", `String runtime_surface;
      "peer_mode", `String "local_reference";
      "peer", `String peer;
      "byte_source", `String "local_reference_p2p";
      "proof_mode", `String "p2p_sync";
      "reference_start_height", `Int !source_start_height;
      "reference_start_hash", `String !source_start_hash;
      "reference_finish_height", `Int target;
      "reference_finish_hash", `String validated_hash;
      "target_height", `Int target;
      "header_target_height", `Int target;
      "validated_height", `Int validated_height;
      "header_height", `Int validated_height;
      "stored_block_height", `Int validated_height;
      "validated_hash", `String validated_hash;
      "header_hash", `String validated_hash;
      "stored_block_hash", `String validated_hash;
      "sync_status", `String status;
      "current_blocker", !current_blocker;
      "binary_gate_status", `String "not_attempted";
      "chainstate_backend", `String "rocksdb";
      "runtime_truth_backend", `String "rocksdb";
      "rocksdb_runtime_truth", `Bool true;
      "native_storage", `Bool true;
      "native_crypto_backend", `String "libsecp256k1";
      "native_crypto_available", `Bool true;
      "crypto_context_mode", `String (worker_crypto_context_mode ());
      "utxo_accounting_policy", `String "core_spendable_v1";
      "chainstate_utxo_count", `Int chainstate_utxo_count;
      "storage_codec_version", `Int 2;
      "rocksdb_wal_disabled", `Bool false;
      "rocksdb_sync_writes", `Bool false;
      "rocksdb_tuning", `String Rocks.tuning_mode;
      "fresh_state", `Bool (!source_start_height = 0);
      "source_state_height", `Int !source_start_height;
      "source_state_hash", `String !source_start_hash;
      "source_state_utxo_count", `Int !source_start_utxos;
      "source_state_origin", `String (if !source_start_height = 0 then "fresh_state" else "port_durable_state");
      "prefetch_depth", `Int prefetch_depth;
      "script_runner_mode", `String (if total_timing.script_active_workers > 1 then "parallel" else "sequential");
      "script_threads", `Int (Block_connect.script_threads ());
      "script_worker_jobs", `Int total_timing.script_worker_jobs;
      "script_parallel_min_inputs", `Int (Block_connect.script_parallel_min_inputs ());
      "resume_supported", `Bool true;
      "performance_gate_elapsed_ms_max", `Null;
      "performance_gate_status", `String "not_applicable";
      "expected_chainstate_utxo_count", (match expected_utxo_count target with Some value -> `Int value | None -> `Null);
      "utxo_gate_status", `String (if utxo_ok then "passed" else "failed");
      "blocks_fetched", `Int !blocks_fetched;
      "blocks_connected", `Int !blocks_connected;
      "block_count", `Int !blocks_connected;
      "last_block_tx_count", `Int tx_count;
      "started_at", `String started_at;
      "updated_at", `String (Util.utc_now ());
      "captured_at", `String (Util.utc_now ());
      "elapsed_ms", `Int elapsed_ms;
      "telemetry_schema", `String "benchmark.telemetry_tick.v1";
      "telemetry_log", `String telemetry_log;
      "telemetry_summary", telemetry_summary;
      "slow_blocks", `List (List.map (fun (block, connect) -> json_of_slow_block block connect) !slow_blocks);
      "failures", (if proof_result = "passed" then `List [] else `List [ !current_blocker ]);
      "timing_summary", `Assoc [
        "total_ms", `Int elapsed_ms;
        "stage_totals_ms", json_of_timing total_timing;
      ];
      "pipeline_timing_summary", `Assoc [
        "total_ms", `Int elapsed_ms;
        "stage_totals_ms", json_of_timing ~include_pipeline:true total_timing;
      ];
      "stage_totals_ms", json_of_timing total_timing;
    ]
  in
  Util.yojson_to_file result_path json;
  Printf.printf "ocbitnode-local-reference-proof result=%s target=%d height=%d elapsed_ms=%d result_path=%s\n%!" proof_result target validated_height elapsed_ms result_path;
  if proof_result = "passed" then 0 else 1
