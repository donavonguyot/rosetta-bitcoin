exception Connect_error of Yojson.Safe.t

type timing_buckets = {
  mutable p2p_fetch_ms : int;
  mutable block_parse_validate_ms : int;
  mutable block_store_ms : int;
  mutable utxo_load_ms : int;
  mutable script_verify_ms : int;
  mutable script_sighash_legacy_ms : int;
  mutable script_sighash_witness_ms : int;
  mutable script_sighash_taproot_ms : int;
  mutable script_ecdsa_verify_ms : int;
  mutable script_schnorr_verify_ms : int;
  mutable script_interpreter_eval_ms : int;
  mutable script_runner_wait_ms : int;
  mutable script_verify_worker_cpu_ms : int;
  mutable script_sighash_cache_build_ms : int;
  mutable script_job_dispatch_ms : int;
  mutable script_wall_ms : int;
  mutable script_active_workers : int;
  mutable utxo_apply_ms : int;
  mutable commit_ms : int;
  mutable block_connect_store_commit_ms : int;
}

type utxo = {
  txid : string;
  vout : int;
  height : int;
  value_sats : int64;
  coinbase : bool;
  script_pubkey : string;
}

type result = {
  block_hash : string;
  tx_count : int;
  vin_count : int;
  vout_count : int;
  script_input_count : int;
  input_shape_counts : (string * int) list;
  spent_prevout_script_types : (string * int) list;
  output_script_types : (string * int) list;
  block_size : int;
  chainstate_utxo_count : int;
  timing : timing_buckets;
}

let chain = "testnet4"

let now_ms () = int_of_float (Unix.gettimeofday () *. 1000.0)
let elapsed start = max 0 (now_ms () - start)

let empty_timing () =
  {
    p2p_fetch_ms = 0;
    block_parse_validate_ms = 0;
    block_store_ms = 0;
    utxo_load_ms = 0;
    script_verify_ms = 0;
    script_sighash_legacy_ms = 0;
    script_sighash_witness_ms = 0;
    script_sighash_taproot_ms = 0;
    script_ecdsa_verify_ms = 0;
    script_schnorr_verify_ms = 0;
    script_interpreter_eval_ms = 0;
    script_runner_wait_ms = 0;
    script_verify_worker_cpu_ms = 0;
    script_sighash_cache_build_ms = 0;
    script_job_dispatch_ms = 0;
    script_wall_ms = 0;
    script_active_workers = 0;
    utxo_apply_ms = 0;
    commit_ms = 0;
    block_connect_store_commit_ms = 0;
  }

let add_timing total row =
  total.p2p_fetch_ms <- total.p2p_fetch_ms + row.p2p_fetch_ms;
  total.block_parse_validate_ms <- total.block_parse_validate_ms + row.block_parse_validate_ms;
  total.block_store_ms <- total.block_store_ms + row.block_store_ms;
  total.utxo_load_ms <- total.utxo_load_ms + row.utxo_load_ms;
  total.script_verify_ms <- total.script_verify_ms + row.script_verify_ms;
  total.script_sighash_legacy_ms <- total.script_sighash_legacy_ms + row.script_sighash_legacy_ms;
  total.script_sighash_witness_ms <- total.script_sighash_witness_ms + row.script_sighash_witness_ms;
  total.script_sighash_taproot_ms <- total.script_sighash_taproot_ms + row.script_sighash_taproot_ms;
  total.script_ecdsa_verify_ms <- total.script_ecdsa_verify_ms + row.script_ecdsa_verify_ms;
  total.script_schnorr_verify_ms <- total.script_schnorr_verify_ms + row.script_schnorr_verify_ms;
  total.script_interpreter_eval_ms <- total.script_interpreter_eval_ms + row.script_interpreter_eval_ms;
  total.script_runner_wait_ms <- total.script_runner_wait_ms + row.script_runner_wait_ms;
  total.script_verify_worker_cpu_ms <- total.script_verify_worker_cpu_ms + row.script_verify_worker_cpu_ms;
  total.script_sighash_cache_build_ms <- total.script_sighash_cache_build_ms + row.script_sighash_cache_build_ms;
  total.script_job_dispatch_ms <- total.script_job_dispatch_ms + row.script_job_dispatch_ms;
  total.script_wall_ms <- total.script_wall_ms + row.script_wall_ms;
  total.script_active_workers <- max total.script_active_workers row.script_active_workers;
  total.utxo_apply_ms <- total.utxo_apply_ms + row.utxo_apply_ms;
  total.commit_ms <- total.commit_ms + row.commit_ms;
  total.block_connect_store_commit_ms <- total.block_connect_store_commit_ms + row.block_connect_store_commit_ms

let outpoint_key txid vout = txid ^ Codec_v2.be32 vout

let utxo_key utxo = outpoint_key utxo.txid utxo.vout

let spent_key input =
  outpoint_key input.Tx.previous_output.hash (Int32.to_int input.previous_output.index)

let encode_int value = string_of_int value
let decode_int = int_of_string

let be32_at raw offset =
  (Char.code raw.[offset] lsl 24) lor (Char.code raw.[offset + 1] lsl 16) lor (Char.code raw.[offset + 2] lsl 8)
  lor Char.code raw.[offset + 3]

let be64_at raw offset =
  let value = ref 0L in
  for i = 0 to 7 do
    value := Int64.logor (Int64.shift_left !value 8) (Int64.of_int (Char.code raw.[offset + i]))
  done;
  !value

let decode_utxo_value txid vout raw =
  if String.length raw < 18 then invalid_arg "short codec v2 utxo";
  let height = be32_at raw 0 in
  let stored_vout = be32_at raw 4 in
  if stored_vout <> vout then invalid_arg "codec v2 utxo vout mismatch";
  let value_sats = be64_at raw 8 in
  let coinbase = Char.code raw.[16] <> 0 in
  let script_len = Char.code raw.[17] in
  if 18 + script_len <> String.length raw then invalid_arg "codec v2 utxo script length mismatch";
  let script_pubkey = String.sub raw 18 script_len in
  { txid; vout; height; value_sats; coinbase; script_pubkey }

let metadata_height db name =
  match Rocks.get db (Codec_v2.metadata_key name) with
  | Some value -> (try int_of_string value with _ -> -1)
  | None -> -1

let metadata_string db name default =
  Option.value ~default (Rocks.get db (Codec_v2.metadata_key name))

let is_spendable_output script_pubkey =
  script_pubkey <> "" && Char.code script_pubkey.[0] <> 0x6a

let blocker ~height ~block_hash ~txid ~input ~missing_rule ~failure =
  `Assoc [
    "height", `Int height;
    "block_hash", `String block_hash;
    "txid", `String txid;
    "input", `Int input;
    "failure", `String failure;
    "missing_rule", `String missing_rule;
    "source", `String "ocbitnode-connect";
    "created_at", `String (Util.utc_now ());
  ]

let parse_block raw expected_hash expected_prev =
  let block = Block.parse raw in
  let block_hash = Block.header_hash_hex block.header in
  if expected_hash <> "" && block_hash <> expected_hash then failwith ("block hash mismatch: got " ^ block_hash ^ " want " ^ expected_hash);
  (match expected_prev with
  | Some prev -> if Block.(block.header.prev_block) <> Tx.parse_display_hash prev then failwith "block previous hash mismatch"
  | None -> ());
  if not (Block.validate_merkle_root block) then failwith "block merkle root mismatch";
  if not (Block.proof_of_work_ok block.header) then failwith "block proof-of-work mismatch";
  block, block_hash

let output_utxos height tx txid coinbase =
  tx.Tx.outputs
  |> List.mapi (fun vout (output : Tx.tx_out) -> vout, output)
  |> List.filter_map (fun (vout, (output : Tx.tx_out)) ->
         if not (is_spendable_output output.script_pubkey) then None
         else Some { txid; vout; height; value_sats = output.value; coinbase; script_pubkey = output.script_pubkey })

let list_filter_mapi fn rows =
  let rec loop index acc = function
    | [] -> List.rev acc
    | row :: rest -> (
        match fn index row with
        | Some value -> loop (index + 1) (value :: acc) rest
        | None -> loop (index + 1) acc rest)
  in
  loop 0 [] rows

let gather_external_prevouts txs =
  let seen = Hashtbl.create 128 in
  txs
  |> List.mapi (fun tx_index tx -> tx_index, tx)
  |> List.concat_map (fun (tx_index, tx) ->
         if tx_index = 0 then []
         else
           tx.Tx.inputs
           |> list_filter_mapi (fun _ input ->
                  let txid = input.Tx.previous_output.hash in
                  let vout = Int32.to_int input.previous_output.index in
                  let key = outpoint_key txid vout in
                  if Hashtbl.mem seen key then None
                  else (
                    Hashtbl.add seen key true;
                    Some (key, txid, vout))))

let load_prevouts db txs =
  let prevouts = gather_external_prevouts txs in
  let keys = List.map (fun (key, _, _) -> Codec_v2.utxo_key ~chain ~txid:(String.sub key 0 32) ~vout:(be32_at key 32)) prevouts in
  let values = Rocks.multi_get db keys in
  let loaded = Hashtbl.create (List.length prevouts) in
  List.iter2
    (fun (key, txid, vout) value ->
      match value with
      | Some raw -> Hashtbl.add loaded key (decode_utxo_value txid vout raw)
      | None -> ())
    prevouts values;
  loaded

let find_utxo loaded created key =
  match Hashtbl.find_opt created key with
  | Some utxo -> Some utxo
  | None -> Hashtbl.find_opt loaded key

let classify_script script =
  if script = "" then "empty"
  else
    match Char.code script.[0] with
    | 0x6a -> "op_return"
    | _ when String.length script = 25 && Char.code script.[0] = 0x76 && Char.code script.[1] = 0xa9 -> "p2pkh"
    | _ when String.length script = 23 && Char.code script.[0] = 0xa9 -> "p2sh"
    | _ when String.length script = 22 && Char.code script.[0] = 0x00 && Char.code script.[1] = 0x14 -> "p2wpkh"
    | _ when String.length script = 34 && Char.code script.[0] = 0x00 && Char.code script.[1] = 0x20 -> "p2wsh"
    | _ when String.length script = 34 && Char.code script.[0] = 0x51 && Char.code script.[1] = 0x20 -> "p2tr"
    | _ -> "other"

type script_task = {
  tx_index : int;
  input_index : int;
  prevout : Script_verify.spent_prevout;
  spent_prevouts : Script_verify.spent_prevout list;
  cache : Script_verify.sighash_cache;
}

type script_timing_snapshot = {
  mutable ss_sighash_legacy_ms : int;
  mutable ss_sighash_witness_ms : int;
  mutable ss_sighash_taproot_ms : int;
  mutable ss_ecdsa_verify_ms : int;
  mutable ss_schnorr_verify_ms : int;
  mutable ss_interpreter_eval_ms : int;
}

type script_outcome = (int * int * string) option * script_timing_snapshot * int

type script_worker_summary = {
  sw_failure : (int * int * string) option;
  sw_timing : script_timing_snapshot;
  sw_worker_ms : int;
  sw_jobs : int;
}

let fresh_script_timing_snapshot () =
  {
    ss_sighash_legacy_ms = 0;
    ss_sighash_witness_ms = 0;
    ss_sighash_taproot_ms = 0;
    ss_ecdsa_verify_ms = 0;
    ss_schnorr_verify_ms = 0;
    ss_interpreter_eval_ms = 0;
  }

let empty_script_timing_snapshot = fresh_script_timing_snapshot ()

let snapshot_script_timing (row : Script_verify.script_timing) =
  {
    ss_sighash_legacy_ms = row.script_sighash_legacy_ms;
    ss_sighash_witness_ms = row.script_sighash_witness_ms;
    ss_sighash_taproot_ms = row.script_sighash_taproot_ms;
    ss_ecdsa_verify_ms = row.script_ecdsa_verify_ms;
    ss_schnorr_verify_ms = row.script_schnorr_verify_ms;
    ss_interpreter_eval_ms = row.script_interpreter_eval_ms;
  }

let add_snapshot into row =
  into.ss_sighash_legacy_ms <- into.ss_sighash_legacy_ms + row.ss_sighash_legacy_ms;
  into.ss_sighash_witness_ms <- into.ss_sighash_witness_ms + row.ss_sighash_witness_ms;
  into.ss_sighash_taproot_ms <- into.ss_sighash_taproot_ms + row.ss_sighash_taproot_ms;
  into.ss_ecdsa_verify_ms <- into.ss_ecdsa_verify_ms + row.ss_ecdsa_verify_ms;
  into.ss_schnorr_verify_ms <- into.ss_schnorr_verify_ms + row.ss_schnorr_verify_ms;
  into.ss_interpreter_eval_ms <- into.ss_interpreter_eval_ms + row.ss_interpreter_eval_ms

let earlier_failure current candidate =
  match current, candidate with
  | None, value -> value
  | value, None -> value
  | Some (a_tx, a_input, _), Some (b_tx, b_input, _) ->
      if compare (b_tx, b_input) (a_tx, a_input) < 0 then candidate else current

let empty_worker_summary () =
  { sw_failure = None; sw_timing = fresh_script_timing_snapshot (); sw_worker_ms = 0; sw_jobs = 0 }

type script_worker_pool = {
  mutex : Mutex.t;
  started : Condition.t;
  finished : Condition.t;
  mutable jobs : script_task array;
  mutable summaries : script_worker_summary option array;
  mutable ranges : (int * int) array;
  mutable active_workers : int;
  mutable completed_workers : int;
  mutable generation : int;
  mutable stopping : bool;
  mutable verify : (Crypto.verifier -> script_task -> script_outcome) option;
  mutable workers : unit Domain.t list;
}

let incr_count counts key =
  Hashtbl.replace counts key (1 + Option.value ~default:0 (Hashtbl.find_opt counts key))

let counts_to_list counts =
  Hashtbl.fold (fun key value acc -> (key, value) :: acc) counts []
  |> List.sort (fun (a, _) (b, _) -> String.compare a b)

let input_shape tx input_index (prevout : Script_verify.spent_prevout) =
  let witness_items = if input_index < List.length tx.Tx.witness then List.length (List.nth tx.Tx.witness input_index) else 0 in
  classify_script prevout.Script_verify.script_pubkey ^ if witness_items > 0 then "+witness" else "+legacy"

let script_threads () =
  let configured =
    try int_of_string (Sys.getenv "OCBITNODE_SCRIPT_THREADS")
    with _ -> max 2 (min 4 (Domain.recommended_domain_count ()))
  in
  max 1 configured

let script_parallel_min_inputs () =
  try int_of_string (Sys.getenv "OCBITNODE_SCRIPT_PARALLEL_MIN_INPUTS")
  with _ -> 64

let process_worker_range verifier jobs verify start_index end_index =
  let summary = ref (empty_worker_summary ()) in
  for index = start_index to end_index - 1 do
    let failure, script_timing, worker_ms = verify verifier jobs.(index) in
    let current = !summary in
    let merged_timing = current.sw_timing in
    add_snapshot merged_timing script_timing;
    summary :=
      {
        sw_failure = earlier_failure current.sw_failure failure;
        sw_timing = merged_timing;
        sw_worker_ms = current.sw_worker_ms + worker_ms;
        sw_jobs = current.sw_jobs + 1;
      }
  done;
  !summary

let script_worker_loop pool worker_index =
  let verifier = Crypto.create_worker_verifier () in
  let rec loop seen_generation =
    Mutex.lock pool.mutex;
    while (not pool.stopping) && pool.generation = seen_generation do
      Condition.wait pool.started pool.mutex
    done;
    if pool.stopping then Mutex.unlock pool.mutex
    else
      let generation = pool.generation in
      let active_workers = pool.active_workers in
      let jobs = pool.jobs in
      let ranges = pool.ranges in
      let verify = pool.verify in
      Mutex.unlock pool.mutex;
      let summary =
        if worker_index >= active_workers then empty_worker_summary ()
        else
          match verify with
          | None -> empty_worker_summary ()
          | Some verify ->
              let start_index, end_index = ranges.(worker_index) in
              process_worker_range verifier jobs verify start_index end_index
      in
      Mutex.lock pool.mutex;
      if (not pool.stopping) && pool.generation = generation && worker_index < pool.active_workers then (
        pool.summaries.(worker_index) <- Some summary;
        pool.completed_workers <- pool.completed_workers + 1;
        if pool.completed_workers = pool.active_workers then (
          pool.verify <- None;
          Condition.broadcast pool.finished));
      Mutex.unlock pool.mutex;
      loop generation
  in
  Fun.protect ~finally:(fun () -> Crypto.close_verifier verifier) (fun () -> loop 0)

let create_script_worker_pool threads =
  let worker_count = max 1 threads in
  let pool =
    {
      mutex = Mutex.create ();
      started = Condition.create ();
      finished = Condition.create ();
      jobs = [||];
      summaries = [||];
      ranges = [||];
      active_workers = 0;
      completed_workers = 0;
      generation = 0;
      stopping = false;
      verify = None;
      workers = [];
    }
  in
  if worker_count > 1 then
    pool.workers <- List.init worker_count (fun worker_index -> Domain.spawn (fun () -> script_worker_loop pool worker_index));
  pool

let stop_script_worker_pool pool =
  Mutex.lock pool.mutex;
  pool.stopping <- true;
  Condition.broadcast pool.started;
  Condition.broadcast pool.finished;
  Mutex.unlock pool.mutex;
  List.iter (fun worker -> try Domain.join worker with _ -> ()) pool.workers

let with_script_worker_pool threads fn =
  let pool = create_script_worker_pool threads in
  Fun.protect ~finally:(fun () -> stop_script_worker_pool pool) (fun () -> fn pool)

let run_script_worker_pool pool tasks verify =
  let task_array = Array.of_list tasks in
  if Array.length task_array = 0 then ([], 0)
  else (
    let worker_count = max 1 (List.length pool.workers) in
    let active_workers = min worker_count (Array.length task_array) in
    let chunk_size = max 1 ((Array.length task_array + active_workers - 1) / active_workers) in
    Mutex.lock pool.mutex;
    pool.jobs <- task_array;
    pool.summaries <- Array.make active_workers None;
    pool.ranges <-
      Array.init active_workers (fun worker_index ->
          let start_index = worker_index * chunk_size in
          let end_index = min (Array.length task_array) (start_index + chunk_size) in
          start_index, end_index);
    pool.completed_workers <- 0;
    pool.active_workers <- active_workers;
    pool.verify <- Some verify;
    pool.generation <- pool.generation + 1;
    Condition.broadcast pool.started;
    while pool.completed_workers < pool.active_workers && not pool.stopping do
      Condition.wait pool.finished pool.mutex
    done;
    let summaries = Array.to_list pool.summaries |> List.map (function Some row -> row | None -> empty_worker_summary ()) in
    pool.jobs <- [||];
    pool.ranges <- [||];
    pool.active_workers <- 0;
    Mutex.unlock pool.mutex;
    summaries, active_workers)

let add_script_timing timing row =
  timing.script_sighash_legacy_ms <- timing.script_sighash_legacy_ms + row.ss_sighash_legacy_ms;
  timing.script_sighash_witness_ms <- timing.script_sighash_witness_ms + row.ss_sighash_witness_ms;
  timing.script_sighash_taproot_ms <- timing.script_sighash_taproot_ms + row.ss_sighash_taproot_ms;
  timing.script_ecdsa_verify_ms <- timing.script_ecdsa_verify_ms + row.ss_ecdsa_verify_ms;
  timing.script_schnorr_verify_ms <- timing.script_schnorr_verify_ms + row.ss_schnorr_verify_ms;
  timing.script_interpreter_eval_ms <- timing.script_interpreter_eval_ms + row.ss_interpreter_eval_ms

let verify_script_jobs ?script_pool txs txids height block_hash script_jobs timing input_shape_counts spent_prevout_script_types =
  let tx_array = Array.of_list txs in
  let txid_array = Array.of_list txids in
  let verify_one verifier (task : script_task) =
    let started = now_ms () in
    try
      let tx = tx_array.(task.tx_index) in
      let options : Script_verify.verify_input_options =
        { script_pubkey = task.prevout.script_pubkey; amount = task.prevout.amount; spent_prevouts = task.spent_prevouts }
      in
      let result, script_timing = Script_verify.verify_transaction_input_with_cache_and_timing ~cache:task.cache ~verifier tx task.input_index options in
      let failure = match result with Ok () -> None | Error failure -> Some (task.tx_index, task.input_index, failure) in
      failure, snapshot_script_timing script_timing, elapsed started
    with exn -> Some (task.tx_index, task.input_index, Printexc.to_string exn), empty_script_timing_snapshot, elapsed started
  in
  let tasks : script_task list =
    script_jobs
    |> List.concat_map (fun (tx_index, spent_prevouts, cache) ->
           List.mapi
             (fun input_index (prevout : Script_verify.spent_prevout) -> { tx_index; input_index; prevout; spent_prevouts; cache })
             spent_prevouts)
  in
  let failures =
    let task_count = List.length tasks in
    let dispatch_started = now_ms () in
    let summaries, active_workers =
      if task_count = 0 then ([], 0)
      else if task_count < script_parallel_min_inputs () || script_threads () <= 1 then (
        let verifier = Crypto.create_worker_verifier () in
        let summary =
          Fun.protect ~finally:(fun () -> Crypto.close_verifier verifier) (fun () ->
              let task_array = Array.of_list tasks in
              process_worker_range verifier task_array verify_one 0 task_count)
        in
        [ summary ], 1)
      else
        match script_pool with
        | Some pool -> run_script_worker_pool pool tasks verify_one
        | None ->
            let task_array = Array.of_list tasks in
            let active_workers = min (script_threads ()) task_count in
            let chunk_size = max 1 ((task_count + active_workers - 1) / active_workers) in
            let worker worker_index =
              let verifier = Crypto.create_worker_verifier () in
              Fun.protect ~finally:(fun () -> Crypto.close_verifier verifier) (fun () ->
                  let start_index = worker_index * chunk_size in
                  let end_index = min task_count (start_index + chunk_size) in
                  process_worker_range verifier task_array verify_one start_index end_index)
            in
            let domains = List.init active_workers (fun worker_index -> Domain.spawn (fun () -> worker worker_index)) in
            List.map Domain.join domains, active_workers
    in
    timing.script_job_dispatch_ms <- timing.script_job_dispatch_ms + elapsed dispatch_started;
    timing.script_runner_wait_ms <- timing.script_runner_wait_ms + elapsed dispatch_started;
    timing.script_active_workers <- max timing.script_active_workers active_workers;
    List.iter
      (fun summary ->
        add_script_timing timing summary.sw_timing;
        timing.script_verify_worker_cpu_ms <- timing.script_verify_worker_cpu_ms + summary.sw_worker_ms)
      summaries;
    List.filter_map (fun summary -> summary.sw_failure) summaries
  in
  List.iter
    (fun (task : script_task) ->
      incr_count spent_prevout_script_types (classify_script task.prevout.script_pubkey);
      incr_count input_shape_counts (input_shape tx_array.(task.tx_index) task.input_index task.prevout))
    tasks;
  match List.sort (fun (a_tx, a_in, _) (b_tx, b_in, _) -> compare (a_tx, a_in) (b_tx, b_in)) failures with
  | [] -> ()
  | (tx_index, input_index, failure) :: _ ->
      raise
        (Connect_error
           (blocker ~height ~block_hash ~txid:txid_array.(tx_index) ~input:input_index ~missing_rule:"script_verify_failed" ~failure))

let connect_block ~script_pool ~db ~height ~target ~raw ~expected_hash ~expected_prev ~file_number ~file_offset ~utxo_count =
  let block_started = now_ms () in
  let timing = empty_timing () in
  let parse_started = now_ms () in
  let block, block_hash = parse_block raw expected_hash expected_prev in
  timing.block_parse_validate_ms <- elapsed parse_started;
  let txs = block.Block.transactions in
  let tx_array = Array.of_list txs in
  if txs = [] || not (Tx.is_coinbase (List.hd txs)) then
    raise (Connect_error (blocker ~height ~block_hash ~txid:"" ~input:0 ~missing_rule:"block_first_transaction_not_coinbase" ~failure:"block does not begin with a coinbase transaction"));
  let load_started = now_ms () in
  let loaded = load_prevouts db txs in
  timing.utxo_load_ms <- elapsed load_started;
  let created = Hashtbl.create 128 in
  let spent = Hashtbl.create 64 in
  let undo_entries = ref [] in
  let script_jobs = ref [] in
  let txids = Array.map Tx.txid tx_array in
  let txid_internals = Array.map Tx.txid_internal tx_array in
  let vin_count = ref 0 in
  let vout_count = ref 0 in
  let script_input_count = ref 0 in
  let input_shape_counts = Hashtbl.create 16 in
  let spent_prevout_script_types = Hashtbl.create 16 in
  let output_script_types = Hashtbl.create 16 in
  List.iteri
    (fun tx_index tx ->
      let txid = txids.(tx_index) in
      let txid_internal = txid_internals.(tx_index) in
      vin_count := !vin_count + List.length tx.Tx.inputs;
      vout_count := !vout_count + List.length tx.Tx.outputs;
      List.iter (fun output -> incr_count output_script_types (classify_script output.Tx.script_pubkey)) tx.Tx.outputs;
      if tx_index = 0 then (
        if height <> 0 then
          List.iter (fun utxo -> Hashtbl.replace created (utxo_key utxo) utxo) (output_utxos height tx txid_internal true))
      else (
        if tx.inputs = [] then
          raise (Connect_error (blocker ~height ~block_hash ~txid ~input:0 ~missing_rule:"transaction_without_inputs" ~failure:"non-coinbase transaction has no inputs"));
        let spent_prevouts = Array.make (List.length tx.inputs) { Script_verify.amount = 0L; script_pubkey = "" } in
        let input_utxos = ref [] in
        let input_keys = Hashtbl.create (List.length tx.inputs) in
        List.iteri
          (fun input_index input ->
            let key = spent_key input in
            if Hashtbl.mem input_keys key || Hashtbl.mem spent key then
              raise (Connect_error (blocker ~height ~block_hash ~txid ~input:input_index ~missing_rule:"duplicate_spend" ~failure:"duplicate spend inside block"));
            Hashtbl.add input_keys key true;
            match find_utxo loaded created key with
            | None ->
                raise (Connect_error (blocker ~height ~block_hash ~txid ~input:input_index ~missing_rule:"missing_utxo" ~failure:"OCaml connect could not find the spent prevout"))
            | Some utxo ->
                if utxo.coinbase && height - utxo.height < 100 then
                  raise (Connect_error (blocker ~height ~block_hash ~txid ~input:input_index ~missing_rule:"coinbase_maturity" ~failure:"coinbase spend before 100 confirmations"));
                spent_prevouts.(input_index) <- { Script_verify.amount = utxo.value_sats; script_pubkey = utxo.script_pubkey };
                incr script_input_count;
                input_utxos := (key, utxo) :: !input_utxos)
          tx.inputs;
        let cache_started = now_ms () in
        let spent_prevouts_list = Array.to_list spent_prevouts in
        let cache = Script_verify.create_sighash_cache tx spent_prevouts_list in
        timing.script_sighash_cache_build_ms <- timing.script_sighash_cache_build_ms + elapsed cache_started;
        script_jobs := (tx_index, spent_prevouts_list, cache) :: !script_jobs;
        List.iter
          (fun (key, utxo) ->
            if Hashtbl.mem created key then Hashtbl.remove created key;
            Hashtbl.replace spent key utxo)
          !input_utxos;
        List.iter (fun utxo -> Hashtbl.replace created (utxo_key utxo) utxo) (output_utxos height tx txid_internal false)))
    txs;
  let script_started = now_ms () in
  verify_script_jobs ?script_pool (Array.to_list tx_array) (Array.to_list txids) height block_hash (List.rev !script_jobs) timing input_shape_counts spent_prevout_script_types;
  timing.script_verify_ms <- elapsed script_started;
  timing.script_wall_ms <- timing.script_verify_ms;
  if timing.script_runner_wait_ms = 0 then timing.script_runner_wait_ms <- timing.script_verify_ms;
  let apply_started = now_ms () in
  let external_spend_count = ref 0 in
  Hashtbl.iter
    (fun key utxo ->
      if Hashtbl.mem loaded key then (
        incr external_spend_count;
        undo_entries := (utxo.txid, utxo.vout, utxo.height, utxo.coinbase, utxo.value_sats, utxo.script_pubkey) :: !undo_entries))
    spent;
  let next_count = !utxo_count - !external_spend_count + Hashtbl.length created in
  utxo_count := next_count;
  timing.utxo_apply_ms <- elapsed apply_started;
  let commit_started = now_ms () in
  Rocks.write_batch db ~disable_wal:false ~sync:false (fun batch ->
      Rocks.batch_put batch (Codec_v2.height_key "h" chain height) (Codec_v2.header_value block.header.raw);
      Rocks.batch_put batch (Codec_v2.height_key "b" chain height)
        (Codec_v2.block_index_value ~hash:(Block.header_hash block.header) ~file_number ~file_offset ~block_size:(String.length raw));
      Rocks.batch_put batch (Codec_v2.height_key "d" chain height) (Codec_v2.undo_value !undo_entries);
      Hashtbl.iter
        (fun key utxo ->
          if Hashtbl.mem loaded key then Rocks.batch_delete batch (Codec_v2.utxo_key ~chain ~txid:utxo.txid ~vout:utxo.vout))
        spent;
      Hashtbl.iter
        (fun _key utxo ->
          Rocks.batch_put batch (Codec_v2.utxo_key ~chain ~txid:utxo.txid ~vout:utxo.vout)
            (Codec_v2.utxo_value ~height:utxo.height ~vout:utxo.vout ~value_sats:utxo.value_sats ~coinbase:utxo.coinbase ~script_pubkey:utxo.script_pubkey))
        created;
      Rocks.batch_put batch (Codec_v2.tip_key chain) (Codec_v2.tip_value ~height ~hash:(Block.header_hash block.header));
      Rocks.batch_put batch (Codec_v2.metadata_key "status") (if height >= target then "blocks_current" else "blocks_syncing");
      Rocks.batch_put batch (Codec_v2.metadata_key "blocker") "none";
      Rocks.batch_put batch (Codec_v2.metadata_key "validated_height") (encode_int height);
      Rocks.batch_put batch (Codec_v2.metadata_key "header_height") (encode_int height);
      Rocks.batch_put batch (Codec_v2.metadata_key "stored_block_height") (encode_int height);
      Rocks.batch_put batch (Codec_v2.metadata_key "validated_hash") block_hash;
      Rocks.batch_put batch (Codec_v2.metadata_key "header_hash") block_hash;
      Rocks.batch_put batch (Codec_v2.metadata_key "stored_block_hash") block_hash;
      Rocks.batch_put batch (Codec_v2.metadata_key "chainstate_utxo_count") (encode_int next_count);
      Rocks.batch_put batch (Codec_v2.metadata_key "utxo_accounting_policy") "core_spendable_v1";
      Rocks.batch_put batch (Codec_v2.metadata_key "native_crypto_backend") "libsecp256k1";
      Rocks.batch_put batch (Codec_v2.metadata_key "rocksdb_sync_writes") "false");
  timing.commit_ms <- elapsed commit_started;
  timing.block_connect_store_commit_ms <- elapsed block_started;
  {
    block_hash;
    tx_count = List.length txs;
    vin_count = !vin_count;
    vout_count = !vout_count;
    script_input_count = !script_input_count;
    input_shape_counts = counts_to_list input_shape_counts;
    spent_prevout_script_types = counts_to_list spent_prevout_script_types;
    output_script_types = counts_to_list output_script_types;
    block_size = String.length raw;
    chainstate_utxo_count = next_count;
    timing;
  }

let status db =
  `Assoc [
    "validated_height", `Int (metadata_height db "validated_height");
    "header_height", `Int (metadata_height db "header_height");
    "stored_block_height", `Int (metadata_height db "stored_block_height");
    "validated_hash", `String (metadata_string db "validated_hash" "");
    "header_hash", `String (metadata_string db "header_hash" "");
    "stored_block_hash", `String (metadata_string db "stored_block_hash" "");
    "sync_status", `String (metadata_string db "status" "not_started");
    "current_blocker", `String (metadata_string db "blocker" "none");
    "chainstate_utxo_count", `Int (metadata_height db "chainstate_utxo_count");
    "utxo_accounting_policy", `String (metadata_string db "utxo_accounting_policy" "");
    "native_crypto_backend", `String (metadata_string db "native_crypto_backend" "");
  ]
