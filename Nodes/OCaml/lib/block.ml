type header = {
  version : int32;
  prev_block : string;
  merkle_root : string;
  time : int32;
  bits : int32;
  nonce : int32;
  raw : string;
}

type t = {
  header : header;
  transactions : Tx.t list;
}

exception Block_error of string

let fail msg = raise (Block_error msg)

let ensure condition msg = if not condition then fail msg

let parse_header raw =
  ensure (String.length raw >= 80) "block header too short";
  {
    version = Tx.le32 raw 0;
    prev_block = String.sub raw 4 32;
    merkle_root = String.sub raw 36 32;
    time = Tx.le32 raw 68;
    bits = Tx.le32 raw 72;
    nonce = Tx.le32 raw 76;
    raw = String.sub raw 0 80;
  }

let parse raw =
  let header = parse_header raw in
  let transactions = Tx.parse_block_transactions raw in
  { header; transactions }

let header_hash header = Tx.double_sha header.raw

let header_hash_hex header = Tx.display_hash (header_hash header)

let merkle_parent a b = Tx.double_sha (a ^ b)

let merkle_root txs =
  let rec layer hashes =
    match hashes with
    | [] -> fail "empty merkle tree"
    | [ single ] -> single
    | _ ->
        let rec pairs rows acc =
          match rows with
          | [] -> List.rev acc
          | [ last ] -> List.rev (merkle_parent last last :: acc)
          | a :: b :: rest -> pairs rest (merkle_parent a b :: acc)
        in
        layer (pairs hashes [])
  in
  layer (List.map Tx.txid_internal txs)

let validate_merkle_root block =
  block.header.merkle_root = merkle_root block.transactions

let target_from_bits bits =
  let bits = Int32.to_int bits in
  let exponent = (bits lsr 24) land 0xff in
  let mantissa = bits land 0x00ff_ffff in
  let target = Bytes.make 32 '\000' in
  (if exponent <= 3 then
    let value = mantissa lsr (8 * (3 - exponent)) in
    for i = 0 to min 3 exponent - 1 do
      Bytes.set target i (Char.chr ((value lsr (8 * i)) land 0xff))
    done
  else
    let offset = exponent - 3 in
    for i = 0 to 2 do
      if offset + i < 32 then Bytes.set target (offset + i) (Char.chr ((mantissa lsr (8 * i)) land 0xff))
    done);
  Bytes.unsafe_to_string target

let little_endian_leq a b =
  let rec loop i =
    if i < 0 then true
    else
      let av = Char.code a.[i] in
      let bv = Char.code b.[i] in
      av < bv || (av = bv && loop (i - 1))
  in
  loop 31

let proof_of_work_ok header =
  little_endian_leq (header_hash header) (target_from_bits header.bits)
