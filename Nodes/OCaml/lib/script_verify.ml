exception Script_error of string

type spent_prevout = {
  amount : int64;
  script_pubkey : string;
}

type verify_input_options = {
  script_pubkey : string;
  amount : int64;
  spent_prevouts : spent_prevout list;
}

type sighash_needs = {
  needs_legacy : bool;
  needs_bip143 : bool;
  needs_taproot : bool;
}

type script_timing = {
  mutable script_sighash_legacy_ms : int;
  mutable script_sighash_witness_ms : int;
  mutable script_sighash_taproot_ms : int;
  mutable script_ecdsa_verify_ms : int;
  mutable script_schnorr_verify_ms : int;
  mutable script_interpreter_eval_ms : int;
}

type sighash_cache = {
  tx : Tx.t;
  inputs : Tx.tx_in array;
  outputs : Tx.tx_out array;
  witness : string list array;
  spent_prevouts : spent_prevout list;
  spent_prevouts_array : spent_prevout array;
  has_legacy : bool;
  has_bip143 : bool;
  has_taproot : bool;
  legacy_empty_inputs_all : string array;
  legacy_empty_inputs_zero_sequence : string array;
  legacy_outputs_all : string;
  bip143_prevouts : string;
  bip143_sequence : string;
  bip143_outputs_all : string;
  bip143_single_outputs : string array;
  taproot_prevouts : string;
  taproot_amounts : string;
  taproot_script_pubkeys : string;
  taproot_sequences : string;
  taproot_outputs_all : string;
  taproot_single_outputs : string array;
}

let empty_timing () =
  {
    script_sighash_legacy_ms = 0;
    script_sighash_witness_ms = 0;
    script_sighash_taproot_ms = 0;
    script_ecdsa_verify_ms = 0;
    script_schnorr_verify_ms = 0;
    script_interpreter_eval_ms = 0;
  }

let add_timing into row =
  into.script_sighash_legacy_ms <- into.script_sighash_legacy_ms + row.script_sighash_legacy_ms;
  into.script_sighash_witness_ms <- into.script_sighash_witness_ms + row.script_sighash_witness_ms;
  into.script_sighash_taproot_ms <- into.script_sighash_taproot_ms + row.script_sighash_taproot_ms;
  into.script_ecdsa_verify_ms <- into.script_ecdsa_verify_ms + row.script_ecdsa_verify_ms;
  into.script_schnorr_verify_ms <- into.script_schnorr_verify_ms + row.script_schnorr_verify_ms;
  into.script_interpreter_eval_ms <- into.script_interpreter_eval_ms + row.script_interpreter_eval_ms

let now_ms () = int_of_float (Unix.gettimeofday () *. 1000.0)

let measure add fn =
  let started = now_ms () in
  Fun.protect
    ~finally:(fun () -> add (max 0 (now_ms () - started)))
    fn

let err msg = raise (Script_error msg)
let ensure condition msg = if not condition then err msg

let op_0 = 0x00
let op_pushdata1 = 0x4c
let op_pushdata2 = 0x4d
let op_pushdata4 = 0x4e
let op_1negate = 0x4f
let op_1 = 0x51
let op_16 = 0x60
let op_nop = 0x61
let op_if = 0x63
let op_notif = 0x64
let op_else = 0x67
let op_endif = 0x68
let op_verify = 0x69
let op_toaltstack = 0x6b
let op_fromaltstack = 0x6c
let op_2drop = 0x6d
let op_2dup = 0x6e
let op_3dup = 0x6f
let op_2over = 0x70
let op_2swap = 0x72
let op_ifdup = 0x73
let op_depth = 0x74
let op_drop = 0x75
let op_dup = 0x76
let op_nip = 0x77
let op_over = 0x78
let op_pick = 0x79
let op_roll = 0x7a
let op_rot = 0x7b
let op_swap = 0x7c
let op_tuck = 0x7d
let op_size = 0x82
let op_equal = 0x87
let op_equalverify = 0x88
let op_1sub = 0x8c
let op_negate = 0x8f
let op_abs = 0x90
let op_not = 0x91
let op_0notequal = 0x92
let op_add = 0x93
let op_sub = 0x94
let op_mul = 0x95
let op_booland = 0x9a
let op_boolor = 0x9b
let op_numequal = 0x9c
let op_numequalverify = 0x9d
let op_numnotequal = 0x9e
let op_lessthan = 0x9f
let op_greaterthan = 0xa0
let op_lessthanorequal = 0xa1
let op_greaterthanorequal = 0xa2
let op_min = 0xa3
let op_max = 0xa4
let op_within = 0xa5
let op_ripemd160 = 0xa6
let op_sha1 = 0xa7
let op_sha256 = 0xa8
let op_hash160 = 0xa9
let op_hash256 = 0xaa
let op_codeseparator = 0xab
let op_checksig = 0xac
let op_checksigverify = 0xad
let op_checkmultisig = 0xae
let op_checkmultisigverify = 0xaf
let op_checklocktimeverify = 0xb1
let op_checksequenceverify = 0xb2
let op_checksigadd = 0xba

let taproot_leaf_tapscript = 0xc0
let sequence_disable_flag = 1 lsl 31
let sequence_type_flag = 1 lsl 22
let sequence_locktime_mask = 0x0000ffff
let locktime_threshold = 500_000_000l
let max_consensus_script_size = 10_000
let max_tapscript_stack_items = 1000
let max_script_element_size = 520
let tap_validation_offset = 50
let tap_validation_per_sigop = 50
let taproot_sighash_default = 0
let taproot_sighash_all = 1
let taproot_sighash_single = 3

module Stack = struct
  type t = {
    mutable items : string array;
    mutable size : int;
  }

  let create () = { items = Array.make 16 ""; size = 0 }

  let grow t =
    let next = Array.make (max 1 (Array.length t.items * 2)) "" in
    Array.blit t.items 0 next 0 t.size;
    t.items <- next

  let push t item =
    if t.size = Array.length t.items then grow t;
    t.items.(t.size) <- item;
    t.size <- t.size + 1

  let pop t =
    if t.size = 0 then err "stack underflow";
    t.size <- t.size - 1;
    let item = t.items.(t.size) in
    t.items.(t.size) <- "";
    item

  let peek t =
    if t.size = 0 then err "stack underflow";
    t.items.(t.size - 1)

  let size t = t.size

  let item_from_top t n =
    ensure (n > 0 && n <= size t) "stack underflow";
    t.items.(t.size - n)

  let snapshot t =
    let rows = ref [] in
    for i = t.size - 1 downto 0 do
      rows := t.items.(i) :: !rows
    done;
    !rows

  let push_all t items = List.iter (push t) items

  let roll_from_top t depth =
    ensure (depth < size t) "OP_ROLL out of range";
    let source = t.size - 1 - depth in
    let item = t.items.(source) in
    for i = source to t.size - 2 do
      t.items.(i) <- t.items.(i + 1)
    done;
    t.items.(t.size - 1) <- item
end

type eval_context = {
  tx : Tx.t;
  input_index : int;
  script_code : string;
  code_separator_offset : int;
  amount : int64;
  witness : bool;
  cache : sighash_cache option;
  timing : script_timing option;
  verifier : Crypto.verifier option;
}

let effective_script_code context =
  if context.code_separator_offset = 0 then context.script_code
  else String.sub context.script_code context.code_separator_offset (String.length context.script_code - context.code_separator_offset)

let with_code_separator_after context offset = { context with code_separator_offset = offset }

let byte = Tx.byte
let sub = Tx.sub

let sha256_bytes = Util.sha256_raw
let double_sha = Tx.double_sha
let sha1 data = Digestif.SHA1.(to_raw_string (digest_string data))
let ripemd160 data = Digestif.RMD160.(to_raw_string (digest_string data))
let hash160 data = ripemd160 (sha256_bytes data)
let tagged_hash tag data = Crypto.tagged_sha256 ~tag ~msg:data

let is_push_opcode op = (op >= 1 && op <= 75) || op = op_pushdata1 || op = op_pushdata2 || op = op_pushdata4

let read_push script offset =
  ensure (offset < String.length script) "push offset out of range";
  let op = byte script offset in
  let cursor = ref (offset + 1) in
  let length =
    if op >= 1 && op <= 75 then op
    else if op = op_pushdata1 then (
      ensure (!cursor < String.length script) "truncated pushdata1";
      let len = byte script !cursor in
      incr cursor;
      len)
    else if op = op_pushdata2 then (
      ensure (!cursor + 2 <= String.length script) "truncated pushdata2";
      let len = Tx.le16 script !cursor in
      cursor := !cursor + 2;
      len)
    else if op = op_pushdata4 then (
      ensure (!cursor + 4 <= String.length script) "truncated pushdata4";
      let len = Int32.to_int (Tx.le32 script !cursor) in
      cursor := !cursor + 4;
      len)
    else err (Printf.sprintf "invalid push opcode 0x%x" op)
  in
  ensure (!cursor + length <= String.length script) "push exceeds script length";
  sub script !cursor length, !cursor + length

let legacy_find_and_delete script target =
  let output = Buffer.create (String.length script) in
  let offset = ref 0 in
  while !offset < String.length script do
    let start = !offset in
    let op = byte script !offset in
    incr offset;
    let item =
      if op = op_0 then Some ""
      else if op >= op_1 && op <= op_16 then Some (String.make 1 (Char.chr (op - op_1 + 1)))
      else if op = op_1negate then Some "\x81"
      else if is_push_opcode op then (
        offset := start;
        try
          let pushed, next = read_push script start in
          offset := next;
          Some pushed
        with Script_error _ ->
          Buffer.add_substring output script start (String.length script - start);
          offset := String.length script;
          None)
      else (
        Buffer.add_substring output script start (!offset - start);
        None)
    in
    match item with
    | Some item when item <> target -> Buffer.add_substring output script start (!offset - start)
    | Some _ | None -> ()
  done;
  Buffer.contents output

let advance_opcode script offset =
  let op = byte script offset in
  if op = op_0 || (op >= op_1 && op <= op_16) || op = op_1negate then offset + 1
  else if op >= 1 && op <= 75 then offset + 1 + op
  else if op = op_pushdata1 || op = op_pushdata2 || op = op_pushdata4 then snd (read_push script offset)
  else offset + 1

let encode_op_n value =
  if value = 0 then ""
  else (
    ensure (value >= 1 && value <= 16) "cannot encode op_n";
    String.make 1 (Char.chr value))

let cast_to_bool item =
  let result = ref false in
  for i = 0 to String.length item - 1 do
    let b = byte item i in
    if b <> 0 && not (i = String.length item - 1 && b = 0x80) then result := true
  done;
  !result

let decode_script_num item max_len =
  ensure (String.length item <= max_len) "script number overflow";
  if item = "" then 0L
  else
    let negative = (byte item (String.length item - 1) land 0x80) <> 0 in
    let value = ref 0L in
    for i = 0 to String.length item - 1 do
      let b = if negative && i = String.length item - 1 then byte item i land 0x7f else byte item i in
      value := Int64.logor !value (Int64.shift_left (Int64.of_int b) (8 * i))
    done;
    if negative then Int64.neg !value else !value

let encode_script_num value max_len =
  if value = 0L then ""
  else
    let negative = value < 0L in
    let abs_value = ref (if negative then Int64.neg value else value) in
    let bytes = ref [] in
    while !abs_value > 0L do
      bytes := Char.chr (Int64.to_int (Int64.logand !abs_value 0xffL)) :: !bytes;
      abs_value := Int64.shift_right_logical !abs_value 8
    done;
    let raw = Bytes.of_string (String.of_seq (List.to_seq (List.rev !bytes))) in
    let raw =
      if Char.code (Bytes.get raw (Bytes.length raw - 1)) land 0x80 <> 0 then Bytes.cat raw (Bytes.make 1 '\000')
      else raw
    in
    if negative then
      Bytes.set raw (Bytes.length raw - 1) (Char.chr (Char.code (Bytes.get raw (Bytes.length raw - 1)) lor 0x80));
    ensure (Bytes.length raw <= max_len) "script number overflow";
    Bytes.unsafe_to_string raw

let parse_push_only script_sig =
  let rec loop offset acc =
    if offset >= String.length script_sig then List.rev acc
    else
      let op = byte script_sig offset in
      if op = op_0 then loop (offset + 1) ("" :: acc)
      else if op >= op_1 && op <= op_16 then loop (offset + 1) (encode_op_n (op - op_1 + 1) :: acc)
      else if op = op_1negate then loop (offset + 1) ("\x81" :: acc)
      else if is_push_opcode op then
        let item, next = read_push script_sig offset in
        loop next (item :: acc)
      else err "non-push opcode in scriptSig"
  in
  loop 0 []

let terminal_strict stack = Stack.size stack = 1 && cast_to_bool (Stack.peek stack)
let terminal_relaxed stack = Stack.size stack > 0 && cast_to_bool (Stack.peek stack)
let all_true rows = List.for_all (fun value -> value) rows

let is_p2pkh script =
  String.length script = 25
  && byte script 0 = op_dup
  && byte script 1 = op_hash160
  && byte script 2 = 0x14
  && byte script 23 = op_equalverify
  && byte script 24 = op_checksig

let is_p2pk script =
  (String.length script = 35 && byte script 0 = 33 && byte script 34 = op_checksig)
  || (String.length script = 67 && byte script 0 = 65 && byte script 66 = op_checksig)

let is_p2wpkh script = String.length script = 22 && byte script 0 = 0 && byte script 1 = 0x14
let is_p2wsh script = String.length script = 34 && byte script 0 = 0 && byte script 1 = 0x20
let is_p2sh script = String.length script = 23 && byte script 0 = op_hash160 && byte script 1 = 0x14 && byte script 22 = op_equal
let is_p2tr script = String.length script = 34 && byte script 0 = op_1 && byte script 1 = 0x20

let p2pkh_script_code pubkey_hash =
  String.make 1 (Char.chr op_dup) ^ String.make 1 (Char.chr op_hash160) ^ String.make 1 (Char.chr (String.length pubkey_hash))
  ^ pubkey_hash ^ String.make 1 (Char.chr op_equalverify) ^ String.make 1 (Char.chr op_checksig)

let witness_version script =
  if String.length script < 4 then None
  else
    let version =
      if byte script 0 = op_0 then Some 0
      else if byte script 0 >= op_1 && byte script 0 <= op_16 then Some (byte script 0 - op_1 + 1)
      else None
    in
    match version with
    | None -> None
    | Some version ->
        let item, next = read_push script 1 in
        if String.length item >= 2 && String.length item <= 40 && next = String.length script then Some version else None

let is_bare_op_n script =
  if script = "" then false
  else
    let op = byte script 0 in
    if not ((op >= op_1 && op <= op_16) || op = op_1negate) then false
    else if String.length script = 1 then true
    else if is_p2tr script || is_p2wpkh script || is_p2wsh script then false
    else
      try snd (read_push script 1) = String.length script with Script_error _ -> false

let is_ecdsa_pubkey item =
  (String.length item = 33 && (byte item 0 = 2 || byte item 0 = 3)) || (String.length item = 65 && byte item 0 = 4)

let is_bare_multisig script =
  if String.length script < 4 || byte script 0 < op_1 || byte script 0 > op_16 then false
  else
    let required = byte script 0 - op_1 + 1 in
    let offset = ref 1 in
    let pubkeys = ref 0 in
    let valid = ref true in
    while !valid && !offset < String.length script && not (byte script !offset >= op_1 && byte script !offset <= op_16) do
      try
        let item, next = read_push script !offset in
        if not (is_ecdsa_pubkey item) then valid := false
        else (
          offset := next;
          incr pubkeys;
          if !pubkeys > 20 then valid := false)
      with Script_error _ -> valid := false
    done;
    if (not !valid) || !pubkeys = 0 || !pubkeys < required || !offset >= String.length script then false
    else
      let n_op = byte script !offset in
      let n = n_op - op_1 + 1 in
      incr offset;
      n_op >= op_1 && n_op <= op_16 && n = !pubkeys && !offset < String.length script && byte script !offset = op_checkmultisig && !offset + 1 = String.length script

let is_bare_legacy_script script =
  script <> ""
  && String.length script <= max_consensus_script_size
  && witness_version script = None
  && not (String.length script <= 83 && byte script 0 = 0x6a)
  && not (is_p2pk script || is_p2pkh script || is_p2wpkh script || is_p2wsh script || is_p2sh script || is_p2tr script || is_bare_op_n script || is_bare_multisig script)

let cache_matches (cache : sighash_cache option) transaction =
  match cache with
  | Some cache when cache.tx == transaction -> Some cache
  | _ -> None

let input_count ?cache transaction =
  match cache_matches cache transaction with
  | Some cache -> Array.length cache.inputs
  | None -> List.length transaction.Tx.inputs

let output_count ?cache transaction =
  match cache_matches cache transaction with
  | Some cache -> Array.length cache.outputs
  | None -> List.length transaction.Tx.outputs

let input_at ?cache transaction index =
  match cache_matches cache transaction with
  | Some cache -> cache.inputs.(index)
  | None -> List.nth transaction.Tx.inputs index

let output_at ?cache transaction index =
  match cache_matches cache transaction with
  | Some cache -> cache.outputs.(index)
  | None -> List.nth transaction.Tx.outputs index

let spent_prevout_at ?cache spent_prevouts transaction index =
  match cache_matches cache transaction with
  | Some cache -> cache.spent_prevouts_array.(index)
  | None -> List.nth spent_prevouts index

let legacy_input input script_code base_type signing =
  let buf = Buffer.create 128 in
  Buffer.add_string buf (Tx.serialize_outpoint input.Tx.previous_output);
  if signing then (
    Buffer.add_string buf (Tx.compact_size (String.length script_code));
    Buffer.add_string buf script_code)
  else Buffer.add_char buf '\000';
  if base_type = 1 || signing then Tx.put_u32 buf input.sequence else Tx.put_u32 buf 0l;
  Buffer.contents buf

let legacy_empty_input input sequence =
  let buf = Buffer.create 41 in
  Buffer.add_string buf (Tx.serialize_outpoint input.Tx.previous_output);
  Buffer.add_char buf '\000';
  Tx.put_u32 buf sequence;
  Buffer.contents buf

let legacy_outputs_all transaction =
  let buf = Buffer.create 256 in
  Buffer.add_string buf (Tx.compact_size (List.length transaction.Tx.outputs));
  List.iter (fun output -> Buffer.add_string buf (Tx.serialize_txout output)) transaction.outputs;
  Buffer.contents buf

(* Legacy pre-segwit sighash; consensus byte-shape must match Shared script fixtures. *)
let legacy_sighash ?cache transaction input_index script_code sighash_type =
  ensure (input_index < input_count ?cache transaction) "input index out of range";
  let base_type = sighash_type land 0x1f in
  let anyone_can_pay = sighash_type land 0x80 <> 0 in
  if base_type = 3 && input_index >= output_count ?cache transaction then "\001" ^ String.make 31 '\000'
  else
    let buf = Buffer.create 512 in
    Tx.put_u32 buf transaction.version;
    if anyone_can_pay then (
      Buffer.add_string buf (Tx.compact_size 1);
      Buffer.add_string buf (legacy_input (input_at ?cache transaction input_index) script_code base_type true))
    else (
      Buffer.add_string buf (Tx.compact_size (input_count ?cache transaction));
      match cache_matches cache transaction with
      | Some cache when cache.has_legacy ->
          let empty_inputs = if base_type = 1 then cache.legacy_empty_inputs_all else cache.legacy_empty_inputs_zero_sequence in
          Array.iteri
            (fun index input ->
              if index = input_index then Buffer.add_string buf (legacy_input input script_code base_type true)
              else Buffer.add_string buf empty_inputs.(index))
            cache.inputs
      | Some _ | None ->
          List.iteri
            (fun index input -> Buffer.add_string buf (legacy_input input script_code base_type (index = input_index)))
            transaction.inputs);
    if base_type = 2 then Buffer.add_char buf '\000'
    else if base_type = 3 then (
      Buffer.add_string buf (Tx.compact_size (input_index + 1));
      for _ = 0 to input_index - 1 do Buffer.add_string buf (Tx.serialize_txout { value = -1L; script_pubkey = "" }) done;
      Buffer.add_string buf (Tx.serialize_txout (output_at ?cache transaction input_index)))
    else (
      match cache_matches cache transaction with
      | Some cache when cache.has_legacy -> Buffer.add_string buf cache.legacy_outputs_all
      | Some _ | None -> Buffer.add_string buf (legacy_outputs_all transaction));
    Tx.put_u32 buf transaction.lock_time;
    Tx.put_u32 buf (Int32.of_int sighash_type);
    double_sha (Buffer.contents buf)

(* BIP143 witness sighash; amount and script_code come from spent prevout runtime truth. *)
let bip143_sighash ?cache transaction input_index script_code amount sighash_type =
  ensure (input_index < input_count ?cache transaction) "input index out of range";
  let anyone_can_pay = sighash_type land 0x80 <> 0 in
  let base_type = sighash_type land 0x1f in
  let zero = String.make 32 '\000' in
  let hash_prevouts =
    if anyone_can_pay then zero
    else match cache with
      | Some (cache : sighash_cache) when cache.tx == transaction && cache.has_bip143 -> cache.bip143_prevouts
      | _ ->
      let b = Buffer.create 128 in
      List.iter (fun input -> Buffer.add_string b (Tx.serialize_outpoint input.Tx.previous_output)) transaction.inputs;
      double_sha (Buffer.contents b)
  in
  let hash_sequence =
    if anyone_can_pay || base_type = 2 || base_type = 3 then zero
    else match cache with
      | Some (cache : sighash_cache) when cache.tx == transaction && cache.has_bip143 -> cache.bip143_sequence
      | _ ->
      let b = Buffer.create 64 in
      List.iter (fun input -> Tx.put_u32 b input.Tx.sequence) transaction.inputs;
      double_sha (Buffer.contents b)
  in
  let hash_outputs =
    if base_type = 3 then (
      if input_index < output_count ?cache transaction then
        match cache_matches cache transaction with
        | Some cache when cache.has_bip143 -> cache.bip143_single_outputs.(input_index)
        | Some _ | None -> double_sha (Tx.serialize_txout (output_at ?cache transaction input_index))
      else zero)
    else if base_type = 2 then zero
    else match cache with
      | Some (cache : sighash_cache) when cache.tx == transaction && cache.has_bip143 -> cache.bip143_outputs_all
      | _ ->
      let b = Buffer.create 256 in
      List.iter (fun output -> Buffer.add_string b (Tx.serialize_txout output)) transaction.outputs;
      double_sha (Buffer.contents b)
  in
  let input = input_at ?cache transaction input_index in
  let buf = Buffer.create 512 in
  Tx.put_u32 buf transaction.version;
  Buffer.add_string buf hash_prevouts;
  Buffer.add_string buf hash_sequence;
  Buffer.add_string buf (Tx.serialize_outpoint input.previous_output);
  Buffer.add_string buf (Tx.compact_size (String.length script_code));
  Buffer.add_string buf script_code;
  Tx.put_i64 buf amount;
  Tx.put_u32 buf input.sequence;
  Buffer.add_string buf hash_outputs;
  Tx.put_u32 buf transaction.lock_time;
  Tx.put_u32 buf (Int32.of_int sighash_type);
  double_sha (Buffer.contents buf)

let verify_ecdsa ?verifier pubkey digest sig_der =
  match verifier with
  | Some verifier -> Crypto.ecdsa_verify_bytes_with_verifier ~verifier ~pubkey ~msg_hash:digest ~signature_der:sig_der
  | None -> Crypto.ecdsa_verify_bytes ~pubkey ~msg_hash:digest ~signature_der:sig_der

let verify_schnorr ?verifier pubkey_xonly digest sig64 =
  match verifier with
  | Some verifier -> Crypto.schnorr_verify_bytes_with_verifier ~verifier ~xonly_pubkey:pubkey_xonly ~msg_hash:digest ~signature:sig64
  | None -> Crypto.schnorr_verify_bytes ~xonly_pubkey:pubkey_xonly ~msg_hash:digest ~signature:sig64

let debug_tapscript_signature_failure input_index hash_type pubkey digest sig64 leaf =
  match Sys.getenv_opt "OCBITNODE_DEBUG_TAPSCRIPT_SIG" with
  | Some "1" | Some "true" ->
      prerr_endline
        (Yojson.Safe.to_string
           (`Assoc [
             "event", `String "ocbitnode.tapscript_signature_failed";
             "input_index", `Int input_index;
             "hash_type", `Int hash_type;
             "pubkey", `String (Util.hex_of_bytes pubkey);
             "digest", `String (Util.hex_of_bytes digest);
             "signature", `String (Util.hex_of_bytes sig64);
             "tapleaf_hash", `String (Util.hex_of_bytes leaf);
           ]))
  | _ -> ()

let debug_tapscript_final_stack input_index stack =
  match Sys.getenv_opt "OCBITNODE_DEBUG_TAPSCRIPT_SIG" with
  | Some "1" | Some "true" ->
      prerr_endline
        (Yojson.Safe.to_string
           (`Assoc [
             "event", `String "ocbitnode.tapscript_final_stack";
             "input_index", `Int input_index;
             "stack_size", `Int (Stack.size stack);
             "stack", `List (List.map (fun item -> `String (Util.hex_of_bytes item)) (Stack.snapshot stack));
           ]))
  | _ -> ()

let check_ecdsa_signature context signature pubkey =
  if signature = "" then false
  else
    let sighash_type = byte signature (String.length signature - 1) in
    let sig_der = sub signature 0 (String.length signature - 1) in
    let script_code =
      if context.witness then effective_script_code context
      else legacy_find_and_delete (effective_script_code context) signature
    in
    let digest =
      try
        Some
          (if context.witness then
             measure
               (fun ms -> Option.iter (fun timing -> timing.script_sighash_witness_ms <- timing.script_sighash_witness_ms + ms) context.timing)
               (fun () -> bip143_sighash ?cache:context.cache context.tx context.input_index script_code context.amount sighash_type)
           else
             measure
               (fun ms -> Option.iter (fun timing -> timing.script_sighash_legacy_ms <- timing.script_sighash_legacy_ms + ms) context.timing)
               (fun () -> legacy_sighash ?cache:context.cache context.tx context.input_index script_code sighash_type))
      with Script_error _ -> None
    in
    let primary =
      match digest with
      | Some digest ->
          measure
            (fun ms -> Option.iter (fun timing -> timing.script_ecdsa_verify_ms <- timing.script_ecdsa_verify_ms + ms) context.timing)
            (fun () -> verify_ecdsa ?verifier:context.verifier pubkey digest sig_der)
      | None -> false
    in
    primary

let int_of_script_num item max_len = Int64.to_int (decode_script_num item max_len)

let check_lock_time_verify stack transaction =
  if transaction.Tx.version < 2l then ()
  else (
    ensure (transaction.lock_time <> 0l) "CHECKLOCKTIMEVERIFY on final tx";
    ensure (List.exists (fun input -> input.Tx.sequence <> Int32.minus_one) transaction.inputs) "CHECKLOCKTIMEVERIFY on final tx";
    let locktime = decode_script_num (Stack.peek stack) 5 in
    ensure (locktime >= 0L) "negative locktime";
    let lock32 = Int32.of_int (Int64.to_int locktime) in
    ensure ((lock32 < locktime_threshold) = (transaction.lock_time < locktime_threshold)) "locktime type mismatch";
    ensure (lock32 <= transaction.lock_time) "locktime unsatisfied")

let check_sequence_verify stack transaction input_index =
  if transaction.Tx.version < 2l then ()
  else
    let required = int_of_script_num (Stack.peek stack) 5 in
    ensure (required >= 0) "negative sequence";
    if required land sequence_disable_flag <> 0 then ()
    else
      let sequence = Int32.to_int (List.nth transaction.inputs input_index).Tx.sequence in
      ensure (sequence <> Int32.to_int Int32.minus_one) "final sequence";
      ensure (sequence land sequence_disable_flag = 0) "disabled sequence";
      ensure (required land sequence_type_flag = sequence land sequence_type_flag) "sequence type mismatch";
      ensure (required land sequence_locktime_mask <= sequence land sequence_locktime_mask) "sequence unsatisfied"

let eval_numeric opcode stack =
  if opcode = op_within then (
    let maxv = decode_script_num (Stack.pop stack) 4 in
    let minv = decode_script_num (Stack.pop stack) 4 in
    let value = decode_script_num (Stack.pop stack) 4 in
    Stack.push stack (encode_op_n (if minv <= value && value < maxv then 1 else 0)))
  else if opcode = op_booland || opcode = op_boolor then (
    let b = cast_to_bool (Stack.pop stack) in
    let a = cast_to_bool (Stack.pop stack) in
    let v = (opcode = op_booland && a && b) || (opcode = op_boolor && (a || b)) in
    Stack.push stack (encode_op_n (if v then 1 else 0)))
  else
    let b = decode_script_num (Stack.pop stack) 4 in
    let a = decode_script_num (Stack.pop stack) 4 in
    match opcode with
    | x when x = op_add -> Stack.push stack (encode_script_num Int64.(add a b) 4)
    | x when x = op_sub -> Stack.push stack (encode_script_num Int64.(sub a b) 4)
    | x when x = op_mul -> Stack.push stack (encode_script_num Int64.(mul a b) 4)
    | x when x = op_min -> Stack.push stack (encode_script_num (if a <= b then a else b) 4)
    | x when x = op_max -> Stack.push stack (encode_script_num (if a >= b then a else b) 4)
    | x when x = op_lessthan -> Stack.push stack (encode_op_n (if a < b then 1 else 0))
    | x when x = op_greaterthan -> Stack.push stack (encode_op_n (if a > b then 1 else 0))
    | x when x = op_lessthanorequal -> Stack.push stack (encode_op_n (if a <= b then 1 else 0))
    | x when x = op_greaterthanorequal -> Stack.push stack (encode_op_n (if a >= b then 1 else 0))
    | x when x = op_numequal -> Stack.push stack (encode_op_n (if a = b then 1 else 0))
    | x when x = op_numnotequal -> Stack.push stack (encode_op_n (if a <> b then 1 else 0))
    | x when x = op_numequalverify -> ensure (a = b) "NUMEQUALVERIFY failed"
    | _ -> err (Printf.sprintf "unsupported numeric opcode 0x%x" opcode)

let check_multisig stack context =
  let index = ref 1 in
  let key_count = int_of_script_num (Stack.item_from_top stack !index) 4 in
  ensure (key_count >= 0 && key_count <= 20) "pubkey count out of range";
  let key_start = !index + 1 in
  index := key_start + key_count;
  let sig_count = int_of_script_num (Stack.item_from_top stack !index) 4 in
  ensure (sig_count >= 0 && sig_count <= key_count) "signature count out of range";
  let sig_start = !index + 1 in
  index := sig_start + sig_count;
  ensure (Stack.size stack >= !index) "CHECKMULTISIG stack underflow";
  let success = ref true in
  let sig_offset = ref 0 in
  let key_offset = ref 0 in
  let remaining_sigs = ref sig_count in
  let remaining_keys = ref key_count in
  let check_context =
    if context.witness then context
    else
      let script_code =
        List.init sig_count (fun offset -> Stack.item_from_top stack (sig_start + offset))
        |> List.fold_left legacy_find_and_delete (effective_script_code context)
      in
      { context with script_code; code_separator_offset = 0 }
  in
  while !success && !remaining_sigs > 0 do
    let signature = Stack.item_from_top stack (sig_start + !sig_offset) in
    let pubkey = Stack.item_from_top stack (key_start + !key_offset) in
    if check_ecdsa_signature check_context signature pubkey then (
      incr sig_offset;
      decr remaining_sigs);
    incr key_offset;
    decr remaining_keys;
    if !remaining_sigs > !remaining_keys then success := false
  done;
  while !index > 1 do
    ignore (Stack.pop stack);
    decr index
  done;
  ensure (Stack.size stack <> 0) "CHECKMULTISIG missing dummy";
  ignore (Stack.pop stack);
  !success

let eval_opcode opcode stack alt context _tapscript instr_at =
  match opcode with
  | x when x = op_drop -> ignore (Stack.pop stack); context
  | x when x = op_2drop -> ignore (Stack.pop stack); ignore (Stack.pop stack); context
  | x when x = op_toaltstack -> Stack.push alt (Stack.pop stack); context
  | x when x = op_fromaltstack -> Stack.push stack (Stack.pop alt); context
  | x when x = op_2dup ->
      let x2 = Stack.pop stack in
      let x1 = Stack.pop stack in
      List.iter (Stack.push stack) [ x1; x2; x1; x2 ];
      context
  | x when x = op_3dup ->
      let x3 = Stack.pop stack in
      let x2 = Stack.pop stack in
      let x1 = Stack.pop stack in
      List.iter (Stack.push stack) [ x1; x2; x3; x1; x2; x3 ];
      context
  | x when x = op_2over ->
      ensure (Stack.size stack >= 4) "OP_2OVER underflow";
      let a = Stack.item_from_top stack 4 in
      let b = Stack.item_from_top stack 4 in
      Stack.push stack a;
      Stack.push stack b;
      context
  | x when x = op_2swap ->
      let x4 = Stack.pop stack in
      let x3 = Stack.pop stack in
      let x2 = Stack.pop stack in
      let x1 = Stack.pop stack in
      List.iter (Stack.push stack) [ x3; x4; x1; x2 ];
      context
  | x when x = op_depth -> Stack.push stack (encode_script_num (Int64.of_int (Stack.size stack)) 4); context
  | x when x = op_pick ->
      let depth = int_of_script_num (Stack.pop stack) 4 in
      ensure (depth >= 0 && depth < Stack.size stack) "OP_PICK out of range";
      Stack.push stack (Stack.item_from_top stack (depth + 1));
      context
  | x when x = op_roll ->
      let depth = int_of_script_num (Stack.pop stack) 4 in
      Stack.roll_from_top stack depth;
      context
  | x when x = op_dup -> Stack.push stack (Stack.peek stack); context
  | x when x = op_ifdup -> if cast_to_bool (Stack.peek stack) then Stack.push stack (Stack.peek stack); context
  | x when x = op_nip ->
      let top = Stack.pop stack in
      ignore (Stack.pop stack);
      Stack.push stack top;
      context
  | x when x = op_over -> Stack.push stack (Stack.item_from_top stack 2); context
  | x when x = op_rot ->
      let x3 = Stack.pop stack in
      let x2 = Stack.pop stack in
      let x1 = Stack.pop stack in
      List.iter (Stack.push stack) [ x2; x3; x1 ];
      context
  | x when x = op_swap ->
      let a = Stack.pop stack in
      let b = Stack.pop stack in
      Stack.push stack a;
      Stack.push stack b;
      context
  | x when x = op_tuck ->
      let top = Stack.pop stack in
      let second = Stack.pop stack in
      List.iter (Stack.push stack) [ top; second; top ];
      context
  | x when x = op_size -> Stack.push stack (encode_script_num (Int64.of_int (String.length (Stack.peek stack))) 4); context
  | x when x = op_sha1 -> Stack.push stack (sha1 (Stack.pop stack)); context
  | x when x = op_sha256 -> Stack.push stack (sha256_bytes (Stack.pop stack)); context
  | x when x = op_hash256 -> Stack.push stack (double_sha (Stack.pop stack)); context
  | x when x = op_ripemd160 -> Stack.push stack (ripemd160 (Stack.pop stack)); context
  | x when x = op_hash160 -> Stack.push stack (hash160 (Stack.pop stack)); context
  | x when x = op_equal ->
      let b = Stack.pop stack in
      let a = Stack.pop stack in
      Stack.push stack (encode_op_n (if a = b then 1 else 0));
      context
  | x when x = op_equalverify ->
      let b = Stack.pop stack in
      let a = Stack.pop stack in
      ensure (a = b) "EQUALVERIFY failed";
      context
  | x when x = op_verify -> ensure (cast_to_bool (Stack.pop stack)) "VERIFY failed"; context
  | x
    when x = op_add || x = op_sub || x = op_mul || x = op_min || x = op_max || x = op_lessthan || x = op_greaterthan
         || x = op_lessthanorequal || x = op_greaterthanorequal || x = op_within || x = op_booland || x = op_boolor
         || x = op_numequal || x = op_numnotequal || x = op_numequalverify ->
      eval_numeric opcode stack;
      context
  | x when x = op_1sub ->
      let v = Int64.sub (decode_script_num (Stack.pop stack) 4) 1L in
      Stack.push stack (encode_script_num v 4);
      context
  | x when x = op_negate ->
      Stack.push stack (encode_script_num (Int64.neg (decode_script_num (Stack.pop stack) 4)) 4);
      context
  | x when x = op_abs ->
      let v = decode_script_num (Stack.pop stack) 4 in
      Stack.push stack (encode_script_num (if v < 0L then Int64.neg v else v) 4);
      context
  | x when x = op_not -> Stack.push stack (encode_op_n (if not (cast_to_bool (Stack.pop stack)) then 1 else 0)); context
  | x when x = op_0notequal -> Stack.push stack (encode_op_n (if cast_to_bool (Stack.pop stack) then 1 else 0)); context
  | x when x = op_codeseparator -> with_code_separator_after context (instr_at + 1)
  | x when x = op_nop -> context
  | x when x = op_checksig || x = op_checksigverify ->
      let pubkey = Stack.pop stack in
      let signature = Stack.pop stack in
      let valid = check_ecdsa_signature context signature pubkey in
      if x = op_checksig then Stack.push stack (encode_op_n (if valid then 1 else 0)) else ensure valid "CHECKSIGVERIFY failed";
      context
  | x when x = op_checkmultisig || x = op_checkmultisigverify ->
      let valid = check_multisig stack context in
      if x = op_checkmultisig then Stack.push stack (encode_op_n (if valid then 1 else 0)) else ensure valid "CHECKMULTISIGVERIFY failed";
      context
  | x when x = op_checklocktimeverify -> check_lock_time_verify stack context.tx; context
  | x when x = op_checksequenceverify -> check_sequence_verify stack context.tx context.input_index; context
  | _ -> err (Printf.sprintf "unsupported opcode 0x%x" opcode)

let evaluate_script script stack context =
  let offset = ref 0 in
  let steps = ref 0 in
  let step_limit = String.length script + 1000 in
  let vf_exec = ref [] in
  let alt = Stack.create () in
  let context = ref context in
  while !offset < String.length script do
    incr steps;
    let instr_at = !offset in
    let opcode = byte script !offset in
    ensure (!steps <= step_limit) (Printf.sprintf "script instruction limit exceeded at offset %d opcode 0x%02x" instr_at opcode);
    let f_exec = all_true !vf_exec in
    if opcode = op_if || opcode = op_notif then (
      if f_exec then
        let branch = cast_to_bool (Stack.pop stack) in
        vf_exec := (if opcode = op_notif then not branch else branch) :: !vf_exec
      else vf_exec := false :: !vf_exec;
      incr offset)
    else if opcode = op_else then (
      ensure (!vf_exec <> []) "unbalanced conditional";
      (match !vf_exec with
      | x :: rest -> vf_exec := (not x) :: rest
      | [] -> ());
      incr offset)
    else if opcode = op_endif then (
      ensure (!vf_exec <> []) "unbalanced conditional";
      vf_exec := List.tl !vf_exec;
      incr offset)
    else if not f_exec then offset := advance_opcode script !offset
    else if opcode = op_0 then (
      Stack.push stack "";
      incr offset)
    else if opcode >= op_1 && opcode <= op_16 then (
      Stack.push stack (encode_op_n (opcode - op_1 + 1));
      incr offset)
    else if opcode = op_1negate then (
      Stack.push stack "\x81";
      incr offset)
    else if is_push_opcode opcode then (
      let item, next = read_push script !offset in
      Stack.push stack item;
      offset := next)
    else (
      context := eval_opcode opcode stack alt !context false instr_at;
      incr offset)
  done

let timed_eval timing script stack context =
  measure
    (fun ms -> Option.iter (fun timing -> timing.script_interpreter_eval_ms <- timing.script_interpreter_eval_ms + ms) timing)
    (fun () -> evaluate_script script stack context)

let make_context ?cache ?timing ?verifier ~tx ~input_index ~script_code ~code_separator_offset ~amount ~witness () =
  { tx; input_index; script_code; code_separator_offset; amount; witness; cache; timing; verifier }

let verify_p2wpkh_witness ?cache ?timing ?verifier script_pubkey transaction input_index amount witness =
  if List.length witness <> 2 then false
  else
    let script_code = p2pkh_script_code (sub script_pubkey 2 20) in
    let stack = Stack.create () in
    List.iter (Stack.push stack) witness;
    let context = make_context ?cache ?timing ?verifier ~tx:transaction ~input_index ~script_code ~code_separator_offset:0 ~amount ~witness:true () in
    timed_eval timing script_code stack context;
    terminal_strict stack

let verify_p2wsh_witness ?cache ?timing ?verifier witness_program transaction input_index amount witness min_items =
  if List.length witness < min_items then false
  else
    let witness_script = List.nth witness (List.length witness - 1) in
    if witness_script = "" || String.length witness_script > max_consensus_script_size || sha256_bytes witness_script <> witness_program then false
    else
      let stack = Stack.create () in
      List.iter (Stack.push stack) (List.rev (List.tl (List.rev witness)));
      let context = make_context ?cache ?timing ?verifier ~tx:transaction ~input_index ~script_code:witness_script ~code_separator_offset:0 ~amount ~witness:true () in
      timed_eval timing witness_script stack context;
      terminal_strict stack

let verify_p2wpkh ?cache ?timing ?verifier script_sig script_pubkey transaction input_index amount witness =
  script_sig = "" && verify_p2wpkh_witness ?cache ?timing ?verifier script_pubkey transaction input_index amount witness

let verify_p2wsh ?cache ?timing ?verifier script_sig script_pubkey transaction input_index amount witness =
  script_sig = "" && verify_p2wsh_witness ?cache ?timing ?verifier (sub script_pubkey 2 32) transaction input_index amount witness 1

let verify_p2sh ?cache ?timing ?verifier script_sig script_pubkey transaction input_index amount witness =
  let pushes = parse_push_only script_sig in
  if pushes = [] || String.length (List.nth pushes (List.length pushes - 1)) > max_script_element_size then false
  else
    let redeem = List.nth pushes (List.length pushes - 1) in
    let context = make_context ?cache ?timing ?verifier ~tx:transaction ~input_index ~script_code:script_pubkey ~code_separator_offset:0 ~amount ~witness:false () in
    let stack_sig = Stack.create () in
    timed_eval timing script_sig stack_sig context;
    if Stack.size stack_sig = 0 || Stack.peek stack_sig <> redeem then false
    else
      let outer = Stack.create () in
      Stack.push_all outer (Stack.snapshot stack_sig);
      timed_eval timing script_pubkey outer context;
      if (not (terminal_relaxed outer)) || hash160 redeem <> sub script_pubkey 2 20 then false
      else if is_p2wpkh redeem then verify_p2wpkh_witness ?cache ?timing ?verifier redeem transaction input_index amount witness
      else if is_p2wsh redeem then verify_p2wsh_witness ?cache ?timing ?verifier (sub redeem 2 32) transaction input_index amount witness 1
      else
        let inner = Stack.create () in
        let snap = Stack.snapshot stack_sig in
        snap |> List.rev |> List.tl |> List.rev |> List.iter (Stack.push inner);
        let inner_context = make_context ?cache ?timing ?verifier ~tx:transaction ~input_index ~script_code:redeem ~code_separator_offset:0 ~amount ~witness:false () in
        timed_eval timing redeem inner inner_context;
        terminal_relaxed inner

let sha_prevouts transaction =
  let b = Buffer.create 128 in
  List.iter (fun input -> Buffer.add_string b (Tx.serialize_outpoint input.Tx.previous_output)) transaction.Tx.inputs;
  sha256_bytes (Buffer.contents b)

let sha_amounts (prevouts : spent_prevout list) =
  let b = Buffer.create 128 in
  List.iter (fun (prevout : spent_prevout) -> Tx.put_i64 b prevout.amount) prevouts;
  sha256_bytes (Buffer.contents b)

let sha_script_pubkeys (prevouts : spent_prevout list) =
  let b = Buffer.create 128 in
  List.iter
    (fun prevout ->
      Buffer.add_string b (Tx.compact_size (String.length (prevout : spent_prevout).script_pubkey));
      Buffer.add_string b prevout.script_pubkey)
    prevouts;
  sha256_bytes (Buffer.contents b)

let sha_sequences transaction =
  let b = Buffer.create 64 in
  List.iter (fun input -> Tx.put_u32 b input.Tx.sequence) transaction.Tx.inputs;
  sha256_bytes (Buffer.contents b)

let sha_outputs_all transaction =
  let b = Buffer.create 256 in
  List.iter (fun output -> Buffer.add_string b (Tx.serialize_txout output)) transaction.Tx.outputs;
  sha256_bytes (Buffer.contents b)

let create_sighash_cache_for_array transaction (spent_prevouts_array : spent_prevout array) needs =
  let inputs = Array.of_list transaction.Tx.inputs in
  let outputs = Array.of_list transaction.Tx.outputs in
  let witness = Array.of_list transaction.Tx.witness in
  let spent_prevouts = Array.to_list spent_prevouts_array in
  let serialize_prevouts () =
    let b = Buffer.create (36 * Array.length inputs) in
    Array.iter (fun input -> Buffer.add_string b (Tx.serialize_outpoint input.Tx.previous_output)) inputs;
    Buffer.contents b
  in
  let serialize_sequences () =
    let b = Buffer.create (4 * Array.length inputs) in
    Array.iter (fun input -> Tx.put_u32 b input.Tx.sequence) inputs;
    Buffer.contents b
  in
  let serialize_outputs_all () =
    let b = Buffer.create 256 in
    Array.iter (fun output -> Buffer.add_string b (Tx.serialize_txout output)) outputs;
    Buffer.contents b
  in
  let hash_prevouts = lazy (serialize_prevouts ()) in
  let sequence_bytes = lazy (serialize_sequences ()) in
  let outputs_bytes = lazy (serialize_outputs_all ()) in
  let serialized_outputs = lazy (Array.map Tx.serialize_txout outputs) in
  let bip143_single_outputs = if needs.needs_bip143 then Array.map double_sha (Lazy.force serialized_outputs) else [||] in
  let taproot_single_outputs = if needs.needs_taproot then Array.map sha256_bytes (Lazy.force serialized_outputs) else [||] in
  let taproot_amount_bytes =
    if needs.needs_taproot then
      let b = Buffer.create (8 * Array.length spent_prevouts_array) in
      Array.iter (fun (prevout : spent_prevout) -> Tx.put_i64 b prevout.amount) spent_prevouts_array;
      Buffer.contents b
    else ""
  in
  let taproot_script_pubkey_bytes =
    if needs.needs_taproot then
      let b = Buffer.create 256 in
      Array.iter
        (fun (prevout : spent_prevout) ->
          Buffer.add_string b (Tx.compact_size (String.length prevout.script_pubkey));
          Buffer.add_string b prevout.script_pubkey)
        spent_prevouts_array;
      Buffer.contents b
    else ""
  in
  {
    tx = transaction;
    inputs;
    outputs;
    witness;
    spent_prevouts;
    spent_prevouts_array;
    has_legacy = needs.needs_legacy;
    has_bip143 = needs.needs_bip143;
    has_taproot = needs.needs_taproot;
    legacy_empty_inputs_all = if needs.needs_legacy then Array.map (fun input -> legacy_empty_input input input.Tx.sequence) inputs else [||];
    legacy_empty_inputs_zero_sequence = if needs.needs_legacy then Array.map (fun input -> legacy_empty_input input 0l) inputs else [||];
    legacy_outputs_all = if needs.needs_legacy then legacy_outputs_all transaction else "";
    bip143_prevouts = if needs.needs_bip143 then double_sha (Lazy.force hash_prevouts) else "";
    bip143_sequence = if needs.needs_bip143 then double_sha (Lazy.force sequence_bytes) else "";
    bip143_outputs_all = if needs.needs_bip143 then double_sha (Lazy.force outputs_bytes) else "";
    bip143_single_outputs;
    taproot_prevouts = if needs.needs_taproot then sha256_bytes (Lazy.force hash_prevouts) else "";
    taproot_amounts = if needs.needs_taproot then sha256_bytes taproot_amount_bytes else "";
    taproot_script_pubkeys = if needs.needs_taproot then sha256_bytes taproot_script_pubkey_bytes else "";
    taproot_sequences = if needs.needs_taproot then sha256_bytes (Lazy.force sequence_bytes) else "";
    taproot_outputs_all = if needs.needs_taproot then sha256_bytes (Lazy.force outputs_bytes) else "";
    taproot_single_outputs;
  }

let full_sighash_needs = { needs_legacy = true; needs_bip143 = true; needs_taproot = true }
let empty_sighash_needs = { needs_legacy = false; needs_bip143 = false; needs_taproot = false }

let create_sighash_cache transaction (spent_prevouts : spent_prevout list) =
  create_sighash_cache_for_array transaction (Array.of_list spent_prevouts) full_sighash_needs

let taproot_allowed_hash_type hash_type = hash_type <= 0x03 || (hash_type >= 0x81 && hash_type <= 0x83)
let tapleaf_hash version script = tagged_hash "TapLeaf" (String.make 1 (Char.chr version) ^ Tx.compact_size (String.length script) ^ script)

let tapbranch_hash left right =
  if String.compare left right <= 0 then tagged_hash "TapBranch" (left ^ right) else tagged_hash "TapBranch" (right ^ left)

let serialized_witness_stack stack =
  let b = Buffer.create 128 in
  Buffer.add_string b (Tx.compact_size (List.length stack));
  List.iter
    (fun item ->
      Buffer.add_string b (Tx.compact_size (String.length item));
      Buffer.add_string b item)
    stack;
  Buffer.contents b

type taproot_options = {
  hash_type : int;
  annex : string option;
  ext_flag : int;
  tapleaf_hash : string option;
  code_separator_pos : int32;
}

let taproot_sighash ?cache transaction input_index (spent_prevouts : spent_prevout list) opt =
  ensure (List.length spent_prevouts = List.length transaction.Tx.inputs) "spent_prevouts length mismatch";
  ensure (taproot_allowed_hash_type opt.hash_type) "unsupported taproot sighash type";
  ensure (input_index < List.length transaction.inputs) "input index out of range";
  let output_mode = ref opt.hash_type in
  if !output_mode = taproot_sighash_default then output_mode := taproot_sighash_all;
  output_mode := !output_mode land 0x03;
  let anyone_can_pay = opt.hash_type land 0x80 <> 0 in
  if !output_mode = taproot_sighash_single && input_index >= List.length transaction.outputs then err "SIGHASH_SINGLE without matching output";
  let b = Buffer.create 512 in
  Buffer.add_char b (Char.chr opt.hash_type);
  Tx.put_u32 b transaction.version;
  Tx.put_u32 b transaction.lock_time;
  if not anyone_can_pay then (
    match cache with
    | Some (cache : sighash_cache) when cache.tx == transaction && cache.has_taproot ->
        Buffer.add_string b cache.taproot_prevouts;
        Buffer.add_string b cache.taproot_amounts;
        Buffer.add_string b cache.taproot_script_pubkeys;
        Buffer.add_string b cache.taproot_sequences
    | _ ->
        Buffer.add_string b (sha_prevouts transaction);
        Buffer.add_string b (sha_amounts spent_prevouts);
        Buffer.add_string b (sha_script_pubkeys spent_prevouts);
        Buffer.add_string b (sha_sequences transaction));
  if !output_mode = taproot_sighash_all then
    Buffer.add_string b
      (match cache with
      | Some (cache : sighash_cache) when cache.tx == transaction && cache.has_taproot -> cache.taproot_outputs_all
      | _ -> sha_outputs_all transaction);
  let spend_type = (opt.ext_flag lsl 1) + if Option.is_some opt.annex then 1 else 0 in
  Buffer.add_char b (Char.chr spend_type);
  if anyone_can_pay then (
    let input = input_at ?cache transaction input_index in
    let prevout = spent_prevout_at ?cache spent_prevouts transaction input_index in
    Buffer.add_string b (Tx.serialize_outpoint input.previous_output);
    Buffer.add_string b (Tx.serialize_txout { value = prevout.amount; script_pubkey = prevout.script_pubkey });
    Tx.put_u32 b input.sequence)
  else Tx.put_u32 b (Int32.of_int input_index);
  (match opt.annex with
  | Some annex -> Buffer.add_string b (sha256_bytes (Tx.compact_size (String.length annex) ^ annex))
  | None -> ());
  if !output_mode = taproot_sighash_single then
    Buffer.add_string b
      (match cache_matches cache transaction with
      | Some cache when cache.has_taproot -> cache.taproot_single_outputs.(input_index)
      | Some _ | None -> sha256_bytes (Tx.serialize_txout (output_at ?cache transaction input_index)));
  if opt.ext_flag = 1 then (
    let leaf = match opt.tapleaf_hash with Some value -> value | None -> err "tapscript sighash missing leaf hash" in
    Buffer.add_string b leaf;
    Buffer.add_char b '\000';
    Tx.put_u32 b opt.code_separator_pos);
  tagged_hash "TapSighash" ("\000" ^ Buffer.contents b)

let opcode_is_success op =
  op = 80 || op = 98 || (op >= 126 && op <= 129) || (op >= 131 && op <= 134) || (op >= 137 && op <= 138)
  || (op >= 141 && op <= 142) || (op >= 149 && op <= 153) || (op >= 187 && op <= 254)

let prescan_op_success script =
  let offset = ref 0 in
  let found = ref false in
  while (not !found) && !offset < String.length script do
    let op = byte script !offset in
    if op = op_0 || (op >= op_1 && op <= op_16) || op = op_1negate then incr offset
    else if op >= 1 && op <= 75 then offset := !offset + 1 + op
    else if op = op_pushdata1 || op = op_pushdata2 || op = op_pushdata4 then offset := snd (read_push script !offset)
    else if opcode_is_success op then found := true
    else incr offset
  done;
  !found

let verify_tap_signature ?cache ?timing ?verifier pubkey sig_blob transaction input_index spent_prevouts annex leaf code_sep budget =
  ensure (pubkey <> "") "empty pubkey in tapscript";
  if sig_blob <> "" then (
    budget := !budget - tap_validation_per_sigop;
    ensure (!budget >= 0) "tapscript validation weight exceeded");
  if String.length pubkey <> 32 then sig_blob <> ""
  else if sig_blob = "" then false
  else
    let hash_type, sig64 =
      if String.length sig_blob = 65 then (
        let h = byte sig_blob 64 in
        ensure (h <> taproot_sighash_default) "invalid tap hashtype";
        h, sub sig_blob 0 64)
      else (
        ensure (String.length sig_blob = 64) "invalid Schnorr signature length";
        taproot_sighash_default, sig_blob)
    in
    let digest =
      measure
        (fun ms -> Option.iter (fun timing -> timing.script_sighash_taproot_ms <- timing.script_sighash_taproot_ms + ms) timing)
        (fun () ->
          taproot_sighash ?cache transaction input_index spent_prevouts
            { hash_type; annex; ext_flag = 1; tapleaf_hash = Some leaf; code_separator_pos = code_sep })
    in
    let valid =
      measure
      (fun ms -> Option.iter (fun timing -> timing.script_schnorr_verify_ms <- timing.script_schnorr_verify_ms + ms) timing)
      (fun () -> verify_schnorr ?verifier pubkey digest sig64)
    in
    if not valid then debug_tapscript_signature_failure input_index hash_type pubkey digest sig64 leaf;
    valid

let eval_tap_sig_op ?cache ?timing ?verifier op stack transaction input_index spent_prevouts annex leaf code_sep budget =
  if op = op_checksig || op = op_checksigverify then (
    let pubkey = Stack.pop stack in
    let sig_blob = Stack.pop stack in
    let valid = verify_tap_signature ?cache ?timing ?verifier pubkey sig_blob transaction input_index spent_prevouts annex leaf code_sep budget in
    if op = op_checksig then Stack.push stack (encode_op_n (if valid then 1 else 0)) else ensure valid "CHECKSIGVERIFY failed")
  else
    let pubkey = Stack.pop stack in
    let n_item = Stack.pop stack in
    let sig_blob = Stack.pop stack in
    let n = ref (decode_script_num n_item 4) in
    if sig_blob = "" then Stack.push stack (encode_script_num !n 4)
    else (
      if verify_tap_signature ?cache ?timing ?verifier pubkey sig_blob transaction input_index spent_prevouts annex leaf code_sep budget then n := Int64.add !n 1L;
      Stack.push stack (encode_script_num !n 4))

let evaluate_tapscript ?cache ?timing ?verifier script stack transaction input_index leaf spent_prevouts annex budget =
  let offset = ref 0 in
  let steps = ref 0 in
  let step_limit = String.length script + 1000 in
  let vf_exec = ref [] in
  let alt = Stack.create () in
  let code_sep = ref Int32.minus_one in
  while !offset < String.length script do
    incr steps;
    let instr_at = !offset in
    let op = byte script !offset in
    ensure (!steps <= step_limit) (Printf.sprintf "tapscript instruction limit exceeded at offset %d opcode 0x%02x" instr_at op);
    let f_exec = all_true !vf_exec in
    if op = op_if || op = op_notif then (
      if f_exec then
        let branch = cast_to_bool (Stack.pop stack) in
        vf_exec := (if op = op_notif then not branch else branch) :: !vf_exec
      else vf_exec := false :: !vf_exec;
      incr offset)
    else if op = op_else then (
      ensure (!vf_exec <> []) "unbalanced conditional";
      (match !vf_exec with x :: rest -> vf_exec := (not x) :: rest | [] -> ());
      incr offset)
    else if op = op_endif then (
      ensure (!vf_exec <> []) "unbalanced conditional";
      vf_exec := List.tl !vf_exec;
      incr offset)
    else if not f_exec then offset := advance_opcode script !offset
    else if op = op_checksig || op = op_checksigverify || op = op_checksigadd then (
      eval_tap_sig_op ?cache ?timing ?verifier op stack transaction input_index spent_prevouts annex leaf !code_sep budget;
      incr offset)
    else if op = op_codeseparator then (
      code_sep := Int32.of_int instr_at;
      incr offset)
    else if op = op_checkmultisig || op = op_checkmultisigverify then err "CHECKMULTISIG disabled in tapscript"
    else if op = op_checklocktimeverify then (
      check_lock_time_verify stack transaction;
      incr offset)
    else if op = op_checksequenceverify then (
      check_sequence_verify stack transaction input_index;
      incr offset)
    else if op = op_0 || (op >= op_1 && op <= op_16) || op = op_1negate || is_push_opcode op then (
      if op = op_0 then (Stack.push stack ""; incr offset)
      else if op >= op_1 && op <= op_16 then (Stack.push stack (encode_op_n (op - op_1 + 1)); incr offset)
      else if op = op_1negate then (Stack.push stack "\x81"; incr offset)
      else
        let item, next = read_push script !offset in
        Stack.push stack item;
        offset := next)
    else (
      let context =
        {
          tx = transaction;
          input_index;
          script_code = script;
          code_separator_offset = 0;
          amount = (List.nth spent_prevouts input_index).amount;
          witness = true;
          cache;
          timing;
          verifier;
        }
      in
      ignore (eval_opcode op stack alt context true instr_at);
      incr offset)
  done

let verify_taproot_script_path ?cache ?timing ?verifier script_pubkey witness annex transaction input_index spent_prevouts serialized_witness =
  if List.length spent_prevouts <> List.length transaction.Tx.inputs || List.length witness < 2 then false
  else
    let script_bytes = List.nth witness (List.length witness - 2) in
    let control = List.nth witness (List.length witness - 1) in
    let stack_items = witness |> List.rev |> List.tl |> List.tl |> List.rev in
    if script_bytes = "" || String.length control < 33 || String.length control > 33 + (128 * 32) || (String.length control - 33) mod 32 <> 0 then false
    else
      let leaf_masked = byte control 0 land 0xfe in
      if leaf_masked = 0x50 then false
      else
        let internal_x = sub control 1 32 in
        let leaf = tapleaf_hash leaf_masked script_bytes in
        let root = ref leaf in
        let offset = ref 33 in
        while !offset < String.length control do
          root := tapbranch_hash !root (sub control !offset 32);
          offset := !offset + 32
        done;
        let tweak_result =
          match verifier with
          | Some verifier -> Crypto.taproot_tweak_xonly_bytes_with_verifier ~verifier ~xonly_pubkey:internal_x ~merkle_root:!root
          | None -> Crypto.taproot_tweak_xonly_bytes ~xonly_pubkey:internal_x ~merkle_root:!root
        in
        match tweak_result with
        | None -> false
        | Some (output_xonly, parity) ->
            if sub script_pubkey 2 32 <> output_xonly || byte control 0 <> (leaf_masked lor parity) then false
            else if leaf_masked <> taproot_leaf_tapscript then true
            else if prescan_op_success script_bytes then true
            else if List.length stack_items > max_tapscript_stack_items || List.exists (fun item -> String.length item > max_script_element_size) stack_items then false
            else
              let budget = ref (tap_validation_offset + String.length serialized_witness) in
              let stack = Stack.create () in
              List.iter (Stack.push stack) stack_items;
              measure
                (fun ms -> Option.iter (fun timing -> timing.script_interpreter_eval_ms <- timing.script_interpreter_eval_ms + ms) timing)
                (fun () -> evaluate_tapscript ?cache ?timing ?verifier script_bytes stack transaction input_index leaf spent_prevouts annex budget);
              if not (terminal_strict stack) then debug_tapscript_final_stack input_index stack;
              ensure (terminal_strict stack)
                ("tapscript failed final stack check: "
                ^ Yojson.Safe.to_string
                    (`Assoc [
                      "stack_size", `Int (Stack.size stack);
                      "stack", `List (List.map (fun item -> `String (Util.hex_of_bytes item)) (Stack.snapshot stack));
                    ]));
              true

let verify_taproot ?cache ?timing ?verifier script_pubkey script_sig witness transaction input_index spent_prevouts =
  if script_sig <> "" || spent_prevouts = [] || not (is_p2tr script_pubkey) then false
  else
    let serialized_witness = serialized_witness_stack witness in
    if List.length witness >= 2 && List.nth witness (List.length witness - 1) <> "" && byte (List.nth witness (List.length witness - 1)) 0 = 0x50 then false
    else if List.length witness >= 2 then verify_taproot_script_path ?cache ?timing ?verifier script_pubkey witness None transaction input_index spent_prevouts serialized_witness
    else if List.length witness <> 1 then false
    else
      let sig_blob = List.hd witness in
      if String.length sig_blob <> 64 && String.length sig_blob <> 65 then false
      else
        let hash_type, sig64 =
          if String.length sig_blob = 65 then (
            let h = byte sig_blob 64 in
            if h = taproot_sighash_default then -1, "" else h, sub sig_blob 0 64)
          else taproot_sighash_default, sig_blob
        in
        hash_type >= 0
        &&
        let digest =
          measure
            (fun ms -> Option.iter (fun timing -> timing.script_sighash_taproot_ms <- timing.script_sighash_taproot_ms + ms) timing)
            (fun () ->
              taproot_sighash ?cache transaction input_index spent_prevouts
                { hash_type; annex = None; ext_flag = 0; tapleaf_hash = None; code_separator_pos = Int32.minus_one })
        in
        measure
          (fun ms -> Option.iter (fun timing -> timing.script_schnorr_verify_ms <- timing.script_schnorr_verify_ms + ms) timing)
          (fun () -> verify_schnorr ?verifier (sub script_pubkey 2 32) digest sig64)

let verify_script ?cache ?timing ?verifier script_sig script_pubkey transaction input_index amount witness spent_prevouts =
  if is_p2tr script_pubkey then verify_taproot ?cache ?timing ?verifier script_pubkey script_sig witness transaction input_index spent_prevouts
  else if is_p2wpkh script_pubkey then verify_p2wpkh ?cache ?timing ?verifier script_sig script_pubkey transaction input_index amount witness
  else if is_p2wsh script_pubkey then verify_p2wsh ?cache ?timing ?verifier script_sig script_pubkey transaction input_index amount witness
  else if is_p2sh script_pubkey then verify_p2sh ?cache ?timing ?verifier script_sig script_pubkey transaction input_index amount witness
  else
    let context = make_context ?cache ?timing ?verifier ~tx:transaction ~input_index ~script_code:script_pubkey ~code_separator_offset:0 ~amount ~witness:false () in
    if is_p2pk script_pubkey then (
      if witness <> [] then false
      else
        let pushes = parse_push_only script_sig in
        if List.length pushes <> 1 || List.hd pushes = "" then false
        else
          let stack_sig = Stack.create () in
          timed_eval timing script_sig stack_sig context;
          let stack = Stack.create () in
          Stack.push_all stack (Stack.snapshot stack_sig);
          timed_eval timing script_pubkey stack context;
          terminal_strict stack)
    else if (is_bare_op_n script_pubkey || is_bare_multisig script_pubkey || is_bare_legacy_script script_pubkey) && witness <> [] then false
    else
      let stack_sig = Stack.create () in
      timed_eval timing script_sig stack_sig context;
      let stack = Stack.create () in
      Stack.push_all stack (Stack.snapshot stack_sig);
      timed_eval timing script_pubkey stack context;
      if (is_bare_op_n script_pubkey && String.length script_pubkey > 1) || is_bare_legacy_script script_pubkey || is_p2pkh script_pubkey then
        terminal_relaxed stack
      else terminal_strict stack

(* Spend-path verifier for Shared-supported templates. Unsupported shapes -> validation blocker. *)
let verify_transaction_input_with_cache_and_timing ?cache ?verifier transaction input_index options =
  let timing = empty_timing () in
  try
    ensure (input_index < input_count ?cache transaction) "input index out of range";
    (match witness_version options.script_pubkey with Some version -> ensure (version <= 1) "unsupported witness program version" | None -> ());
    ensure
      (is_p2pk options.script_pubkey || is_p2pkh options.script_pubkey || is_p2wpkh options.script_pubkey || is_p2wsh options.script_pubkey
       || is_p2sh options.script_pubkey || is_p2tr options.script_pubkey || is_bare_op_n options.script_pubkey || is_bare_multisig options.script_pubkey
      || is_bare_legacy_script options.script_pubkey)
      ("unsupported OCaml scriptPubKey template: " ^ Util.hex_of_bytes options.script_pubkey);
    let witness =
      match cache_matches cache transaction with
      | Some cache -> if input_index < Array.length cache.witness then cache.witness.(input_index) else []
      | None -> if input_index < List.length transaction.witness then List.nth transaction.witness input_index else []
    in
    let cache =
      match cache_matches cache transaction with
      | Some cache -> Some cache
      | None -> Some (create_sighash_cache transaction options.spent_prevouts)
    in
    let timing_opt = Some timing in
    ensure
      (verify_script ?cache ?timing:timing_opt ?verifier (input_at ?cache transaction input_index).script_sig options.script_pubkey transaction input_index
         options.amount witness options.spent_prevouts)
      (Printf.sprintf "script verification failed for input %d" input_index);
    Ok (), timing
  with Script_error message -> Error message, timing

let verify_transaction_input_with_timing transaction input_index options =
  verify_transaction_input_with_cache_and_timing transaction input_index options

let verify_transaction_input transaction input_index options =
  fst (verify_transaction_input_with_timing transaction input_index options)

let test_cast_to_bool = cast_to_bool
let test_decode_script_num = decode_script_num
let test_encode_script_num = encode_script_num
let test_legacy_sighash = legacy_sighash
let test_legacy_sighash_cached transaction spent_prevouts input_index script_code sighash_type =
  let cache = create_sighash_cache transaction spent_prevouts in
  legacy_sighash ~cache transaction input_index script_code sighash_type
let test_bip143_sighash transaction input_index script_code amount sighash_type =
  bip143_sighash transaction input_index script_code amount sighash_type

let test_bip143_sighash_cached transaction spent_prevouts input_index script_code amount sighash_type =
  let cache = create_sighash_cache transaction spent_prevouts in
  bip143_sighash ~cache transaction input_index script_code amount sighash_type

let test_taproot_sighash transaction input_index spent_prevouts hash_type =
  taproot_sighash transaction input_index spent_prevouts
    { hash_type; annex = None; ext_flag = 0; tapleaf_hash = None; code_separator_pos = Int32.minus_one }

let test_taproot_sighash_cached transaction input_index spent_prevouts hash_type =
  let cache = create_sighash_cache transaction spent_prevouts in
  taproot_sighash ~cache transaction input_index spent_prevouts
    { hash_type; annex = None; ext_flag = 0; tapleaf_hash = None; code_separator_pos = Int32.minus_one }

let test_tapscript_sighash transaction input_index spent_prevouts hash_type tapleaf_hash =
  taproot_sighash transaction input_index spent_prevouts
    { hash_type; annex = None; ext_flag = 1; tapleaf_hash = Some tapleaf_hash; code_separator_pos = Int32.minus_one }

let test_tapscript_sighash_cached transaction input_index spent_prevouts hash_type tapleaf_hash =
  let cache = create_sighash_cache transaction spent_prevouts in
  taproot_sighash ~cache transaction input_index spent_prevouts
    { hash_type; annex = None; ext_flag = 1; tapleaf_hash = Some tapleaf_hash; code_separator_pos = Int32.minus_one }

let test_tapscript_signature transaction input_index spent_prevouts pubkey signature tapleaf_hash =
  verify_tap_signature pubkey signature transaction input_index spent_prevouts None tapleaf_hash Int32.minus_one (ref (tap_validation_offset + 1024))

let test_tapscript_signature_cached transaction input_index spent_prevouts pubkey signature tapleaf_hash =
  let cache = create_sighash_cache transaction spent_prevouts in
  verify_tap_signature ~cache pubkey signature transaction input_index spent_prevouts None tapleaf_hash Int32.minus_one (ref (tap_validation_offset + 1024))

let test_evaluate_tapscript_stack transaction input_index spent_prevouts script stack_items tapleaf_hash =
  let stack = Stack.create () in
  List.iter (Stack.push stack) stack_items;
  evaluate_tapscript script stack transaction input_index tapleaf_hash spent_prevouts None (ref (tap_validation_offset + 1024));
  Stack.snapshot stack

let test_taproot_script_path script_pubkey witness transaction input_index spent_prevouts =
  verify_taproot_script_path script_pubkey witness None transaction input_index spent_prevouts (serialized_witness_stack witness)

let test_tapleaf_hash = tapleaf_hash
