type db
type batch

type outpoint = {
  txid : string;
  vout : int;
}

type utxo_row = {
  txid : string;
  vout : int;
  height : int;
  value_sats : int64;
  coinbase : bool;
  script_pubkey : string;
}

type utxo_load_stats = {
  lookup_count : int;
  key_bytes : int;
  value_bytes : int;
  multi_get_ms : int;
  decode_ms : int;
}

external open_db : string -> bool -> db = "ocbitnode_rocks_open"
external close : db -> unit = "ocbitnode_rocks_close"
external put : db -> string -> string -> bool -> bool -> unit = "ocbitnode_rocks_put"
external get : db -> string -> string option = "ocbitnode_rocks_get"
external multi_get_raw : db -> string array -> string option array = "ocbitnode_rocks_multi_get"
external multi_get_utxo_raw : db -> string -> outpoint array -> string option array * (int * int * int * int) = "ocbitnode_rocks_multi_get_utxo_raw"
external delete : db -> string -> bool -> bool -> unit = "ocbitnode_rocks_delete"
external batch_create : unit -> batch = "ocbitnode_rocks_batch_create"
external batch_put : batch -> string -> string -> unit = "ocbitnode_rocks_batch_put"
external batch_delete : batch -> string -> unit = "ocbitnode_rocks_batch_delete"
external utxo_key_raw : string -> outpoint -> string = "ocbitnode_rocks_utxo_key_raw"
external utxo_value_raw : utxo_row -> string = "ocbitnode_rocks_utxo_value_raw"
external batch_delete_utxos_raw : batch -> string -> outpoint array -> unit = "ocbitnode_rocks_batch_delete_utxos_raw"
external batch_put_utxos_raw : batch -> string -> utxo_row array -> unit = "ocbitnode_rocks_batch_put_utxos_raw"
external batch_write : db -> batch -> bool -> bool -> unit = "ocbitnode_rocks_batch_write"
external batch_write_timed : db -> batch -> bool -> bool -> int = "ocbitnode_rocks_batch_write_timed"
external iter_prefix : db -> string -> (string * string) list = "ocbitnode_rocks_iter_prefix"
external version : unit -> string = "ocbitnode_rocks_version"
external stats : db -> string = "ocbitnode_rocks_stats"

let tuning_mode =
  "create_if_missing=true,parallelism=4,block_cache_mb=512,bloom_bits_per_key=10,cache_index_filter_blocks=true,write_buffer_mb=128,max_write_buffer_number=6,max_background_jobs=4"

let with_db path fn =
  let db = open_db path true in
  Fun.protect ~finally:(fun () -> close db) (fun () -> fn db)

let multi_get db keys = multi_get_raw db (Array.of_list keys) |> Array.to_list

let now_ms () = int_of_float (Unix.gettimeofday () *. 1000.0)
let elapsed start = max 0 (now_ms () - start)

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

let multi_get_utxos db ~chain outpoints =
  let raw_values, (lookup_count, key_bytes, value_bytes, multi_get_ms) = multi_get_utxo_raw db chain outpoints in
  let decode_started = now_ms () in
  let rows =
    Array.mapi
      (fun index raw ->
        match raw with
        | None -> None
        | Some value ->
            let outpoint = outpoints.(index) in
            Some (decode_utxo_value outpoint.txid outpoint.vout value))
      raw_values
  in
  rows, { lookup_count; key_bytes; value_bytes; multi_get_ms; decode_ms = elapsed decode_started }

let utxo_key ~chain outpoint = utxo_key_raw chain outpoint
let utxo_value row = utxo_value_raw row
let batch_delete_utxos batch ~chain outpoints = batch_delete_utxos_raw batch chain outpoints
let batch_put_utxos batch ~chain rows = batch_put_utxos_raw batch chain rows

let write_batch db ?(disable_wal = false) ?(sync = true) fill =
  let batch = batch_create () in
  fill batch;
  batch_write db batch disable_wal sync

let write_batch_timed db ?(disable_wal = false) ?(sync = true) fill =
  let batch = batch_create () in
  fill batch;
  batch_write_timed db batch disable_wal sync
