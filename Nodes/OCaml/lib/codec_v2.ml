let compact_size value =
  if value < 0 then invalid_arg "compact-size cannot encode negative values"
  else if value < 0xfd then String.make 1 (Char.chr value)
  else if value <= 0xffff then
    String.init 3 (function
      | 0 -> Char.chr 0xfd
      | 1 -> Char.chr (value land 0xff)
      | _ -> Char.chr ((value lsr 8) land 0xff))
  else if value <= 0xffffffff then
    String.init 5 (function
      | 0 -> Char.chr 0xfe
      | i -> Char.chr ((value lsr (8 * (i - 1))) land 0xff))
  else
    let v = Int64.of_int value in
    String.init 9 (function
      | 0 -> Char.chr 0xff
      | i ->
          Char.chr
            (Int64.to_int
               (Int64.logand (Int64.shift_right_logical v (8 * (i - 1))) 0xffL)))

let byte_at raw offset =
  if offset >= String.length raw then invalid_arg "truncated codec v2 byte";
  Char.code raw.[offset]

let le16_at raw offset =
  byte_at raw offset lor (byte_at raw (offset + 1) lsl 8)

let le32_at raw offset =
  byte_at raw offset lor (byte_at raw (offset + 1) lsl 8) lor (byte_at raw (offset + 2) lsl 16)
  lor (byte_at raw (offset + 3) lsl 24)

let le64_at raw offset =
  let value = ref 0L in
  for i = 0 to 7 do
    value := Int64.logor !value (Int64.shift_left (Int64.of_int (byte_at raw (offset + i))) (8 * i))
  done;
  !value

let read_compact_size raw offset =
  let first = byte_at raw offset in
  match first with
  | 0xfd ->
      if offset + 3 > String.length raw then invalid_arg "truncated codec v2 compactsize16";
      le16_at raw (offset + 1), offset + 3
  | 0xfe ->
      if offset + 5 > String.length raw then invalid_arg "truncated codec v2 compactsize32";
      le32_at raw (offset + 1), offset + 5
  | 0xff ->
      if offset + 9 > String.length raw then invalid_arg "truncated codec v2 compactsize64";
      let value = le64_at raw (offset + 1) in
      if value > Int64.of_int max_int then invalid_arg "codec v2 compactsize too large";
      Int64.to_int value, offset + 9
  | value -> value, offset + 1

let be32 value =
  String.init 4 (fun i -> Char.chr ((value lsr ((3 - i) * 8)) land 0xff))

let be64 value =
  String.init 8 (fun i -> Char.chr (Int64.to_int (Int64.shift_right_logical value ((7 - i) * 8)) land 0xff))

let prefixed prefix chain suffix = prefix ^ compact_size (String.length chain) ^ chain ^ suffix

let metadata_key name = "m" ^ compact_size (String.length name) ^ name

let tip_key chain = prefixed "t" chain ""

let height_key prefix chain height = prefixed prefix chain (be32 height)

let utxo_key ~chain ~txid ~vout = prefixed "u" chain (txid ^ be32 vout)

let tip_value ~height ~hash = be32 height ^ hash

let block_index_value ~hash ~file_number ~file_offset ~block_size =
  hash ^ be32 file_number ^ be32 file_offset ^ be32 block_size

let header_value serialized_header = be32 0x50000000 ^ serialized_header

let utxo_value ~height ~vout ~value_sats ~coinbase ~script_pubkey =
  be32 height ^ be32 vout ^ be64 value_sats ^
  (if coinbase then "\001" else "\000") ^
  compact_size (String.length script_pubkey) ^ script_pubkey

let undo_value entries =
  let encode_entry (txid, vout, height, coinbase, value_sats, script_pubkey) =
    txid ^ be32 vout ^ be32 height ^ (if coinbase then "\001" else "\000") ^
    be64 value_sats ^ compact_size (String.length script_pubkey) ^ script_pubkey
  in
  be32 (List.length entries) ^ String.concat "" (List.map encode_entry entries)
