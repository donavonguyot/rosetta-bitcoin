exception Connect_error of Yojson.Safe.t

type timing_buckets = {
  mutable p2p_fetch_ms : int;
  mutable block_parse_validate_ms : int;
  mutable block_store_ms : int;
  mutable utxo_load_ms : int;
  mutable utxo_lookup_count : int;
  mutable utxo_key_bytes : int;
  mutable utxo_value_bytes : int;
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
  mutable script_worker_jobs : int;
  mutable script_chunk_count : int;
  mutable script_chunk_size : int;
  mutable script_worker_loop_ms : int;
  mutable script_worker_join_ms : int;
  mutable script_dispatch_setup_ms : int;
  mutable runner_batches : int;
  mutable utxo_apply_ms : int;
  mutable created_utxos : int;
  mutable spent_external : int;
  mutable same_block_spends : int;
  mutable same_block_prevout_skipped : int;
  mutable tx_count_total : int;
  mutable input_count_total : int;
  mutable utxo_key_encode_ms : int;
  mutable utxo_value_decode_ms : int;
  mutable writebatch_prepare_ms : int;
  mutable rocksdb_write_ms : int;
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
    utxo_lookup_count = 0;
    utxo_key_bytes = 0;
    utxo_value_bytes = 0;
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
    script_worker_jobs = 0;
    script_chunk_count = 0;
    script_chunk_size = 0;
    script_worker_loop_ms = 0;
    script_worker_join_ms = 0;
    script_dispatch_setup_ms = 0;
    runner_batches = 0;
    utxo_apply_ms = 0;
    created_utxos = 0;
    spent_external = 0;
    same_block_spends = 0;
    same_block_prevout_skipped = 0;
    tx_count_total = 0;
    input_count_total = 0;
    utxo_key_encode_ms = 0;
    utxo_value_decode_ms = 0;
    writebatch_prepare_ms = 0;
    rocksdb_write_ms = 0;
    commit_ms = 0;
    block_connect_store_commit_ms = 0;
  }

let add_timing total row =
  total.p2p_fetch_ms <- total.p2p_fetch_ms + row.p2p_fetch_ms;
  total.block_parse_validate_ms <- total.block_parse_validate_ms + row.block_parse_validate_ms;
  total.block_store_ms <- total.block_store_ms + row.block_store_ms;
  total.utxo_load_ms <- total.utxo_load_ms + row.utxo_load_ms;
  total.utxo_lookup_count <- total.utxo_lookup_count + row.utxo_lookup_count;
  total.utxo_key_bytes <- total.utxo_key_bytes + row.utxo_key_bytes;
  total.utxo_value_bytes <- total.utxo_value_bytes + row.utxo_value_bytes;
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
  total.script_worker_jobs <- total.script_worker_jobs + row.script_worker_jobs;
  total.script_chunk_count <- total.script_chunk_count + row.script_chunk_count;
  total.script_chunk_size <- max total.script_chunk_size row.script_chunk_size;
  total.script_worker_loop_ms <- total.script_worker_loop_ms + row.script_worker_loop_ms;
  total.script_worker_join_ms <- total.script_worker_join_ms + row.script_worker_join_ms;
  total.script_dispatch_setup_ms <- total.script_dispatch_setup_ms + row.script_dispatch_setup_ms;
  total.runner_batches <- total.runner_batches + row.runner_batches;
  total.utxo_apply_ms <- total.utxo_apply_ms + row.utxo_apply_ms;
  total.created_utxos <- total.created_utxos + row.created_utxos;
  total.spent_external <- total.spent_external + row.spent_external;
  total.same_block_spends <- total.same_block_spends + row.same_block_spends;
  total.same_block_prevout_skipped <- total.same_block_prevout_skipped + row.same_block_prevout_skipped;
  total.tx_count_total <- total.tx_count_total + row.tx_count_total;
  total.input_count_total <- total.input_count_total + row.input_count_total;
  total.utxo_key_encode_ms <- total.utxo_key_encode_ms + row.utxo_key_encode_ms;
  total.utxo_value_decode_ms <- total.utxo_value_decode_ms + row.utxo_value_decode_ms;
  total.writebatch_prepare_ms <- total.writebatch_prepare_ms + row.writebatch_prepare_ms;
  total.rocksdb_write_ms <- total.rocksdb_write_ms + row.rocksdb_write_ms;
  total.commit_ms <- total.commit_ms + row.commit_ms;
  total.block_connect_store_commit_ms <- total.block_connect_store_commit_ms + row.block_connect_store_commit_ms

let outpoint txid vout : Rocks.outpoint = { Rocks.txid; vout }

let utxo_outpoint utxo = outpoint utxo.txid utxo.vout

let spent_outpoint input =
  outpoint input.Tx.previous_output.hash (Int32.to_int input.previous_output.index)

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
  let script_len, script_offset = Codec_v2.read_compact_size raw 17 in
  if script_offset + script_len <> String.length raw then invalid_arg "codec v2 utxo script length mismatch";
  let script_pubkey = String.sub raw script_offset script_len in
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

let block_mutation_shape tx_array =
  let spends = ref 0 in
  let creates = ref 0 in
  Array.iteri
    (fun tx_index tx ->
      if tx_index <> 0 then spends := !spends + List.length tx.Tx.inputs;
      List.iter (fun output -> if is_spendable_output output.Tx.script_pubkey then incr creates) tx.Tx.outputs)
    tx_array;
  !spends, !creates

let build_in_block_spendable_outputs tx_array expected_creates =
  let outputs = Hashtbl.create (max 16 expected_creates) in
  Array.iteri
    (fun tx_index tx ->
      let txid = Tx.txid_internal tx in
      tx.Tx.outputs
      |> List.iteri (fun vout output ->
             if is_spendable_output output.Tx.script_pubkey then
               Hashtbl.replace outputs (outpoint txid vout) tx_index))
    tx_array;
  outputs

let gather_external_prevouts tx_array timing =
  let expected_spends, expected_creates = block_mutation_shape tx_array in
  let in_block_outputs = build_in_block_spendable_outputs tx_array expected_creates in
  let seen = Hashtbl.create (max 16 expected_spends) in
  let rows = ref [] in
  for tx_index = 1 to Array.length tx_array - 1 do
    let tx = tx_array.(tx_index) in
    List.iter
      (fun input ->
        let key = spent_outpoint input in
        match Hashtbl.find_opt in_block_outputs key with
        | Some creator_index when creator_index < tx_index ->
            timing.same_block_prevout_skipped <- timing.same_block_prevout_skipped + 1
        | _ ->
        if not (Hashtbl.mem seen key) then (
          Hashtbl.add seen key true;
          rows := key :: !rows))
      tx.Tx.inputs
  done;
  Array.of_list (List.rev !rows)

let load_prevouts db tx_array timing =
  let prevouts = gather_external_prevouts tx_array timing in
  let rows, stats = Rocks.multi_get_utxos db ~chain prevouts in
  timing.utxo_lookup_count <- timing.utxo_lookup_count + stats.lookup_count;
  timing.utxo_key_bytes <- timing.utxo_key_bytes + stats.key_bytes;
  timing.utxo_value_bytes <- timing.utxo_value_bytes + stats.value_bytes;
  timing.utxo_key_encode_ms <- timing.utxo_key_encode_ms + stats.multi_get_ms;
  timing.utxo_value_decode_ms <- timing.utxo_value_decode_ms + stats.decode_ms;
  let fill_started = now_ms () in
  let loaded = Hashtbl.create (max 16 (Array.length prevouts)) in
  Array.iteri
    (fun index value ->
      match value with
      | Some (row : Rocks.utxo_row) ->
          Hashtbl.add loaded prevouts.(index)
            {
              txid = row.txid;
              vout = row.vout;
              height = row.height;
              value_sats = row.value_sats;
              coinbase = row.coinbase;
              script_pubkey = row.script_pubkey;
            }
      | None -> ())
    rows;
  timing.utxo_value_decode_ms <- timing.utxo_value_decode_ms + elapsed fill_started;
  loaded

let find_utxo loaded created key =
  match Hashtbl.find_opt created key with
  | Some utxo -> Some (`Created utxo)
  | None -> Option.map (fun utxo -> `Loaded utxo) (Hashtbl.find_opt loaded key)

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

let sighash_needs_for_prevouts prevouts =
  let needs = ref { Script_verify.needs_legacy = false; needs_bip143 = false; needs_taproot = false } in
  Array.iter
    (fun (prevout : Script_verify.spent_prevout) ->
      match classify_script prevout.script_pubkey with
      | "p2wpkh" | "p2wsh" -> needs := { !needs with needs_bip143 = true }
      | "p2tr" -> needs := { !needs with needs_taproot = true }
      | "p2sh" -> needs := { !needs with needs_legacy = true; needs_bip143 = true }
      | _ -> needs := { !needs with needs_legacy = true })
    prevouts;
  !needs

type script_input = {
  tx_index : int;
  input_index : int;
  job_index : int;
}

type script_chunk = {
  first_task : int;
  task_count : int;
}

type script_job = {
  job_tx_index : int;
  job_spent_prevouts : Script_verify.spent_prevout array;
  job_cache : Script_verify.sighash_cache;
}

type script_timing_snapshot = {
  mutable ss_sighash_legacy_ms : int;
  mutable ss_sighash_witness_ms : int;
  mutable ss_sighash_taproot_ms : int;
  mutable ss_ecdsa_verify_ms : int;
  mutable ss_schnorr_verify_ms : int;
  mutable ss_interpreter_eval_ms : int;
}

type script_outcome = (int * int * string) option * script_timing_snapshot * string * string

type script_worker_summary = {
  sw_failure : (int * int * string) option;
  sw_timing : script_timing_snapshot;
  sw_worker_ms : int;
  sw_jobs : int;
  sw_loop_ms : int;
  sw_input_shape_counts : (string, int) Hashtbl.t;
  sw_spent_prevout_script_types : (string, int) Hashtbl.t;
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
  {
    sw_failure = None;
    sw_timing = fresh_script_timing_snapshot ();
    sw_worker_ms = 0;
    sw_jobs = 0;
    sw_loop_ms = 0;
    sw_input_shape_counts = Hashtbl.create 16;
    sw_spent_prevout_script_types = Hashtbl.create 16;
  }

type script_worker_pool = {
  mutex : Mutex.t;
  started : Condition.t;
  finished : Condition.t;
  mutable inputs : script_input array;
  mutable chunk_size : int;
  mutable summaries : script_worker_summary option array;
  next_index : int Atomic.t;
  mutable active_workers : int;
  mutable completed_workers : int;
  mutable generation : int;
  mutable stopping : bool;
  mutable verify : (Crypto.verifier -> script_input -> script_outcome) option;
  mutable workers : unit Domain.t list;
}

let incr_count counts key =
  Hashtbl.replace counts key (1 + Option.value ~default:0 (Hashtbl.find_opt counts key))

let counts_to_list counts =
  Hashtbl.fold (fun key value acc -> (key, value) :: acc) counts []
  |> List.sort (fun (a, _) (b, _) -> String.compare a b)

let merge_counts into from =
  Hashtbl.iter (fun key value -> Hashtbl.replace into key (value + Option.value ~default:0 (Hashtbl.find_opt into key))) from

let input_shape_from_cache (cache : Script_verify.sighash_cache) input_index (prevout : Script_verify.spent_prevout) =
  let witness_items = if input_index < Array.length cache.witness then List.length cache.witness.(input_index) else 0 in
  classify_script prevout.Script_verify.script_pubkey ^ if witness_items > 0 then "+witness" else "+legacy"

let script_threads () =
  let configured =
    try int_of_string (Sys.getenv "OCBITNODE_SCRIPT_THREADS")
    with _ -> max 2 (min 8 (Domain.recommended_domain_count ()))
  in
  max 1 configured

let script_parallel_min_inputs () =
  try int_of_string (Sys.getenv "OCBITNODE_SCRIPT_PARALLEL_MIN_INPUTS")
  with _ -> 64

let script_chunk_size () =
  let configured =
    try int_of_string (Sys.getenv "OCBITNODE_SCRIPT_CHUNK_SIZE")
    with _ -> 4
  in
  max 1 configured

let build_script_chunks task_count chunk_size =
  let chunk_size = max 1 chunk_size in
  if task_count <= 0 then [||]
  else
    let chunk_count = (task_count + chunk_size - 1) / chunk_size in
    Array.init chunk_count (fun index ->
        let first_task = index * chunk_size in
        { first_task; task_count = min chunk_size (task_count - first_task) })

let script_chunk_bounds chunks =
  Array.map (fun chunk -> chunk.first_task, chunk.task_count) chunks

let process_one_script_input summary verifier inputs verify index =
  let failure, script_timing, spent_prevout_script_type, input_shape = verify verifier inputs.(index) in
  let current = !summary in
  let merged_timing = current.sw_timing in
  add_snapshot merged_timing script_timing;
  incr_count current.sw_spent_prevout_script_types spent_prevout_script_type;
  incr_count current.sw_input_shape_counts input_shape;
  summary :=
    {
      sw_failure = earlier_failure current.sw_failure failure;
      sw_timing = merged_timing;
      sw_worker_ms = current.sw_worker_ms;
      sw_jobs = current.sw_jobs + 1;
      sw_loop_ms = current.sw_loop_ms;
      sw_input_shape_counts = current.sw_input_shape_counts;
      sw_spent_prevout_script_types = current.sw_spent_prevout_script_types;
    }

let merge_worker_summary into row =
  let current = !into in
  add_snapshot current.sw_timing row.sw_timing;
  merge_counts current.sw_input_shape_counts row.sw_input_shape_counts;
  merge_counts current.sw_spent_prevout_script_types row.sw_spent_prevout_script_types;
  into :=
    {
      sw_failure = earlier_failure current.sw_failure row.sw_failure;
      sw_timing = current.sw_timing;
      sw_worker_ms = current.sw_worker_ms + row.sw_worker_ms;
      sw_jobs = current.sw_jobs + row.sw_jobs;
      sw_loop_ms = current.sw_loop_ms + row.sw_loop_ms;
      sw_input_shape_counts = current.sw_input_shape_counts;
      sw_spent_prevout_script_types = current.sw_spent_prevout_script_types;
    }

let process_one_script_chunk verifier inputs verify first_task task_count =
  let summary = ref (empty_worker_summary ()) in
  let loop_started = now_ms () in
  for offset = 0 to task_count - 1 do
    process_one_script_input summary verifier inputs verify (first_task + offset)
  done;
  let worker_ms = elapsed loop_started in
  let current = !summary in
  { current with sw_worker_ms = current.sw_worker_ms + worker_ms; sw_loop_ms = current.sw_loop_ms + worker_ms }

let process_worker_cursor verifier inputs verify next_index chunk_size =
  let summary = ref (empty_worker_summary ()) in
  let chunk_size = max 1 chunk_size in
  let rec loop () =
    let index = Atomic.fetch_and_add next_index chunk_size in
    if index < Array.length inputs then (
      let task_count = min chunk_size (Array.length inputs - index) in
      merge_worker_summary summary (process_one_script_chunk verifier inputs verify index task_count);
      loop ())
  in
  loop ();
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
      let inputs = pool.inputs in
      let chunk_size = pool.chunk_size in
      let next_index = pool.next_index in
      let verify = pool.verify in
      Mutex.unlock pool.mutex;
      let summary =
        if worker_index >= active_workers then empty_worker_summary ()
        else
          match verify with
          | None -> empty_worker_summary ()
          | Some verify -> process_worker_cursor verifier inputs verify next_index chunk_size
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
      inputs = [||];
      chunk_size = 1;
      summaries = [||];
      next_index = Atomic.make 0;
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

let run_script_worker_pool pool inputs chunk_count chunk_size verify =
  if chunk_count = 0 then ([], 0, 0)
  else (
    let worker_count = max 1 (List.length pool.workers) in
    let active_workers = min worker_count chunk_count in
    Mutex.lock pool.mutex;
    pool.inputs <- inputs;
    pool.chunk_size <- max 1 chunk_size;
    pool.summaries <- Array.make active_workers None;
    Atomic.set pool.next_index 0;
    pool.completed_workers <- 0;
    pool.active_workers <- active_workers;
    pool.verify <- Some verify;
    pool.generation <- pool.generation + 1;
    Condition.broadcast pool.started;
    let join_started = now_ms () in
    while pool.completed_workers < pool.active_workers && not pool.stopping do
      Condition.wait pool.finished pool.mutex
    done;
    let join_ms = elapsed join_started in
    let summaries = Array.to_list pool.summaries |> List.map (function Some row -> row | None -> empty_worker_summary ()) in
    pool.inputs <- [||];
    pool.chunk_size <- 1;
    pool.active_workers <- 0;
    Mutex.unlock pool.mutex;
    summaries, active_workers, join_ms)

let add_script_timing timing row =
  timing.script_sighash_legacy_ms <- timing.script_sighash_legacy_ms + row.ss_sighash_legacy_ms;
  timing.script_sighash_witness_ms <- timing.script_sighash_witness_ms + row.ss_sighash_witness_ms;
  timing.script_sighash_taproot_ms <- timing.script_sighash_taproot_ms + row.ss_sighash_taproot_ms;
  timing.script_ecdsa_verify_ms <- timing.script_ecdsa_verify_ms + row.ss_ecdsa_verify_ms;
  timing.script_schnorr_verify_ms <- timing.script_schnorr_verify_ms + row.ss_schnorr_verify_ms;
  timing.script_interpreter_eval_ms <- timing.script_interpreter_eval_ms + row.ss_interpreter_eval_ms

let verify_script_jobs ?script_pool tx_array txid_array height block_hash script_jobs timing input_shape_counts spent_prevout_script_types =
  let verify_one verifier (task : script_input) =
    try
      let tx = tx_array.(task.tx_index) in
      let job = script_jobs.(task.job_index) in
      let prevout = job.job_spent_prevouts.(task.input_index) in
      let cache = job.job_cache in
      let result, script_timing =
        Script_verify.verify_transaction_input_cached_fields_with_timing ~cache ~verifier tx task.input_index ~script_pubkey:prevout.script_pubkey
          ~amount:prevout.amount
      in
      let failure = match result with Ok () -> None | Error failure -> Some (task.tx_index, task.input_index, failure) in
      failure, snapshot_script_timing script_timing, classify_script prevout.script_pubkey, input_shape_from_cache cache task.input_index prevout
    with exn -> Some (task.tx_index, task.input_index, Printexc.to_string exn), empty_script_timing_snapshot, "unknown", "unknown"
  in
  let task_count =
    Array.fold_left (fun total job -> total + Array.length job.job_spent_prevouts) 0 script_jobs
  in
  let setup_started = now_ms () in
  let inputs =
    let rows = Array.make task_count { tx_index = 0; input_index = 0; job_index = 0 } in
    let offset = ref 0 in
    Array.iteri
      (fun job_index job ->
        Array.iteri
          (fun input_index _prevout ->
            rows.(!offset) <- { tx_index = job.job_tx_index; input_index; job_index };
            incr offset)
          job.job_spent_prevouts)
      script_jobs;
    rows
  in
  let chunk_size = script_chunk_size () in
  let chunk_count = if task_count <= 0 then 0 else (task_count + chunk_size - 1) / chunk_size in
  timing.script_dispatch_setup_ms <- timing.script_dispatch_setup_ms + elapsed setup_started;
  timing.script_chunk_count <- timing.script_chunk_count + chunk_count;
  if task_count > 0 then timing.script_chunk_size <- max timing.script_chunk_size chunk_size;
  let failures =
    let dispatch_started = now_ms () in
    let summaries, active_workers, join_ms =
      if task_count = 0 then ([], 0, 0)
      else if task_count < script_parallel_min_inputs () || script_threads () <= 1 then (
        let verifier = Crypto.create_worker_verifier () in
        let summary =
          Fun.protect ~finally:(fun () -> Crypto.close_verifier verifier) (fun () ->
              process_worker_cursor verifier inputs verify_one (Atomic.make 0) chunk_size)
        in
        [ summary ], 1, 0)
      else
        match script_pool with
        | Some pool -> run_script_worker_pool pool inputs chunk_count chunk_size verify_one
        | None ->
            let active_workers = min (script_threads ()) chunk_count in
            let next_index = Atomic.make 0 in
            let worker worker_index =
              ignore worker_index;
              let verifier = Crypto.create_worker_verifier () in
              Fun.protect ~finally:(fun () -> Crypto.close_verifier verifier) (fun () ->
                  process_worker_cursor verifier inputs verify_one next_index chunk_size)
            in
            let domains = List.init active_workers (fun worker_index -> Domain.spawn (fun () -> worker worker_index)) in
            let join_started = now_ms () in
            let summaries = List.map Domain.join domains in
            summaries, active_workers, elapsed join_started
    in
    if task_count > 0 then timing.runner_batches <- timing.runner_batches + 1;
    timing.script_job_dispatch_ms <- timing.script_job_dispatch_ms + elapsed dispatch_started;
    timing.script_runner_wait_ms <- timing.script_runner_wait_ms + elapsed dispatch_started;
    timing.script_worker_join_ms <- timing.script_worker_join_ms + join_ms;
    timing.script_active_workers <- max timing.script_active_workers active_workers;
    List.iter
      (fun summary ->
        add_script_timing timing summary.sw_timing;
        timing.script_verify_worker_cpu_ms <- timing.script_verify_worker_cpu_ms + summary.sw_worker_ms;
        timing.script_worker_jobs <- timing.script_worker_jobs + summary.sw_jobs;
        timing.script_worker_loop_ms <- timing.script_worker_loop_ms + summary.sw_loop_ms;
        merge_counts input_shape_counts summary.sw_input_shape_counts;
        merge_counts spent_prevout_script_types summary.sw_spent_prevout_script_types)
      summaries;
    List.filter_map (fun summary -> summary.sw_failure) summaries
  in
  match List.sort (fun (a_tx, a_in, _) (b_tx, b_in, _) -> compare (a_tx, a_in) (b_tx, b_in)) failures with
  | [] -> ()
  | (tx_index, input_index, failure) :: _ ->
      raise
        (Connect_error
           (blocker ~height ~block_hash ~txid:txid_array.(tx_index) ~input:input_index ~missing_rule:"script_verify_failed" ~failure))

(* Block-local UTXO view, script verification, then atomic chainstate commit. Missing rules -> validation blocker. *)
let connect_block ~script_pool ~db ~height ~target ~raw ~expected_hash ~expected_prev ~file_number ~file_offset ~utxo_count =
  let block_started = now_ms () in
  let timing = empty_timing () in
  let parse_started = now_ms () in
	  let block, block_hash = parse_block raw expected_hash expected_prev in
	  timing.block_parse_validate_ms <- elapsed parse_started;
	  let txs = block.Block.transactions in
	  let tx_array = Array.of_list txs in
    let expected_spends, expected_creates = block_mutation_shape tx_array in
	  timing.tx_count_total <- Array.length tx_array;
	  if txs = [] || not (Tx.is_coinbase (List.hd txs)) then
	    raise (Connect_error (blocker ~height ~block_hash ~txid:"" ~input:0 ~missing_rule:"block_first_transaction_not_coinbase" ~failure:"block does not begin with a coinbase transaction"));
	  let load_started = now_ms () in
	  let loaded = load_prevouts db tx_array timing in
	  timing.utxo_load_ms <- elapsed load_started;
	  let created = Hashtbl.create (max 16 expected_creates) in
	  let spent = Hashtbl.create (max 16 expected_spends) in
	  let spent_external = ref [] in
	  let same_block_spends = ref 0 in
	  let undo_entries = ref [] in
  let script_jobs = Array.make (max 0 (Array.length tx_array - 1))
      { job_tx_index = 0; job_spent_prevouts = [||]; job_cache = Script_verify.create_sighash_cache_for_array tx_array.(0) [||] Script_verify.empty_sighash_needs }
  in
  let txids = Array.map Tx.txid tx_array in
  let txid_internals = Array.map Tx.txid_internal tx_array in
  let vin_count = ref 0 in
  let vout_count = ref 0 in
  let script_input_count = ref 0 in
  let input_shape_counts = Hashtbl.create 16 in
  let spent_prevout_script_types = Hashtbl.create 16 in
  let output_script_types = Hashtbl.create 16 in
	  Array.iteri
	    (fun tx_index tx ->
	      let txid = txids.(tx_index) in
	      let txid_internal = txid_internals.(tx_index) in
	      let input_count = List.length tx.Tx.inputs in
	      let output_count = List.length tx.Tx.outputs in
	      vin_count := !vin_count + input_count;
	      vout_count := !vout_count + output_count;
	      timing.input_count_total <- timing.input_count_total + input_count;
	      List.iter (fun output -> incr_count output_script_types (classify_script output.Tx.script_pubkey)) tx.Tx.outputs;
	      if tx_index = 0 then (
		if height <> 0 then
		  List.iter
		    (fun utxo ->
		      Hashtbl.replace created (utxo_outpoint utxo) utxo;
		      timing.created_utxos <- timing.created_utxos + 1)
		    (output_utxos height tx txid_internal true))
	      else (
		if tx.inputs = [] then
		  raise (Connect_error (blocker ~height ~block_hash ~txid ~input:0 ~missing_rule:"transaction_without_inputs" ~failure:"non-coinbase transaction has no inputs"));
		let spent_prevouts = Array.make input_count { Script_verify.amount = 0L; script_pubkey = "" } in
		let input_utxos = Array.make (Array.length spent_prevouts) None in
		let input_keys = Hashtbl.create input_count in
		List.iteri
		  (fun input_index input ->
		    let key = spent_outpoint input in
		    if Hashtbl.mem input_keys key || Hashtbl.mem spent key then
		      raise (Connect_error (blocker ~height ~block_hash ~txid ~input:input_index ~missing_rule:"duplicate_spend" ~failure:"duplicate spend inside block"));
		    Hashtbl.add input_keys key true;
		    match find_utxo loaded created key with
		    | None ->
			raise (Connect_error (blocker ~height ~block_hash ~txid ~input:input_index ~missing_rule:"missing_utxo" ~failure:"OCaml connect could not find the spent prevout"))
		    | Some source ->
			let utxo = match source with `Created utxo | `Loaded utxo -> utxo in
			if utxo.coinbase && height - utxo.height < 100 then
			  raise (Connect_error (blocker ~height ~block_hash ~txid ~input:input_index ~missing_rule:"coinbase_maturity" ~failure:"coinbase spend before 100 confirmations"));
			spent_prevouts.(input_index) <- { Script_verify.amount = utxo.value_sats; script_pubkey = utxo.script_pubkey };
			incr script_input_count;
			input_utxos.(input_index) <- Some (key, utxo, source))
		  tx.inputs;
        let cache_started = now_ms () in
        let cache = Script_verify.create_sighash_cache_for_array tx spent_prevouts (sighash_needs_for_prevouts spent_prevouts) in
        timing.script_sighash_cache_build_ms <- timing.script_sighash_cache_build_ms + elapsed cache_started;
        script_jobs.(tx_index - 1) <- { job_tx_index = tx_index; job_spent_prevouts = spent_prevouts; job_cache = cache };
		Array.iter
		  (function
		    | None -> ()
		    | Some (key, utxo, source) ->
			(match source with
			| `Created _ ->
			    if Hashtbl.mem created key then (
			      Hashtbl.remove created key;
			      incr same_block_spends)
			| `Loaded _ ->
			    spent_external := (key, utxo) :: !spent_external;
			    undo_entries := (utxo.txid, utxo.vout, utxo.height, utxo.coinbase, utxo.value_sats, utxo.script_pubkey) :: !undo_entries);
			Hashtbl.replace spent key utxo)
		  input_utxos;
		List.iter
		  (fun utxo ->
		    Hashtbl.replace created (utxo_outpoint utxo) utxo;
		    timing.created_utxos <- timing.created_utxos + 1)
		  (output_utxos height tx txid_internal false)))
	    tx_array;
  let script_started = now_ms () in
  verify_script_jobs ?script_pool tx_array txids height block_hash script_jobs timing input_shape_counts spent_prevout_script_types;
  timing.script_verify_ms <- elapsed script_started;
  timing.script_wall_ms <- timing.script_verify_ms;
  if timing.script_runner_wait_ms = 0 then timing.script_runner_wait_ms <- timing.script_verify_ms;
	  let apply_started = now_ms () in
	  let external_spend_count = List.length !spent_external in
	  timing.spent_external <- external_spend_count;
	  timing.same_block_spends <- !same_block_spends;
	  let next_count = !utxo_count - external_spend_count + Hashtbl.length created in
	  utxo_count := next_count;
  timing.utxo_apply_ms <- elapsed apply_started;
  let commit_started = now_ms () in
  let prepare_ms = ref 0 in
  let rocksdb_write_ms =
    Rocks.write_batch_timed db ~disable_wal:false ~sync:false (fun batch ->
      let prepare_started = now_ms () in
      Rocks.batch_put batch (Codec_v2.height_key "h" chain height) (Codec_v2.header_value block.header.raw);
      Rocks.batch_put batch (Codec_v2.height_key "b" chain height)
        (Codec_v2.block_index_value ~hash:(Block.header_hash block.header) ~file_number ~file_offset ~block_size:(String.length raw));
      Rocks.batch_put batch (Codec_v2.height_key "d" chain height) (Codec_v2.undo_value !undo_entries);
      let spent_outpoints = !spent_external |> List.map fst |> Array.of_list in
      Rocks.batch_delete_utxos batch ~chain spent_outpoints;
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
      prepare_ms := elapsed prepare_started)
  in
  timing.writebatch_prepare_ms <- timing.writebatch_prepare_ms + !prepare_ms;
  timing.rocksdb_write_ms <- timing.rocksdb_write_ms + rocksdb_write_ms;
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
