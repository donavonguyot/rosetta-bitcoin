type db
type batch

external open_db : string -> bool -> db = "ocbitnode_rocks_open"
external close : db -> unit = "ocbitnode_rocks_close"
external put : db -> string -> string -> bool -> bool -> unit = "ocbitnode_rocks_put"
external get : db -> string -> string option = "ocbitnode_rocks_get"
external delete : db -> string -> bool -> bool -> unit = "ocbitnode_rocks_delete"
external batch_create : unit -> batch = "ocbitnode_rocks_batch_create"
external batch_put : batch -> string -> string -> unit = "ocbitnode_rocks_batch_put"
external batch_delete : batch -> string -> unit = "ocbitnode_rocks_batch_delete"
external batch_write : db -> batch -> bool -> bool -> unit = "ocbitnode_rocks_batch_write"
external iter_prefix : db -> string -> (string * string) list = "ocbitnode_rocks_iter_prefix"
external version : unit -> string = "ocbitnode_rocks_version"
external stats : db -> string = "ocbitnode_rocks_stats"

let with_db path fn =
  let db = open_db path true in
  Fun.protect ~finally:(fun () -> close db) (fun () -> fn db)

let write_batch db ?(disable_wal = false) ?(sync = true) fill =
  let batch = batch_create () in
  fill batch;
  batch_write db batch disable_wal sync

