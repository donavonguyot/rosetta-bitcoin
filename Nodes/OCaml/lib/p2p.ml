exception P2p_error of string

let err msg = raise (P2p_error msg)
let ensure condition msg = if not condition then err msg

let protocol_version = 70016l
let services = 9L
let testnet4_magic = "\x1c\x16\x3f\x28"
let msg_witness_block = Int32.logor (Int32.shift_left 1l 30) 2l
let genesis_hash = "00000000da84f2bafbbc53dee25a72ae507ff4914b867c565be350b0da8bf043"

type message = {
  command : string;
  payload : string;
}

type block = {
  height : int;
  hash : string;
  raw : string;
  fetch_ms : int;
}

type client = {
  ic : in_channel;
  oc : out_channel;
}

let put_u64 buf value =
  for i = 0 to 7 do
    Buffer.add_char buf (Char.chr (Int64.to_int (Int64.logand (Int64.shift_right_logical value (8 * i)) 0xffL)))
  done

let put_i64 = put_u64

let put_u16_be buf value =
  Buffer.add_char buf (Char.chr ((value lsr 8) land 0xff));
  Buffer.add_char buf (Char.chr (value land 0xff))

let command_field command =
  let bytes = Bytes.make 12 '\000' in
  String.iteri (fun i c -> if i < 12 then Bytes.set bytes i c) command;
  Bytes.unsafe_to_string bytes

let checksum payload = String.sub (Tx.double_sha payload) 0 4

let read_exact ic len =
  try really_input_string ic len with End_of_file -> err "peer closed connection"

let read_message client =
  let header = read_exact client.ic 24 in
  ensure (String.sub header 0 4 = testnet4_magic) "unexpected network magic";
  let command = String.sub header 4 12 |> String.split_on_char '\000' |> List.hd in
  let length = Int32.to_int (Tx.le32 header 16) in
  let expected_checksum = String.sub header 20 4 in
  let payload = read_exact client.ic length in
  ensure (checksum payload = expected_checksum) ("checksum mismatch for " ^ command);
  { command; payload }

let send client command payload =
  let frame = Buffer.create (24 + String.length payload) in
  Buffer.add_string frame testnet4_magic;
  Buffer.add_string frame (command_field command);
  Tx.put_u32 frame (Int32.of_int (String.length payload));
  Buffer.add_string frame (checksum payload);
  Buffer.add_string frame payload;
  output_string client.oc (Buffer.contents frame);
  flush client.oc

let append_net_addr buf =
  put_u64 buf services;
  Buffer.add_string buf (String.make 10 '\000');
  Buffer.add_string buf "\xff\xff\000\000\000\000";
  put_u16_be buf 0

let append_var_bytes buf value =
  Buffer.add_string buf (Tx.compact_size (String.length value));
  Buffer.add_string buf value

let version_payload () =
  let buf = Buffer.create 128 in
  Tx.put_u32 buf protocol_version;
  put_u64 buf services;
  put_i64 buf (Int64.of_float (Unix.time ()));
  append_net_addr buf;
  append_net_addr buf;
  put_u64 buf (Int64.of_float (Unix.gettimeofday () *. 1_000_000.));
  append_var_bytes buf "/ocbitnode:0.1.0/";
  Tx.put_u32 buf 0l;
  Buffer.add_char buf '\000';
  Buffer.contents buf

let parse_peer peer =
  match String.rindex_opt peer ':' with
  | None -> err ("invalid peer: " ^ peer)
  | Some index ->
      let host = String.sub peer 0 index in
      let port = int_of_string (String.sub peer (index + 1) (String.length peer - index - 1)) in
      host, port

let connect peer =
  let host, port = parse_peer peer in
  let addr =
    let addresses = Unix.getaddrinfo host (string_of_int port) [ Unix.(AI_FAMILY PF_INET); AI_SOCKTYPE SOCK_STREAM ] in
    match addresses with
    | row :: _ -> row.Unix.ai_addr
    | [] -> err ("could not resolve peer: " ^ peer)
  in
  let fd = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt fd Unix.TCP_NODELAY true;
  Unix.connect fd addr;
  { ic = Unix.in_channel_of_descr fd; oc = Unix.out_channel_of_descr fd }

(* Deferred advanced negotiation: version/verack/sendheaders only; honest start_height in version_payload. *)
let handshake client =
  send client "version" (version_payload ());
  let seen_version = ref false in
  let seen_verack = ref false in
  while (not !seen_version) || not !seen_verack do
    let message = read_message client in
    match message.command with
    | "version" ->
        seen_version := true;
        send client "verack" ""
    | "verack" -> seen_verack := true
    | "ping" -> send client "pong" message.payload
    | _ -> ()
  done;
  send client "sendheaders" ""

let getheaders_payload locator =
  let buf = Buffer.create 72 in
  Tx.put_u32 buf protocol_version;
  Buffer.add_string buf (Tx.compact_size 1);
  Buffer.add_string buf locator;
  Buffer.add_string buf (String.make 32 '\000');
  Buffer.contents buf

let parse_headers payload =
  let count, offset = Tx.read_compact_size payload 0 in
  let cursor = ref offset in
  let headers = ref [] in
  for _ = 1 to count do
    ensure (!cursor + 80 <= String.length payload) "truncated headers payload";
    let header = String.sub payload !cursor 80 in
    cursor := !cursor + 80;
    let tx_count, next = Tx.read_compact_size payload !cursor in
    ensure (tx_count = 0) "headers message had nonzero tx count";
    cursor := next;
    headers := header :: !headers
  done;
  List.rev !headers

let read_command client command =
  let rec loop () =
    let message = read_message client in
    if message.command = command then message
    else (
      if message.command = "ping" then send client "pong" message.payload;
      loop ())
  in
  loop ()

let headers_through client target =
  let hashes_rev = ref [ Tx.parse_display_hash genesis_hash ] in
  let height = ref 0 in
  while !height < target do
    let locator = List.hd !hashes_rev in
    send client "getheaders" (getheaders_payload locator);
    let headers = parse_headers (read_command client "headers").payload in
    ensure (headers <> []) ("peer returned no headers at height " ^ string_of_int !height);
    List.iter
      (fun header ->
        if !height < target then (
          let prev = String.sub header 4 32 in
          let expected = List.hd !hashes_rev in
          ensure (prev = expected) ("header prev mismatch at height " ^ string_of_int (!height + 1));
          hashes_rev := Tx.double_sha header :: !hashes_rev;
          incr height))
      headers
  done;
  List.rev !hashes_rev

let getdata_payload hashes =
  let buf = Buffer.create (1 + (36 * List.length hashes)) in
  Buffer.add_string buf (Tx.compact_size (List.length hashes));
  List.iter
    (fun hash ->
      Tx.put_u32 buf msg_witness_block;
      Buffer.add_string buf hash)
    hashes;
  Buffer.contents buf

let request_blocks client hashes =
  send client "getdata" (getdata_payload hashes);
  let pending = Hashtbl.create (List.length hashes) in
  List.iteri (fun index hash -> Hashtbl.add pending (Util.hex_of_bytes hash) index) hashes;
  let result = Array.make (List.length hashes) "" in
  while Hashtbl.length pending > 0 do
    let message = read_message client in
    match message.command with
    | "block" ->
        ensure (String.length message.payload >= 80) "short block payload";
        let hash = Util.hex_of_bytes (Tx.double_sha (String.sub message.payload 0 80)) in
        (match Hashtbl.find_opt pending hash with
        | Some index ->
            Hashtbl.remove pending hash;
            result.(index) <- message.payload
        | None -> ())
    | "notfound" -> err "peer returned notfound for requested block"
    | "ping" -> send client "pong" message.payload
    | _ -> ()
  done;
  Array.to_list result

let iter_blocks ~peer ~target ~start_height ~prefetch ~on_block =
  let client = connect peer in
  handshake client;
  let hashes = headers_through client target |> Array.of_list in
  let start = ref start_height in
  while !start <= target do
    let last = min target (!start + max 1 prefetch - 1) in
    let wanted =
      let rec slice i acc =
        if i > last then List.rev acc else slice (i + 1) (hashes.(i) :: acc)
      in
      slice !start []
    in
    let started = Unix.gettimeofday () in
    let blocks = request_blocks client wanted in
    let fetch_ms = int_of_float (((Unix.gettimeofday () -. started) *. 1000.) /. float_of_int (max 1 (List.length blocks))) in
    List.iteri
      (fun offset raw ->
        let height = !start + offset in
        on_block { height; hash = Tx.display_hash (Tx.double_sha (String.sub raw 0 80)); raw; fetch_ms })
      blocks;
    start := last + 1
  done

let fetch_blocks ~peer ~target ~start_height ~prefetch =
  let rows = ref [] in
  iter_blocks ~peer ~target ~start_height ~prefetch ~on_block:(fun block -> rows := block :: !rows);
  List.rev !rows
