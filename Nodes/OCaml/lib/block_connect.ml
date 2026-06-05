type timing_buckets = {
  utxo_load_ms : int;
  script_verify_ms : int;
  utxo_apply_ms : int;
  commit_ms : int;
  block_connect_store_commit_ms : int;
}

type connect_result = {
  block_hash : string;
  tx_count : int;
  timing : timing_buckets;
}

let now_ms () = int_of_float (Unix.gettimeofday () *. 1000.0)

let elapsed start_ms = max 0 (now_ms () - start_ms)

let connect_parsed_block_skeleton ~db block =
  let total_start = now_ms () in
  if not (Block.validate_merkle_root block) then failwith "block merkle root mismatch";
  if not (Block.proof_of_work_ok block.header) then failwith "block proof-of-work mismatch";
  let utxo_load_start = now_ms () in
  let utxo_load_ms = elapsed utxo_load_start in
  let script_start = now_ms () in
  let script_verify_ms = elapsed script_start in
  let apply_start = now_ms () in
  let block_hash = Block.header_hash_hex block.header in
  let utxo_apply_ms = elapsed apply_start in
  let commit_start = now_ms () in
  Rocks.write_batch db ~disable_wal:false ~sync:true (fun batch ->
      Rocks.batch_put batch (Codec_v2.metadata_key "block_connect_skeleton") "true";
      Rocks.batch_put batch (Codec_v2.metadata_key ("header:" ^ block_hash)) (Codec_v2.header_value block.header.raw);
      Rocks.batch_put batch (Codec_v2.tip_key "testnet4") (Codec_v2.tip_value ~height:0 ~hash:(Block.header_hash block.header)));
  let commit_ms = elapsed commit_start in
  {
    block_hash;
    tx_count = List.length block.Block.transactions;
    timing =
      {
        utxo_load_ms;
        script_verify_ms;
        utxo_apply_ms;
        commit_ms;
        block_connect_store_commit_ms = elapsed total_start;
      };
  }
