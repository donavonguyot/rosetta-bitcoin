type outpoint = {
  hash : string;
  index : int32;
}

type tx_in = {
  previous_output : outpoint;
  script_sig : string;
  sequence : int32;
}

type tx_out = {
  value : int64;
  script_pubkey : string;
}

type t = {
  version : int32;
  inputs : tx_in list;
  outputs : tx_out list;
  lock_time : int32;
  witness : string list list;
}

exception Parse_error of string

let fail msg = raise (Parse_error msg)

let ensure condition msg = if not condition then fail msg

let byte data offset =
  if offset >= String.length data then fail "truncated byte";
  Char.code data.[offset]

let sub data offset len =
  ensure (offset + len <= String.length data) "truncated bytes";
  String.sub data offset len

let le16 data offset =
  byte data offset lor (byte data (offset + 1) lsl 8)

let le32 data offset =
  Int32.logor
    (Int32.of_int (byte data offset))
    (Int32.logor
       (Int32.shift_left (Int32.of_int (byte data (offset + 1))) 8)
       (Int32.logor
          (Int32.shift_left (Int32.of_int (byte data (offset + 2))) 16)
          (Int32.shift_left (Int32.of_int (byte data (offset + 3))) 24)))

let le64 data offset =
  let value = ref 0L in
  for i = 0 to 7 do
    value := Int64.logor !value (Int64.shift_left (Int64.of_int (byte data (offset + i))) (8 * i))
  done;
  !value

let put_u32 buf value =
  for i = 0 to 3 do
    Buffer.add_char buf (Char.chr (Int32.to_int (Int32.logand (Int32.shift_right_logical value (8 * i)) 0xffl)))
  done

let put_i64 buf value =
  for i = 0 to 7 do
    Buffer.add_char buf (Char.chr (Int64.to_int (Int64.logand (Int64.shift_right_logical value (8 * i)) 0xffL)))
  done

let compact_size value =
  let buf = Buffer.create 9 in
  if value < 0xfd then Buffer.add_char buf (Char.chr value)
  else if value <= 0xffff then (
    Buffer.add_char buf '\xfd';
    Buffer.add_char buf (Char.chr (value land 0xff));
    Buffer.add_char buf (Char.chr ((value lsr 8) land 0xff)))
  else if value <= 0xffffffff then (
    Buffer.add_char buf '\xfe';
    for i = 0 to 3 do Buffer.add_char buf (Char.chr ((value lsr (8 * i)) land 0xff)) done)
  else (
    Buffer.add_char buf '\xff';
    let v = Int64.of_int value in
    for i = 0 to 7 do
      Buffer.add_char buf (Char.chr (Int64.to_int (Int64.logand (Int64.shift_right_logical v (8 * i)) 0xffL)))
    done);
  Buffer.contents buf

let read_compact_size data offset =
  let first = byte data offset in
  match first with
  | 0xfd ->
      ensure (offset + 3 <= String.length data) "truncated compactsize16";
      le16 data (offset + 1), offset + 3
  | 0xfe ->
      ensure (offset + 5 <= String.length data) "truncated compactsize32";
      Int32.to_int (le32 data (offset + 1)), offset + 5
  | 0xff ->
      ensure (offset + 9 <= String.length data) "truncated compactsize64";
      Int64.to_int (le64 data (offset + 1)), offset + 9
  | value -> value, offset + 1

let deserialize data offset0 =
  ensure (offset0 + 4 <= String.length data) "truncated tx version";
  let offset = ref offset0 in
  let version = le32 data !offset in
  offset := !offset + 4;
  let has_witness =
    !offset + 2 <= String.length data && byte data !offset = 0 && byte data (!offset + 1) = 1
  in
  if has_witness then offset := !offset + 2;
  let input_count, next = read_compact_size data !offset in
  offset := next;
  let inputs = ref [] in
  for _ = 1 to input_count do
    ensure (!offset + 36 <= String.length data) "truncated tx input outpoint";
    let hash = sub data !offset 32 in
    offset := !offset + 32;
    let index = le32 data !offset in
    offset := !offset + 4;
    let script_len, next = read_compact_size data !offset in
    offset := next;
    let script_sig = sub data !offset script_len in
    offset := !offset + script_len;
    ensure (!offset + 4 <= String.length data) "truncated tx input sequence";
    let sequence = le32 data !offset in
    offset := !offset + 4;
    inputs := { previous_output = { hash; index }; script_sig; sequence } :: !inputs
  done;
  let output_count, next = read_compact_size data !offset in
  offset := next;
  let outputs = ref [] in
  for _ = 1 to output_count do
    ensure (!offset + 8 <= String.length data) "truncated tx output value";
    let value = le64 data !offset in
    offset := !offset + 8;
    let script_len, next = read_compact_size data !offset in
    offset := next;
    let script_pubkey = sub data !offset script_len in
    offset := !offset + script_len;
    outputs := { value; script_pubkey } :: !outputs
  done;
  let witness =
    if has_witness then
      let stacks = ref [] in
      for _ = 1 to input_count do
        let item_count, next = read_compact_size data !offset in
        offset := next;
        let items = ref [] in
        for _ = 1 to item_count do
          let item_len, next = read_compact_size data !offset in
          offset := next;
          let item = sub data !offset item_len in
          offset := !offset + item_len;
          items := item :: !items
        done;
        stacks := List.rev !items :: !stacks
      done;
      List.rev !stacks
    else []
  in
  ensure (!offset + 4 <= String.length data) "truncated tx locktime";
  let lock_time = le32 data !offset in
  offset := !offset + 4;
  { version; inputs = List.rev !inputs; outputs = List.rev !outputs; lock_time; witness }, !offset

let serialize_outpoint outpoint =
  let buf = Buffer.create 36 in
  Buffer.add_string buf outpoint.hash;
  put_u32 buf outpoint.index;
  Buffer.contents buf

let serialize_txout output =
  let buf = Buffer.create (9 + String.length output.script_pubkey) in
  put_i64 buf output.value;
  Buffer.add_string buf (compact_size (String.length output.script_pubkey));
  Buffer.add_string buf output.script_pubkey;
  Buffer.contents buf

let serialize tx ~include_witness =
  let buf = Buffer.create 256 in
  put_u32 buf tx.version;
  let use_witness = include_witness && tx.witness <> [] in
  if use_witness then Buffer.add_string buf "\000\001";
  Buffer.add_string buf (compact_size (List.length tx.inputs));
  List.iter
    (fun input ->
      Buffer.add_string buf (serialize_outpoint input.previous_output);
      Buffer.add_string buf (compact_size (String.length input.script_sig));
      Buffer.add_string buf input.script_sig;
      put_u32 buf input.sequence)
    tx.inputs;
  Buffer.add_string buf (compact_size (List.length tx.outputs));
  List.iter (fun output -> Buffer.add_string buf (serialize_txout output)) tx.outputs;
  if use_witness then
    List.iter
      (fun stack ->
        Buffer.add_string buf (compact_size (List.length stack));
        List.iter
          (fun item ->
            Buffer.add_string buf (compact_size (String.length item));
            Buffer.add_string buf item)
          stack)
      tx.witness;
  put_u32 buf tx.lock_time;
  Buffer.contents buf

let double_sha data =
  Util.sha256_raw (Util.sha256_raw data)

let display_hash raw =
  let len = String.length raw in
  String.init len (fun i -> raw.[len - 1 - i]) |> Util.hex_of_bytes

let parse_display_hash value =
  let bytes = Util.bytes_of_hex value in
  ensure (String.length bytes = 32) "hash is not 32 bytes";
  let len = String.length bytes in
  String.init len (fun i -> bytes.[len - 1 - i])

let txid_internal tx = double_sha (serialize tx ~include_witness:false)

let txid tx = display_hash (txid_internal tx)

let is_coinbase tx =
  match tx.inputs with
  | [ input ] -> input.previous_output.index = Int32.minus_one && input.previous_output.hash = String.make 32 '\000'
  | _ -> false

let parse_block_transactions raw =
  ensure (String.length raw >= 81) "block too short";
  let count, offset = read_compact_size raw 80 in
  let txs = ref [] in
  let cursor = ref offset in
  for _ = 1 to count do
    let tx, next = deserialize raw !cursor in
    txs := tx :: !txs;
    cursor := next
  done;
  ensure (!cursor = String.length raw) "block parser did not consume full block";
  List.rev !txs

let script_pushes script =
  let rec loop offset acc =
    if offset >= String.length script then List.rev acc
    else
      let op = byte script offset in
      if op = 0 then loop (offset + 1) ("" :: acc)
      else
        let len, cursor =
          if op >= 1 && op <= 0x4b then op, offset + 1
          else if op = 0x4c then byte script (offset + 1), offset + 2
          else if op = 0x4d then le16 script (offset + 1), offset + 3
          else if op = 0x4e then Int32.to_int (le32 script (offset + 1)), offset + 5
          else fail "script is not push-only"
        in
        loop (cursor + len) (sub script cursor len :: acc)
  in
  loop 0 []
