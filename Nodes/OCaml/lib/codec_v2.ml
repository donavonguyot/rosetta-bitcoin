let compact_size value =
  if value < 0xfd then String.make 1 (Char.chr value)
  else invalid_arg "codec v2 foundation supports compact-size values below 0xfd"

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

